const std = @import("std");
const cmd = @import("cmd.zig");
const Pricing = @import("../core/pricing/mod.zig");

test "Golden Test - U2 Basic" {
    // This looks for testdata relative to CWD
    // We assume CWD is project root or we construct paths appropriately.
    // In 'zig build test', usually cache dir, but we can rely on relative if we pass -Mroot.
    // Safest is to use build.zig provided path or just relative and ensure CWD.

    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();

    // inputs
    const est_path = "testdata/calibrate/u2_basic/estimates.json";
    const csv_path = "testdata/calibrate/u2_basic/actuals.focus.csv";
    const expected_path = "testdata/calibrate/u2_basic/expected.factors.toml";

    // Verify files exist
    cwd.access(est_path, .{}) catch return error.SkipZigTest; // Skip if data missing

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    const args = [_][]const u8{ "calibrate", "--estimates", est_path, "--csv", csv_path };

    // Run 1
    const exit1 = try cmd.run(allocator, &args, &registry, stdout_buf.writer(), stderr_buf.writer());
    try std.testing.expectEqual(@as(u8, 0), exit1);

    // Read Expected
    const expected = try cwd.readFileAlloc(allocator, expected_path, 1024 * 1024);
    defer allocator.free(expected);

    // Assert Equality (Byte for Byte)
    try std.testing.expectEqualStrings(expected, stdout_buf.items);

    // Run 2 (Determinism Check)
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();

    const exit2 = try cmd.run(allocator, &args, &registry, stdout_buf.writer(), stderr_buf.writer());
    try std.testing.expectEqual(@as(u8, 0), exit2);
    try std.testing.expectEqualStrings(expected, stdout_buf.items);
}

test "Golden Test - U2 Fuzzy Match" {
    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();

    // inputs
    const est_path = "testdata/calibrate/u2_fuzzy/estimates.json";
    const csv_path = "testdata/calibrate/u2_fuzzy/actuals.focus.csv";
    const expected_path = "testdata/calibrate/u2_fuzzy/expected.factors.toml";

    // Verify files exist
    cwd.access(est_path, .{}) catch return error.SkipZigTest;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    // Use --match fuzzy
    const args = [_][]const u8{ "calibrate", "--estimates", est_path, "--csv", csv_path, "--match", "fuzzy" };

    const exit3 = try cmd.run(allocator, &args, &registry, stdout_buf.writer(), stderr_buf.writer());
    try std.testing.expectEqual(@as(u8, 0), exit3);

    const expected = try cwd.readFileAlloc(allocator, expected_path, 1024 * 1024);
    defer allocator.free(expected);

    const expected_trim = std.mem.trimRight(u8, expected, " \t\r\n");
    const actual_trim = std.mem.trimRight(u8, stdout_buf.items, " \t\r\n");

    try std.testing.expectEqualStrings(expected_trim, actual_trim);
}
