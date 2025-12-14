const std = @import("std");
const builtin = @import("builtin");

pub const Crypto = @import("crypto.zig");

const CRITICAL_AGE_SECONDS = 90 * 24 * 60 * 60; // 90 days

const StaleStatus = enum { Fresh, Warning, Critical };

const schema = @import("schema.zig");
pub const PriceDef = schema.PriceDef;
pub const MicroUsd = schema.MicroUsd;

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
        try Crypto.verify(allocator, db_content, sig_content);

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

        Crypto.verify(allocator, db_content, sig_content) catch |err| {
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
