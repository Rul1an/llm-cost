const std = @import("std");
const testing = std.testing;
const Schema = @import("core/focus/schema.zig");

// --- 1. Test Deterministic Cost Formatting ---
test "Format Cost MicroUSD" {
    const allocator = testing.allocator;

    // Test cases: Value -> Expected String
    const cases = [_]struct { val: i128, str: []const u8 }{
        .{ .val = 5, .str = "0.000005" }, // 5 micro = 0.000005
        .{ .val = 500000, .str = "0.500000" }, // 0.5 USD
        .{ .val = 1000000, .str = "1.000000" }, // 1.0 USD
        .{ .val = 1234567, .str = "1.234567" }, // 1.234567 USD
        .{ .val = 0, .str = "0.000000" },
        .{ .val = 1500, .str = "0.001500" },
        .{ .val = -500000, .str = "-0.500000" }, // Negative 0.5
    };

    for (cases) |c| {
        const sign = if (c.val < 0) "-" else "";
        const abs_val = @abs(c.val);
        const whole = abs_val / 1_000_000;
        const frac = abs_val % 1_000_000;

        const str = try std.fmt.allocPrint(allocator, "{s}{d}.{d:0>6}", .{ sign, whole, @as(u64, @intCast(frac)) });
        defer allocator.free(str);

        if (!std.mem.eql(u8, c.str, str)) {
            std.debug.print("FAIL: Expected '{s}', Got '{s}'\n", .{ c.str, str });
        }
        try testing.expectEqualStrings(c.str, str);
    }
}

// --- 2. Test Deterministic Export Sorting ---
// Mock logic from export.zig to verify sorting behavior
fn sortRows(_: void, lhs: Schema.FocusRow, rhs: Schema.FocusRow) bool {
    const period_order = std.mem.order(u8, lhs.charge_period_start, rhs.charge_period_start);
    if (period_order != .eq) return period_order == .lt;

    const rid_order = std.mem.order(u8, lhs.resource_id, rhs.resource_id);
    if (rid_order != .eq) return rid_order == .lt;

    const service_order = std.mem.order(u8, lhs.service_name, rhs.service_name);
    return service_order == .lt;
}

test "Export Rows Sorting" {
    const allocator = testing.allocator;

    // Create dummy rows (unsorted)
    // We only populate fields needed for sorting: Period, ResourceId, ServiceName
    var rows = std.ArrayList(Schema.FocusRow).init(allocator);
    defer rows.deinit();

    // Helper to make dummy row
    const makeRow = struct {
        fn make(a: std.mem.Allocator, period: []const u8, rid: []const u8, svc: []const u8) !Schema.FocusRow {
            return Schema.FocusRow{
                .allocator = a,
                .charge_period_start = try a.dupe(u8, period),
                .charge_category = try a.dupe(u8, ""),
                .billed_cost = try a.dupe(u8, ""),
                .resource_id = try a.dupe(u8, rid),
                .resource_type = try a.dupe(u8, ""),
                .region_id = try a.dupe(u8, ""),
                .service_category = try a.dupe(u8, ""),
                .service_name = try a.dupe(u8, svc),
                .consumed_quantity = null,
                .consumed_unit = try a.dupe(u8, ""),
                .resource_name = try a.dupe(u8, ""),
                .tags = .{
                    .provider = try a.dupe(u8, ""),
                    .model = try a.dupe(u8, ""),
                    .token_count_input = 0,
                    .token_count_output = 0,
                    .cache_hit_ratio = null,
                    .content_hash = try a.dupe(u8, ""),
                    .user_tags = std.StringHashMap([]const u8).init(a),
                },
            };
        }
    }.make;

    // Row A: 2024-01-01, ID-2, GPT-4
    // Row B: 2024-01-01, ID-1, GPT-4
    // Row C: 2023-12-31, ID-5, GPT-4
    try rows.append(try makeRow(allocator, "2024-01-01T00:00:00Z", "id-2", "gpt-4"));
    try rows.append(try makeRow(allocator, "2024-01-01T00:00:00Z", "id-1", "gpt-4"));
    try rows.append(try makeRow(allocator, "2023-12-31T00:00:00Z", "id-5", "gpt-4"));

    // Expected Order:
    // 1. C (Earlier Date)
    // 2. B (Same Date, lower ID)
    // 3. A (Same Date, higher ID)

    // Sort
    std.mem.sort(Schema.FocusRow, rows.items, {}, sortRows);

    // Verify
    try testing.expectEqualStrings("2023-12-31T00:00:00Z", rows.items[0].charge_period_start);
    try testing.expectEqualStrings("id-5", rows.items[0].resource_id);

    try testing.expectEqualStrings("2024-01-01T00:00:00Z", rows.items[1].charge_period_start);
    try testing.expectEqualStrings("id-1", rows.items[1].resource_id);

    try testing.expectEqualStrings("2024-01-01T00:00:00Z", rows.items[2].charge_period_start);
    try testing.expectEqualStrings("id-2", rows.items[2].resource_id);

    // Cleanup
    for (rows.items) |*r| r.deinit();
}
