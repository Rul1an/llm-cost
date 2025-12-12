const std = @import("std");
const builtin = @import("builtin");

pub const Crypto = @import("crypto.zig");
// Public Key moved to crypto.zig

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
                } else {
                    // Critical: Point to static "Unknown" so it survives arena deinit
                    // and matches the deinit check logic (which skips free for "Unknown")
                    def.value.provider = "Unknown";
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

    // Verify extracted to crypto.zig (Crypto.verify)

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
