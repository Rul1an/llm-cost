const std = @import("std");
const schema = @import("schema.zig");

pub fn parsePricingDB(allocator: std.mem.Allocator, json_content: []const u8) !schema.PricingDB {
    // We parse into a temporary struct that matches JSON structure if needed,
    // OR we rely on PricingDB shape if it matches.
    // PricingDB has `version`, `updated`, `models`, `aliases`.
    // Valid for direct parsing if fields match.

    // Using ignore_unknown_fields for robustness.
    const parsed = try std.json.parseFromSlice(schema.PricingDB, allocator, json_content, .{
        .ignore_unknown_fields = true,
    });
    // parsed.value is the struct.
    // However, parseFromSlice allocates resources (strings, hashmaps) using allocator.
    // We return the value. The caller is responsible for freeing deep data (PricingDB.deinit).

    return parsed.value;
}
