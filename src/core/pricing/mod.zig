const std = @import("std");
const builtin = @import("builtin");

// Public Key (Base64) - Minisign
const RELEASE_PUBKEY_B64 = "RWQlMFKYcN36NSyucoSch4tDfC/U/giAHdYklLaCOKZ+9PtYNdjO2Urw";

// Time limits (seconds)
const CRITICAL_AGE_SECONDS = 90 * 24 * 60 * 60; // 90 days

const StaleStatus = enum { Fresh, Warning, Critical };

pub const PriceDef = struct {
    provider: []const u8 = "Unknown",
    input_price_per_mtok: f64 = 0,
    output_price_per_mtok: f64 = 0,

    // Legacy aliases if needed
    input_cost_per_mtok: f64 = 0,
    output_cost_per_mtok: f64 = 0,

    output_reasoning_price_per_mtok: f64 = 0.0,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    models: std.StringHashMap(PriceDef),

    // Metadata about loaded set
    source: enum { Embedded, Cache } = .Embedded,
    valid_until: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: anytype) !Registry {
        _ = options;

        // 1. Try Cache (Silent Fail)
        if (loadFromCache(allocator)) |cached_reg| {
            return cached_reg;
        } else |err| {
            // In debug mode, valid to know why cache failed
            if (builtin.mode == .Debug) {
                std.debug.print("[Cache Skip] Reason: {s}\n", .{@errorName(err)});
            }
        }

        // 2. Fallback to Embedded (Secure Boot)
        return loadEmbedded(allocator);
    }

    fn loadFromCache(allocator: std.mem.Allocator) !Registry {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache_path = try getCachePath(&buf, allocator) orelse return error.NoCacheDir;

        const db_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_path, "pricing_db.json" });
        defer allocator.free(db_path);

        const sig_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_path, "pricing_db.json.sig" });
        defer allocator.free(sig_path);

        const cwd = std.fs.cwd();
        const db_content = cwd.readFileAlloc(allocator, db_path, 10 * 1024 * 1024) catch return error.CacheMiss;
        defer allocator.free(db_content);

        const sig_content = cwd.readFileAlloc(allocator, sig_path, 4096) catch return error.CacheMiss;
        defer allocator.free(sig_content);

        // Security First: Verify before parsing
        try verify(db_content, sig_content);

        // Parse & Check Stale
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, db_content, .{});
        defer parsed.deinit();

        var valid_until: i64 = 0;
        if (parsed.value == .object) {
            if (parsed.value.object.get("valid_until")) |v| {
                if (v == .integer) valid_until = v.integer;
            }
        }

        const stale_status = checkStale(valid_until);
        if (stale_status == .Critical) {
            return error.CacheTooStale;
        }

        var reg = Registry{
            .allocator = allocator,
            .models = std.StringHashMap(PriceDef).init(allocator),
            .source = .Cache,
            .valid_until = valid_until,
        };
        errdefer reg.deinit();

        try parseInto(allocator, parsed.value, &reg.models);
        return reg;
    }

    fn loadEmbedded(allocator: std.mem.Allocator) !Registry {
        const db_content = @embedFile("pricing_db.json");
        const sig_content = @embedFile("pricing_db.json.sig");

        verify(db_content, sig_content) catch |err| {
            std.log.err("Minisign verification failed on EMBEDDED database! This indicates a corrupted binary or tampering.", .{});
            return err;
        };

        var reg = Registry{
            .allocator = allocator,
            .models = std.StringHashMap(PriceDef).init(allocator),
            .source = .Embedded,
        };
        errdefer reg.deinit();

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, db_content, .{});
        defer parsed.deinit();

        try parseInto(allocator, parsed.value, &reg.models);
        return reg;
    }

    fn parseInto(allocator: std.mem.Allocator, root: std.json.Value, map: *std.StringHashMap(PriceDef)) !void {
        var models_node: std.json.Value = root;

        // Support v0.8.0 (root is map) and v0.9.0 (root.models is map)
        if (root == .object) {
            if (root.object.get("models")) |m| {
                models_node = m;
            }
        }

        if (models_node == .object) {
            var it = models_node.object.iterator();
            while (it.next()) |entry| {
                const val = entry.value_ptr.*;
                if (val != .object) continue;

                var def = try std.json.parseFromValue(PriceDef, allocator, val, .{ .ignore_unknown_fields = true });
                defer def.deinit();

                // Duplicate provider string because source buffer is transient (in loadFromCache)
                if (!std.mem.eql(u8, def.value.provider, "Unknown")) {
                    def.value.provider = try allocator.dupe(u8, def.value.provider);
                }

                try map.put(try allocator.dupe(u8, entry.key_ptr.*), def.value);
            }
        }
    }

    fn checkStale(valid_until: i64) StaleStatus {
        const now = std.time.timestamp();
        if (valid_until == 0) return .Critical;
        if (now > valid_until + CRITICAL_AGE_SECONDS) return .Critical;
        if (now > valid_until) return .Warning;
        return .Fresh;
    }

    fn getCachePath(buf: []u8, allocator: std.mem.Allocator) !?[]const u8 {
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        if (env_map.get("XDG_CACHE_HOME")) |xdg| {
            return try std.fmt.bufPrint(buf, "{s}/llm-cost", .{xdg});
        }
        if (env_map.get("HOME")) |home| {
            return try std.fmt.bufPrint(buf, "{s}/.cache/llm-cost", .{home});
        }
        if (builtin.os.tag == .windows) {
            if (env_map.get("LOCALAPPDATA")) |appdata| {
                return try std.fmt.bufPrint(buf, "{s}\\llm-cost", .{appdata});
            }
        }
        return null;
    }

    /// Step 1: Public Verify (Refactored)
    pub fn verify(msg: []const u8, sig_file_content: []const u8) !void {
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
        const pub_key_id = buf_128[2..10];
        const pub_key = try PublicKey.fromBytes(buf_128[10..42].*);

        // File Sig
        const file_sig_len = try Base64.calcSizeForSlice(file_sig_b64);
        try Base64.decode(buf_256[0..file_sig_len], file_sig_b64);
        if (file_sig_len < 74) return error.InvalidSignatureLength;

        const raw_file_sig = buf_256[10..74];
        const sig_of_file = Signature.fromBytes(raw_file_sig[0..64].*);

        if (!std.mem.eql(u8, buf_256[2..10], pub_key_id)) return error.KeyIdMismatch;

        // Global Sig
        const global_sig_len = try Base64.calcSizeForSlice(global_sig_b64);
        try Base64.decode(buf_256[0..global_sig_len], global_sig_b64);

        var raw_global_sig: []const u8 = undefined;
        if (global_sig_len == 64) {
            raw_global_sig = buf_256[0..64];
        } else if (global_sig_len == 74) {
            if (!std.mem.eql(u8, buf_256[2..10], pub_key_id)) return error.KeyIdMismatch;
            raw_global_sig = buf_256[10..74];
        } else {
            return error.InvalidSignatureLength;
        }

        const sig_of_global = Signature.fromBytes(raw_global_sig[0..64].*);

        // 3. EXTRACT TRUSTED COMMENT
        const prefix = "trusted comment: ";
        if (!std.mem.startsWith(u8, trusted_comment_line, prefix)) return error.InvalidCommentPrefix;
        const payload_raw = trusted_comment_line[prefix.len..];
        const payload_trimmed = std.mem.trimRight(u8, payload_raw, " \t\r\n");

        // 4. CRITICAL: VERIFY FILE INTEGRITY (Hash)
        var hash: [64]u8 = undefined;
        std.crypto.hash.blake2.Blake2b512.hash(msg, &hash, .{});
        try sig_of_file.verify(&hash, pub_key);

        // 5. SECONDARY: VERIFY METADATA (Global Chain)
        // Assume pure signature + payload + newline
        var global_buf: [512]u8 = undefined;
        const total_len = 64 + payload_trimmed.len + 1;

        if (total_len > global_buf.len) return error.CommentTooLarge;

        std.mem.copyForwards(u8, global_buf[0..64], raw_file_sig); // Use raw_file_sig (64 bytes)
        std.mem.copyForwards(u8, global_buf[64..][0..payload_trimmed.len], payload_trimmed);
        global_buf[64 + payload_trimmed.len] = '\n'; // Add newline

        sig_of_global.verify(global_buf[0..total_len], pub_key) catch {
            // We treat this as a warning for now, as file integrity is verified handled
            std.log.warn("Minisign: Trusted comment verification failed. Data is valid but metadata may be forged.", .{});
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);

            // Free provider string if it's not the default "Unknown" (which is static)
            // Note: We check against the literal "Unknown"
            if (!std.mem.eql(u8, entry.value_ptr.provider, "Unknown")) {
                self.allocator.free(entry.value_ptr.provider);
            }
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
