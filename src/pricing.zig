const std = @import("std");

/// Embedded default data
const default_json = @embedFile("data/default_pricing.json");

pub const PricingModel = struct {
    name: []const u8,
    input_price_per_million: f64,
    output_price_per_million: f64,
    // Optional scaling fields
    reasoning_price_per_million: ?f64 = null,

    // Metadata
    tokenizer: []const u8 = "unknown",
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

        // 1. Check aliases (one-level only)
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
                 // Defensively read fields. If input/output price miss, we consider it malformed -> null.
                 const in_node = m.object.get("input_price") orelse m.object.get("input_price_per_million");
                 const out_node = m.object.get("output_price") orelse m.object.get("output_price_per_million");

                 // Robust float helpers:
                 const getFloat = struct {
                     fn call(val: ?std.json.Value) ?f64 {
                         const v = val orelse return null;
                         return switch (v) {
                             .float => |x| x,
                             .integer => |x| @as(f64, @floatFromInt(x)),
                             else => null,
                         };
                     }
                 }.call;

                 const in_price = getFloat(in_node) orelse return null;
                 const out_price = getFloat(out_node) orelse return null;

                 // Optional fields
                 const reasoning_node = m.object.get("reasoning_price") orelse m.object.get("reasoning_input_price") orelse m.object.get("reasoning_input_price_per_million");
                 const reasoning_price = getFloat(reasoning_node);

                 var tokenizer: []const u8 = "generic_whitespace";
                 if (m.object.get("tokenizer")) |t| {
                     if (t == .string) tokenizer = t.string;
                 }

                 return PricingModel{
                     .name = resolved_name,
                     .input_price_per_million = in_price,
                     .output_price_per_million = out_price,
                     .reasoning_price_per_million = reasoning_price,
                     .tokenizer = tokenizer,
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
