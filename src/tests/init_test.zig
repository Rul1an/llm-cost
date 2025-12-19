const std = @import("std");
const init_cmd = @import("../commands/init.zig");

test "init: creates new file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = tmp.dir;
    // We pass the directory as a string or handle CWD?
    // init.run usually operates on CWD.
    // To test safely, we should probably change CWD or pass dir to run?
    // init.zig run signature? `run(allocator, args)`?
    // If it uses fs.cwd(), we catch it via tmpDir?
    // Changing process CWD is risky for parallel tests.
    // But `init` command is high level.
    // Ideally refactor `init` to accept a `Dir` or `cwd_path`.
    // "No fluff": `init` operates in current directory.
    // Test:
    // Create tmp dir. Change process CWD to it?
    // std.os.chdir?
    // Single threaded test?

    // Pragmatic C-dev style:
    // Just pass the target directory handle implicitly?
    // Or modify `init.run` to accept `base_dir: std.fs.Dir`?
    // `main.zig` calls it.
    // Let's modify `run` signature to take `cwd: std.fs.Dir`.
    // Default main passes `std.fs.cwd()`. Test passes `tmp.dir`.

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
