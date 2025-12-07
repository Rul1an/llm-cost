const std = @import("std");

/// Embedded default data
const default_json = @embedFile("data/default_pricing.json");

pub const PricingModel = struct {
    name: []const u8,
    input_price_per_million: f64,
    output_price_per_million: f64,
};

pub const PricingDB = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn init(allocator: std.mem.Allocator) !PricingDB {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            default_json,
            .{ .ignore_unknown_fields = true }
        );
        return PricingDB{ .parsed = parsed };
    }

    pub fn deinit(self: *PricingDB) void {
        self.parsed.deinit();
    }

    pub fn resolveModel(self: *PricingDB, name: []const u8) ?PricingModel {
        const root = self.parsed.value;

        // 1. Check aliases
        var resolved_name = name;
        if (root.object.get("aliases")) |aliases| {
            if (aliases.object.get(name)) |alias_target| {
                if (alias_target == .string) {
                    resolved_name = alias_target.string;
                }
            }
        }

        // 2. Lookup in models
        if (root.object.get("models")) |models| {
             if (models.object.get(resolved_name)) |m| {
                 const in_price = m.object.get("input_price_per_million").?.float;
                 const out_price = m.object.get("output_price_per_million").?.float;

                 return PricingModel{
                     .name = resolved_name,
                     .input_price_per_million = in_price,
                     .output_price_per_million = out_price,
                 };
             }
        }

        return null;
    }
};

test "pricing db loads and resolves" {
    var db = try PricingDB.init(std.testing.allocator);
    defer db.deinit();

    // Direct match
    if (db.resolveModel("gpt-4o-2024-08-06")) |m| {
        try std.testing.expectEqual(2.50, m.input_price_per_million);
    } else return error.ModelNotFound;

    // Alias
    if (db.resolveModel("gpt-4o")) |m| {
        try std.testing.expectEqualStrings("gpt-4o-2024-08-06", m.name);
    } else return error.AliasNotFound;

    // Unknown
    try std.testing.expect(db.resolveModel("unknown-model") == null);
}
