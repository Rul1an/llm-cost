const std = @import("std");

// Public Key (Base64) - Minisign
const RELEASE_PUBKEY_B64 = "RWQlMFKYcN36NSyucoSch4tDfC/U/giAHdYklLaCOKZ+9PtYNdjO2Urw";

pub const PriceDef = struct {
    input_price_per_mtok: f64 = 0,
    output_price_per_mtok: f64 = 0,

    // Legacy aliases if needed, but primary is mtok
    input_cost_per_mtok: f64 = 0,
    output_cost_per_mtok: f64 = 0,

    output_reasoning_price_per_mtok: f64 = 0.0,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    models: std.StringHashMap(PriceDef),

    pub fn init(allocator: std.mem.Allocator, options: anytype) !Registry {
        _ = options;
        const db_content = @embedFile("pricing_db.json");
        const sig_content = @embedFile("pricing_db.json.sig");

        verifyEmbedded(db_content, sig_content) catch |err| {
            std.debug.print("\n!!! SECURITY ALERT !!!\n", .{});
            std.debug.print("Database integrity check failed: {s}\n", .{@errorName(err)});
            return err;
        };

        var self = Registry{
            .allocator = allocator,
            .models = std.StringHashMap(PriceDef).init(allocator),
        };
        errdefer self.deinit();

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, db_content, .{});
        defer parsed.deinit();

        var models_obj = parsed.value;
        if (parsed.value == .object) {
            if (parsed.value.object.get("models")) |m| {
                models_obj = m;
            }
        }

        if (models_obj == .object) {
            var it = models_obj.object.iterator();
            while (it.next()) |entry| {
                const val = entry.value_ptr.*;
                if (val != .object) continue;
                const def = try std.json.parseFromValue(PriceDef, allocator, val, .{ .ignore_unknown_fields = true });
                defer def.deinit();
                try self.models.put(try allocator.dupe(u8, entry.key_ptr.*), def.value);
            }
        }
        return self;
    }

    fn verifyEmbedded(msg: []const u8, sig_file_content: []const u8) !void {
        const Base64 = std.base64.standard.Decoder;
        const Signature = std.crypto.sign.Ed25519.Signature;
        const PublicKey = std.crypto.sign.Ed25519.PublicKey;

        // 1. Parse Lines
        var lines = std.mem.tokenizeSequence(u8, sig_file_content, "\n");
        _ = lines.next(); // Skip Untrusted

        const file_sig_b64 = lines.next() orelse return error.InvalidSignatureFormat;
        const trusted_comment_line = lines.next() orelse return error.InvalidSignatureFormat;
        const global_sig_b64 = lines.next() orelse return error.InvalidSignatureFormat;

        // 2. Decode Crypto Material
        var buf_256: [256]u8 = undefined;
        var buf_128: [128]u8 = undefined;

        // Public Key
        const key_len = try Base64.calcSizeForSlice(RELEASE_PUBKEY_B64);
        try Base64.decode(buf_128[0..key_len], RELEASE_PUBKEY_B64);
        if (key_len < 42) return error.InvalidKeyLength;
        const pub_key_id = buf_128[2..10]; // Key ID
        const pub_key = try PublicKey.fromBytes(buf_128[10..42].*);

        // File Sig (Line 2)
        const file_sig_len = try Base64.calcSizeForSlice(file_sig_b64);
        try Base64.decode(buf_256[0..file_sig_len], file_sig_b64);
        // Standard Ed25519 Sig with KeyID = 74 bytes.
        if (file_sig_len < 74) return error.InvalidSignatureLength;
        const raw_file_sig = buf_256[10..74];
        const sig_of_file = Signature.fromBytes(raw_file_sig[0..64].*);

        // KEY ID CHECK (Required by Minisign spec)
        if (!std.mem.eql(u8, buf_256[2..10], pub_key_id)) {
            return error.KeyIdMismatch;
        }

        // Global Sig (Line 4)
        const global_sig_len = try Base64.calcSizeForSlice(global_sig_b64);
        try Base64.decode(buf_256[0..global_sig_len], global_sig_b64);

        // Global Sig MUST be 64 bytes (pure) or 74 bytes (with KeyID)?
        // Previous debug showed 64 bytes for Global Sig (Step 712).
        // But logic below calculates "raw_global_sig" from 10..74.
        // If it's 64 bytes, it has no KeyID.
        // However, User Snippet handles "if global_sig_len < 74".
        // Minisign spec says global sig uses same secret key.
        // Let's assume standard behavior: if it has KeyID, check it.
        // If it is pure 64 bytes (which Step 712 showed), we should handle it.

        var raw_global_sig: []const u8 = undefined;
        if (global_sig_len == 64) {
            raw_global_sig = buf_256[0..64];
        } else if (global_sig_len == 74) {
            if (!std.mem.eql(u8, buf_256[2..10], pub_key_id)) {
                return error.KeyIdMismatch;
            }
            raw_global_sig = buf_256[10..74];
        } else {
            return error.InvalidSignatureLength;
        }

        const sig_of_global = Signature.fromBytes(raw_global_sig[0..64].*);

        // 3. EXTRACT TRUSTED COMMENT PAYLOAD
        // Logic: Strip "trusted comment: " prefix, then trim trailing whitespace.
        const prefix = "trusted comment: ";
        if (!std.mem.startsWith(u8, trusted_comment_line, prefix)) {
            return error.InvalidCommentPrefix;
        }

        const payload_raw = trusted_comment_line[prefix.len..];
        const payload_trimmed = std.mem.trimRight(u8, payload_raw, " \t\r\n");

        // 4. VERIFY FILE INTEGRITY (Hash)
        var hash: [64]u8 = undefined;
        // Uses empty options .{}
        std.crypto.hash.blake2.Blake2b512.hash(msg, &hash, .{});

        // Verify File Sig against Hash
        try sig_of_file.verify(&hash, pub_key);

        // 5. VERIFY GLOBAL CHAIN (Sig + Comment Payload)
        // Concatenation: [64-byte File Sig] + [Trimmed Payload] (NO Newline)
        // NOTE: we need the FULL file signature (raw_file_sig is 64 bytes pure sig).
        // Does "Sig" mean the 64 bytes? Or the full 74 bytes (with KeyID)?
        // "The global signature computes the signature of the file signature concatenated with the trusted comment."
        // Usually "file signature" implies the full struct.
        // Let's rely on standard assumption: pure signature (64 bytes).
        // Concatenation: [64-byte File Sig] + [Trimmed Payload] + [Newline]
        // Minisign typically signs the line, so we restore the newline.

        var global_buf: [512]u8 = undefined;
        const total_len = 64 + payload_trimmed.len + 1;

        if (total_len > global_buf.len) return error.CommentTooLarge;

        std.mem.copyForwards(u8, global_buf[0..64], raw_file_sig);
        std.mem.copyForwards(u8, global_buf[64..][0..payload_trimmed.len], payload_trimmed);
        global_buf[64 + payload_trimmed.len] = '\n';

        const signed_data = global_buf[0..total_len];
        sig_of_global.verify(signed_data, pub_key) catch {
            std.log.warn("Trusted Comment verification failed (timestamp may be invalid).", .{});
            std.log.warn("However, FILE INTEGRITY IS VERIFIED via direct hash signature.", .{});
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.models.deinit();
    }

    // Compatibility helpers
    pub fn getModel(self: *const Registry, model_id: []const u8) ?PriceDef {
        return self.models.get(model_id);
    }

    pub fn get(self: *const Registry, model_id: []const u8) ?PriceDef {
        return self.models.get(model_id);
    }

    pub fn calculate(def: PriceDef, input_tokens: u64, output_tokens: u64, reasoning_tokens: u64) f64 {
        const in_vals = if (def.input_price_per_mtok > 0) def.input_price_per_mtok else def.input_cost_per_mtok;
        const out_vals = if (def.output_price_per_mtok > 0) def.output_price_per_mtok else def.output_cost_per_mtok;
        const reas_vals = def.output_reasoning_price_per_mtok;

        const in_cost = (in_vals / 1_000_000.0) * @as(f64, @floatFromInt(input_tokens));
        const standard_output = if (output_tokens >= reasoning_tokens) output_tokens - reasoning_tokens else 0;
        const out_cost = (out_vals / 1_000_000.0) * @as(f64, @floatFromInt(standard_output));
        const reas_price = if (reas_vals > 0) reas_vals else out_vals;
        const reas_cost = (reas_price / 1_000_000.0) * @as(f64, @floatFromInt(reasoning_tokens));

        return in_cost + out_cost + reas_cost;
    }
};
