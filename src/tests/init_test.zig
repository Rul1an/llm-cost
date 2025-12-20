const std = @import("std");
const init_cmd = @import("../commands/init.zig");

test "init: creates new file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = tmp.dir;
    // We modify run signature to take cwd: std.fs.Dir to allow safe testing
    // without process-level CWD changes.

    const args = [_][]const u8{};
    try init_cmd.run(std.testing.allocator, &args, cwd, std.io.null_writer, std.io.null_writer);

    // Verify file exists
    const f = try cwd.openFile("llm-cost.toml", .{});
    defer f.close();

    // basic content check
    const stat = try f.stat();
    try std.testing.expect(stat.size > 0);
}

test "init: fails if file exists (no force)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = tmp.dir;

    // Create dummy file
    try cwd.writeFile(.{ .sub_path = "llm-cost.toml", .data = "exists" });

    const args = [_][]const u8{};
    // Expect error
    if (init_cmd.run(std.testing.allocator, &args, cwd, std.io.null_writer, std.io.null_writer)) {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.FileExists, err);
    }
}

test "init: overwrites if force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = tmp.dir;

    try cwd.writeFile(.{ .sub_path = "llm-cost.toml", .data = "old" });

    const args = [_][]const u8{"--force"};
    try init_cmd.run(std.testing.allocator, &args, cwd, std.io.null_writer, std.io.null_writer);

    const data = try cwd.readFileAlloc(std.testing.allocator, "llm-cost.toml", 1024);
    defer std.testing.allocator.free(data);
    try std.testing.expect(!std.mem.eql(u8, data, "old"));
}
