const std = @import("std");
const testing = std.testing;
const calibrate = @import("calibration");

// Access internal modules exposed by calibrate (mod.zig)
const stats = calibrate.stats;
const types = calibrate.types;
const key_intern = calibrate.key_intern;
const focus = calibrate.focus;

// Helper: Synthesize a record
// Helper: Synthesize a record
fn makeRecord(model: []const u8, cost: i128, tags: std.StringHashMap([]const u8)) focus.FocusRecord {
    return .{
        .BilledCost = cost,
        .EffectiveCost = cost,
        .UsageQuantity = 1,
        .UsageUnit = "units",
        .ChargeCategory = "Usage",
        .ResourceId = "res-1",
        .@"x-llm-model" = model,
        .timestamp = 1704067200, // 2024-01-01
        .tags = tags,
    };
}

test "Cardinality: Error Policy" {
    var interner = key_intern.StringInterner.init(testing.allocator);
    defer interner.deinit();

    var empty_tags = std.StringHashMap([]const u8).init(testing.allocator);
    defer empty_tags.deinit();

    // Limit 3, Policy Error
    var s = try stats.CalibrationStats.init(testing.allocator, &interner, 3, .@"error");
    defer s.deinit();

    try s.update(makeRecord("model-a", 10, empty_tags));
    try s.update(makeRecord("model-b", 10, empty_tags));
    try s.update(makeRecord("model-c", 10, empty_tags));

    // 4th model -> Error
    try testing.expectError(error.CardinalityExceeded, s.update(makeRecord("model-d", 10, empty_tags)));

    // Existing model -> OK
    try s.update(makeRecord("model-a", 10, empty_tags));
}

test "Cardinality: Degrade Policy" {
    var interner = key_intern.StringInterner.init(testing.allocator);
    defer interner.deinit();

    var empty_tags = std.StringHashMap([]const u8).init(testing.allocator);
    defer empty_tags.deinit();

    // Limit 2, Policy Degrade
    var s = try stats.CalibrationStats.init(testing.allocator, &interner, 2, .degrade);
    defer s.deinit();

    try s.update(makeRecord("model-a", 100, empty_tags));
    try s.update(makeRecord("model-b", 200, empty_tags));

    // 3rd model -> should become __other__
    try s.update(makeRecord("model-c", 50, empty_tags));

    // 4th model -> should become __other__ (aggregation)
    try s.update(makeRecord("model-d", 10, empty_tags));

    // Check stats
    try testing.expectEqual(@as(u64, 2), s.by_model.count()); // model-a + __other__
    try testing.expectEqual(true, s.cardinality_truncated);

    // Verify A
    const ka = try interner.intern("model-a");
    try testing.expectEqual(@as(i128, 100), s.by_model.get(ka).?.cost_micro);

    // Verify Other
    const kother = try interner.intern("__other__");
    const other_entry = s.by_model.get(kother);
    try testing.expect(other_entry != null);
    try testing.expectEqual(@as(i128, 260), other_entry.?.cost_micro); // 200 + 50 + 10
    try testing.expectEqual(@as(u64, 3), other_entry.?.count); // b, c, d
}
