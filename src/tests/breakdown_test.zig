const std = @import("std");
const testing = std.testing;
const Aggregator = @import("../calibration/breakdown.zig").Aggregator;
const Resolver = @import("../calibration/tag_resolver.zig").Resolver;
const focus = @import("../calibration/focus_import.zig");

// Test helper with automatic tags management
fn makeRec(allocator: std.mem.Allocator, agent: ?[]const u8, cost: i128) focus.FocusRecord {
    var tags = std.StringHashMap([]const u8).init(allocator);
    if (agent) |a| {
        tags.put("agent", allocator.dupe(u8, a) catch unreachable) catch unreachable;
    }

    return .{
        .BilledCost = cost,
        .EffectiveCost = cost,
        .UsageQuantity = 100,
        .UsageUnit = "tokens",
        .ChargeCategory = "",
        .ResourceId = "gpt-4",
        .tags = tags,
    };
}

// Helper to free record tags (since we alloc dupes in makeRec for tests)
fn freeRec(allocator: std.mem.Allocator, rec: *focus.FocusRecord) void {
    var it = rec.tags.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    rec.tags.deinit();
}

test "Breakdown: Single Dimension" {
    const allocator = testing.allocator;
    var resolver = try Resolver.init(allocator, null);
    defer resolver.deinit();

    var dims = [_][]const u8{"agent"};
    var agg = Aggregator.init(allocator, resolver, &dims, 100);
    defer agg.deinit();

    // Rec 1: Agent A
    var r1 = makeRec(allocator, "AgentA", 100);
    defer freeRec(allocator, &r1);
    try agg.update(&r1);

    // Rec 2: Agent A
    var r2 = makeRec(allocator, "AgentA", 50);
    defer freeRec(allocator, &r2);
    try agg.update(&r2);

    // Rec 3: Agent B
    var r3 = makeRec(allocator, "AgentB", 200);
    defer freeRec(allocator, &r3);
    try agg.update(&r3);

    var res = agg.finish();
    defer res.deinit();

    try testing.expectEqual(@as(usize, 2), res.by_key.count());

    const stats_a = res.by_key.get("AgentA").?;
    try testing.expectEqual(@as(i128, 150), stats_a.cost_micro);
    try testing.expectEqual(@as(u64, 2), stats_a.count);

    const stats_b = res.by_key.get("AgentB").?;
    try testing.expectEqual(@as(i128, 200), stats_b.cost_micro);
}

test "Breakdown: Multi Dimension" {
    const allocator = testing.allocator;
    var resolver = try Resolver.init(allocator, null);
    defer resolver.deinit();

    // Dimension array must live as long as agg? Yes, init takes reference.
    var dims = [_][]const u8{ "agent", "model" };
    var agg = Aggregator.init(allocator, resolver, &dims, 100);
    defer agg.deinit();

    var r1 = makeRec(allocator, "AgentA", 100); // gpt-4
    defer freeRec(allocator, &r1);
    try agg.update(&r1);

    var res = agg.finish();
    defer res.deinit();

    // Key should be "agent=AgentA|model=gpt-4"
    const stats = res.by_key.get("agent=AgentA|model=gpt-4");
    try testing.expect(stats != null);
    try testing.expectEqual(@as(i128, 100), stats.?.cost_micro);
}

test "Breakdown: Cardinality" {
    const allocator = testing.allocator;
    var resolver = try Resolver.init(allocator, null);
    defer resolver.deinit();

    var dims = [_][]const u8{"agent"};
    // Max 1 key
    var agg = Aggregator.init(allocator, resolver, &dims, 1);
    defer agg.deinit();

    var r1 = makeRec(allocator, "AgentA", 10);
    defer freeRec(allocator, &r1);
    try agg.update(&r1);

    var r2 = makeRec(allocator, "AgentB", 20); // Should trigger __other__
    defer freeRec(allocator, &r2);
    try agg.update(&r2);

    var res = agg.finish();
    defer res.deinit();

    try testing.expect(res.by_key.contains("AgentA"));
    try testing.expect(res.by_key.contains("__other__"));

    try testing.expectEqual(@as(i128, 20), res.by_key.get("__other__").?.cost_micro);
}

test "Breakdown: Consistency & Tokens" {
    const allocator = testing.allocator;
    var resolver = try Resolver.init(allocator, null);
    defer resolver.deinit();

    var dims = [_][]const u8{"agent"};
    var agg = Aggregator.init(allocator, resolver, &dims, 100);
    defer agg.deinit();

    // Case 1: Billed != Effective. Should use Billed.
    // Case 2: x-llm tokens present. Should use sum, ignore UsageQuantity.
    var tags = std.StringHashMap([]const u8).init(allocator);
    try tags.put("agent", try allocator.dupe(u8, "AgentC"));

    var r1 = focus.FocusRecord{
        .BilledCost = 200,
        .EffectiveCost = 150, // Discounted
        .UsageQuantity = 1, // 1 Request
        .UsageUnit = "req",
        .ChargeCategory = "",
        .ResourceId = "",
        .tags = tags,
        .@"x-llm-input-tokens" = 100,
        .@"x-llm-output-tokens" = 50,
    };
    defer {
        var it = r1.tags.iterator();
        while (it.next()) |e| allocator.free(e.value_ptr.*);
        r1.tags.deinit();
    }

    try agg.update(&r1);

    var res = agg.finish();
    defer res.deinit();

    const stats = res.by_key.get("AgentC").?;
    try testing.expectEqual(@as(i128, 200), stats.cost_micro); // Uses Billed
    try testing.expectEqual(@as(u64, 150), stats.tokens); // 100 + 50
    try testing.expectEqual(@as(u64, 1), stats.count);
}
