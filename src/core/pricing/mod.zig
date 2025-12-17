const std = @import("std");
const builtin = @import("builtin");

pub const Crypto = @import("crypto.zig");

const CRITICAL_AGE_SECONDS = 90 * 24 * 60 * 60; // 90 days
const WARN_AGE_SECONDS = 30 * 24 * 60 * 60; // 30 days

const StaleStatus = enum { Fresh, Warning, Critical };

const schema = @import("schema.zig");
const Manifest = @import("manifest.zig");
pub const PriceDef = schema.PriceDef;
pub const MicroUsd = schema.MicroUsd;
const paths = @import("paths.zig");
const UpdateState = @import("state.zig").UpdateState;

// P1: Zip-bomb protection handled via readAllArrayList limit
// Removed custom LimitedWriter as std lib supports max_append_size

pub const Registry = struct {
    allocator: std.mem.Allocator,
    models: std.StringHashMap(PriceDef),

    // Metadata about loaded set
    source: enum { Embedded, Cache } = .Embedded,
    generated_at: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: anytype) !Registry {
        _ = options;

        // P0: Rollback Protection - Load state to get highest_seen
        var highest_seen: u64 = 0;
        if (UpdateState.load(allocator)) |st| {
            var state = st; // Mutable copy to deinit
            defer state.deinit(allocator);
            highest_seen = state.highest_version_seen;
        } else |_| {
            // State load fail -> assume 0 (fresh start)
        }

        // 1. Try Cache (Silent Fail)
        if (loadFromCache(allocator, highest_seen)) |cached_reg| {
            return cached_reg;
        } else |_| {
            // Cache failed (Miss, Mismatch, Stale) -> Fallback to Embedded
            // Critical errors (Tampering) are already logged in loadFromCache.
        }

        // 2. Fallback to Embedded (Secure Boot)
        return loadEmbedded(allocator);
    }

    fn loadFromCache(allocator: std.mem.Allocator, highest_seen: u64) !Registry {
        // P0: Consistent Cache Path
        const cache_path = try paths.getCacheDir(allocator);
        defer allocator.free(cache_path);

        // P0: Open Cache Directory (Absolute) to safely read relative files
        var cache_dir = std.fs.openDirAbsolute(cache_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NoCacheDir,
            else => return err,
        };
        defer cache_dir.close();

        // 1. Read Manifest (Relative)
        const manifest_content = cache_dir.readFileAlloc(allocator, "current/manifest.json", 64 * 1024) catch return error.CacheMiss;
        defer allocator.free(manifest_content);

        var manifest_parsed = try std.json.parseFromSlice(Manifest.ManifestContainer, allocator, manifest_content, .{});
        defer manifest_parsed.deinit();

        // 2. Verify Manifest (TUF-lite)
        // Check signature against EMBEDDED Root Key (P1: Unified Root of Trust)
        // Check Expiry (P1: Anti-Freeze)
        // Check Rollback (P0: Anti-Rollback using State)
        const now = std.time.timestamp();
        Manifest.verify(allocator, manifest_parsed.value, Manifest.EMBEDDED_PUB_KEY_STR_HEX, now, highest_seen) catch {
            // If verify fails (signature/expiry), we treat as stale/miss and fallback.
            return error.CacheTooStale;
        };

        // 3. Read & Verify DB (Option A: Consistent Hash on Artifact Bytes)
        const compression_mode = manifest_parsed.value.body.db.compression;
        const is_zstd = std.mem.eql(u8, compression_mode, "zstd");
        const filename = if (is_zstd) "pricing_db.json.zst" else "pricing_db.json";

        // P0: Check defined size before reading
        if (manifest_parsed.value.body.db.size_bytes > 256 * 1024 * 1024) {
            return error.CacheTooLarge;
        }

        // P2: Avoid heap alloc for path
        var rel_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const relative_path = try std.fmt.bufPrint(&rel_path_buf, "current/{s}", .{filename});

        // P3: Verify actual file size via stat BEFORE read (detect truncation)
        {
            const f = try cache_dir.openFile(relative_path, .{});
            defer f.close();
            const st = try f.stat();
            if (st.size != manifest_parsed.value.body.db.size_bytes) {
                // Size mismatch vs Manifest -> Corrupt/Truncated
                return error.CacheMiss; // or HashMismatch
            }
        }

        // Read *Artifact* Bytes (Raw, potentially compressed)
        const artifact_bytes = cache_dir.readFileAlloc(allocator, relative_path, 256 * 1024 * 1024) catch return error.CacheMiss;
        defer allocator.free(artifact_bytes);

        // Verify Hash of Artifact (before decompression)
        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        sha256.update(artifact_bytes);
        var hash_bytes: [32]u8 = undefined;
        sha256.final(&hash_bytes);
        var hash_hex: [64]u8 = undefined;
        // P0: Fix formatter usage
        _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&hash_bytes)}) catch return error.HexError;

        if (!std.mem.eql(u8, &hash_hex, manifest_parsed.value.body.db.sha256)) {
            std.log.err("Cached DB SHA256 mismatch!\nManifest ({s}): {s}\nActual:   {s}", .{ filename, manifest_parsed.value.body.db.sha256, hash_hex });
            return error.HashMismatch;
        }

        // 4. Decompress if needed
        var json_bytes: []const u8 = undefined;
        // Keep decompressor scope limited if possible, but we need bytes to persist for parsing
        // We use an ArrayList for decompressed data.
        var decompressed_list = std.ArrayList(u8).init(allocator);
        defer decompressed_list.deinit();

        if (is_zstd) {
            var fbs = std.io.fixedBufferStream(artifact_bytes);

            // P1: Allocate window buffer (8MB) - Required for robust Zstd decompression
            const window_buf = try allocator.alloc(u8, 1 << 23);
            defer allocator.free(window_buf);

            var d = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window_buf });

            // P1: Zip-bomb protection (Limit 256MB output)
            // readAllArrayList validates max size
            try d.reader().readAllArrayList(&decompressed_list, 256 * 1024 * 1024);
            json_bytes = decompressed_list.items;
        } else {
            // No copy needed, just reference artifact bytes (but careful with differing lifetimes/types)
            // artifact_bytes is owned by us (allocated).
            // json_bytes can alias it.
            json_bytes = artifact_bytes;
        }

        // 5. Check Stale Status from Manifest Metadata
        const generated_at = manifest_parsed.value.body.generated_at;
        const stale_status = checkStale(generated_at);
        if (stale_status == .Critical) {
            return error.CacheTooStale;
        }

        // 6. Parse
        var reg = Registry{
            .allocator = allocator,
            .models = std.StringHashMap(PriceDef).init(allocator),
            .source = .Cache,
            .generated_at = generated_at,
        };
        errdefer reg.deinit();

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
        defer parsed.deinit();

        try parseInto(allocator, parsed.value, &reg.models);
        return reg;
    }

    fn loadEmbedded(allocator: std.mem.Allocator) !Registry {
        const manifest_json = @embedFile("manifest.json");
        const db_content = @embedFile("pricing_db.json");

        // 1. Verify Manifest
        var manifest_parsed = try std.json.parseFromSlice(Manifest.ManifestContainer, allocator, manifest_json, .{});
        defer manifest_parsed.deinit();

        // Use verifyEmbedded helper (Hardcoded Root Key, Anti-Freeze bypass, Strict Checks)
        try Manifest.verifyEmbedded(allocator, manifest_parsed.value);

        // 2. Verify Content Hash
        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        sha256.update(db_content);
        var hash_bytes: [32]u8 = undefined;
        sha256.final(&hash_bytes);
        var hash_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&hash_bytes)}) catch return error.HexError;

        if (!std.mem.eql(u8, &hash_hex, manifest_parsed.value.body.db.sha256)) {
            std.log.err("Embedded DB SHA256 mismatch!\nManifest: {s}\nActual:   {s}", .{ manifest_parsed.value.body.db.sha256, hash_hex });
            return error.HashMismatch;
        }

        // 3. Parse Metadata (Generated At)
        const generated_at = manifest_parsed.value.body.generated_at;

        var reg = Registry{
            .allocator = allocator,
            .models = std.StringHashMap(PriceDef).init(allocator),
            .source = .Embedded,
            .generated_at = generated_at,
        };
        errdefer reg.deinit();

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, db_content, .{});
        defer parsed.deinit();

        try parseInto(allocator, parsed.value, &reg.models);
        return reg;
    }

    // Helper to safely convert float price (USD) to MicroUSD (i128)
    fn toMicroUsd(val: f64) schema.MicroUsdPerMTok {
        // Round to nearest integer to avoid precision truncation issues with floats like 2.499999
        return @intFromFloat(@round(val * 1_000_000.0));
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

                // Manual parsing to handle conversion from JSON float to MicroUSD i128
                var def = PriceDef{
                    .input_price_per_mtok = 0,
                    .output_price_per_mtok = 0,
                    .provider = .Unknown,
                };

                if (val.object.get("input_price_per_mtok")) |v| {
                    if (v == .float) def.input_price_per_mtok = toMicroUsd(v.float);
                    if (v == .integer) def.input_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                }
                // Legacy alias
                if (val.object.get("input_cost_per_mtok")) |v| {
                    if (def.input_price_per_mtok == 0) {
                        if (v == .float) def.input_price_per_mtok = toMicroUsd(v.float);
                        if (v == .integer) def.input_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                    }
                }

                if (val.object.get("output_price_per_mtok")) |v| {
                    if (v == .float) def.output_price_per_mtok = toMicroUsd(v.float);
                    if (v == .integer) def.output_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                }
                // Legacy alias
                if (val.object.get("output_cost_per_mtok")) |v| {
                    if (def.output_price_per_mtok == 0) {
                        if (v == .float) def.output_price_per_mtok = toMicroUsd(v.float);
                        if (v == .integer) def.output_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                    }
                }

                if (val.object.get("output_reasoning_price_per_mtok")) |v| {
                    if (v == .float) def.output_reasoning_price_per_mtok = toMicroUsd(v.float);
                    if (v == .integer) def.output_reasoning_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                }

                if (val.object.get("cache_read_price_per_mtok")) |v| {
                    if (v == .float) def.cache_read_price_per_mtok = toMicroUsd(v.float);
                    if (v == .integer) def.cache_read_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                }
                if (val.object.get("cache_write_price_per_mtok")) |v| {
                    if (v == .float) def.cache_write_price_per_mtok = toMicroUsd(v.float);
                    if (v == .integer) def.cache_write_price_per_mtok = toMicroUsd(@floatFromInt(v.integer));
                }

                // Context window
                if (val.object.get("context_window")) |v| {
                    if (v == .integer) def.context_window = @intCast(v.integer);
                }

                // Provider
                if (val.object.get("provider")) |p_val| {
                    if (p_val == .string) {
                        def.provider = schema.Provider.fromString(p_val.string);
                    }
                }

                // Duplicate provider string because source buffer is transient (in loadFromCache)
                // Provider enum is value type, no duplication needed for enum!
                // Old code duped strings, new code uses Enum.
                // We just need to handle if 'provider' was a string field in the struct?
                // schema.PriceDef.provider is an ENUM.
                // The old code had `provider: []const u8`.
                // Wait, the old code in step 6387 had `provider: []const u8`.
                // schema.zig in step 6434 has `provider: Provider`.
                // So I am changing the type of `PriceDef` in `mod.zig` to match `schema.PriceDef` which uses the Enum.
                // This removes the need for string duplication for provider! excellent.

                try map.put(try allocator.dupe(u8, entry.key_ptr.*), def);
            }
        }
    }

    fn checkStale(generated_at: i64) StaleStatus {
        if (generated_at == 0) return .Critical;

        const now = std.time.timestamp();
        // Prevent underflow if clock is skewed backwards significantly
        if (now < generated_at) return .Warning; // Suspicious: Clock skew or Tampering

        const age = now - generated_at;

        if (age > CRITICAL_AGE_SECONDS) return .Critical;
        if (age > WARN_AGE_SECONDS) return .Warning;
        return .Fresh;
    }

    pub fn getStaleness(self: *const Registry) StaleStatus {
        return checkStale(self.generated_at);
    }

    // Verify extracted to crypto.zig (Crypto.verify)

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

    pub fn calculate(def: PriceDef, input_tokens: u64, output_tokens: u64, reasoning_tokens: u64) MicroUsd {
        // Reasoning tokens are typically included in total output tokens by Engine.
        // We separate them here to apply correct pricing.
        const standard_output = if (output_tokens >= reasoning_tokens) output_tokens - reasoning_tokens else 0;

        return def.calculateCost(input_tokens, .Input) +
            def.calculateCost(standard_output, .Output) +
            def.calculateCost(reasoning_tokens, .Reasoning);
    }
};
