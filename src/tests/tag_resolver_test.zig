const std = @import("std");
const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;
const Resolver = @import("../calibration/tag_resolver.zig").Resolver;
const focus = @import("../calibration/focus_import.zig");

test "Resolver: defaults" {
    const allocator = std.testing.allocator;
    var resolver = try Resolver.init(allocator, null);
    defer resolver.deinit();

    var tags_map = std.StringHashMap([]const u8).init(allocator);
    defer tags_map.deinit();
    try tags_map.put("agent", "Agent007");

    // Mock record
    const rec = focus.FocusRecord{
        .BilledCost = 0,
        .EffectiveCost = 0,
        .UsageQuantity = 0,
        .UsageUnit = "",
        .ChargeCategory = "",
        .ResourceId = "gpt-4o",
        .tags = tags_map,
    };

    // Test "model" -> ResourceId
    if (resolver.resolve(&rec, "model")) |val| {
        try expectEqualStrings("gpt-4o", val);
    } else return error.TestExpectedFound;

    // Test "agent" -> Tags.agent
    if (resolver.resolve(&rec, "agent")) |val| {
        try expectEqualStrings("Agent007", val);
    } else return error.TestExpectedFound;

    // Test missing tag -> null
    if (resolver.resolve(&rec, "tool")) |_| {
        return error.TestExpectedNull;
    }

    // Test direct column name (passthrough)
    if (resolver.resolve(&rec, "UsageUnit")) |val| {
        try expectEqualStrings("", val);
    }
}

test "Resolver: override" {
    const allocator = std.testing.allocator;

    var config = std.StringHashMap([]const u8).init(allocator);
    defer config.deinit();
    try config.put("agent", "ResourceId"); // Override agent to point to ResourceId
    try config.put("run_id", "Tags.github_run"); // New mapping

    var resolver = try Resolver.init(allocator, config);
    defer resolver.deinit();

    var tags_map = std.StringHashMap([]const u8).init(allocator);
    defer tags_map.deinit();
    try tags_map.put("agent", "IgnoredTag");
    try tags_map.put("github_run", "12345");

    const rec = focus.FocusRecord{
        .BilledCost = 0,
        .EffectiveCost = 0,
        .UsageQuantity = 0,
        .UsageUnit = "",
        .ChargeCategory = "",
        .ResourceId = "gpt-4o",
        .tags = tags_map,
    };

    // "agent" should now map to ResourceId "gpt-4o"
    if (resolver.resolve(&rec, "agent")) |val| {
        try expectEqualStrings("gpt-4o", val);
    } else return error.TestExpectedFound;

    // "run_id" should map to Tags.github_run
    if (resolver.resolve(&rec, "run_id")) |val| {
        try expectEqualStrings("12345", val);
    } else return error.TestExpectedFound;
}
