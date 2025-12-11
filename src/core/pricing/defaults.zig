const std = @import("std");
const schema = @import("schema.zig");

// File is copied to this directory.
const EMBEDDED_JSON = @embedFile("pricing_db.json");

pub fn loadEmbedded(allocator: std.mem.Allocator) !schema.PricingDB {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, EMBEDDED_JSON, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJsonFormat;

    var db = schema.PricingDB{
        .version = 0,
        .updated_at = "",
        .valid_until = "",
        .models = std.StringHashMap(schema.PriceDef).init(allocator),
        .aliases = std.StringHashMap([]const u8).init(allocator),
    };
    errdefer {
        db.models.deinit();
        db.aliases.deinit();
    }

    // Version
    if (root.object.get("version")) |v| {
        if (v == .integer) db.version = @intCast(v.integer);
    }

    // Dates
    if (root.object.get("updated_at")) |v| {
        if (v == .string) db.updated_at = try allocator.dupe(u8, v.string);
    }
    if (root.object.get("valid_until")) |v| {
        if (v == .string) db.valid_until = try allocator.dupe(u8, v.string);
    }

    // Models
    if (root.object.get("models")) |models_obj| {
        if (models_obj == .object) {
            var it = models_obj.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val != .object) continue;

                var def = schema.PriceDef{
                    .input_price_per_mtok = 0.0,
                    .output_price_per_mtok = 0.0,
                };

                // Helper to get float
                if (getFloat(val, "input_price_per_mtok")) |f| def.input_price_per_mtok = f;
                if (getFloat(val, "output_price_per_mtok")) |f| def.output_price_per_mtok = f;
                if (getFloat(val, "output_reasoning_price_per_mtok")) |f| def.output_reasoning_price_per_mtok = f;
                if (getFloat(val, "cache_read_price_per_mtok")) |f| def.cache_read_price_per_mtok = f;
                if (getFloat(val, "cache_write_price_per_mtok")) |f| def.cache_write_price_per_mtok = f;

                // Context window
                if (getInt(val, "context_window")) |i| def.context_window = i;

                // Provider
                if (val.object.get("provider")) |p_val| {
                    if (p_val == .string) {
                        def.provider = schema.Provider.fromString(p_val.string);
                    }
                }

                // Constants (dupe key since we are storing it in hashmap which manages keys)
                const key_dupe = try allocator.dupe(u8, key);
                try db.models.put(key_dupe, def);
            }
        }
    }

    // Aliases
    if (root.object.get("aliases")) |aliases_obj| {
        if (aliases_obj == .object) {
            var it = aliases_obj.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val == .string) {
                    const key_dupe = try allocator.dupe(u8, key);
                    const val_dupe = try allocator.dupe(u8, val.string);
                    try db.aliases.put(key_dupe, val_dupe);
                }
            }
        }
    }

    return db;
}

fn getFloat(val: std.json.Value, key: []const u8) ?f64 {
    if (val.object.get(key)) |v| {
        return switch (v) {
            .float => v.float,
            .integer => @floatFromInt(v.integer),
            else => null,
        };
    }
    return null;
}

fn getInt(val: std.json.Value, key: []const u8) ?u64 {
    if (val.object.get(key)) |v| {
        return switch (v) {
            .integer => @intCast(v.integer),
            else => null,
        };
    }
    return null;
}
