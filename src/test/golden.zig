const std = @import("std");

pub fn runGolden(
    case: struct {
        name: []const u8,
        argv: []const []const u8,
        stdout_path: []const u8,
        stderr_path: []const u8,
        exitcode_path: []const u8,
        // Optional input piping
        stdin_path: ?[]const u8 = null,
    },
) !void {
    const alloc = std.testing.allocator;

    // 1. Run process
    var child = std.process.Child.init(case.argv, alloc);
    child.stdin_behavior = if (case.stdin_path != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (case.stdin_path) |path| {
        const input = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
        defer alloc.free(input);
        try child.stdin.?.writer().writeAll(input);
        child.stdin.?.close();
        child.stdin = null;
    }

    const stdout_bytes = try child.stdout.?.reader().readAllAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(stdout_bytes);

    const stderr_bytes = try child.stderr.?.reader().readAllAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(stderr_bytes);

    const term = try child.wait();
    const got_exit: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    // 2. Load golden files
    const cwd = std.fs.cwd();

    const golden_stdout = try cwd.readFileAlloc(alloc, case.stdout_path, 10 * 1024 * 1024);
    defer alloc.free(golden_stdout);

    const golden_stderr = try cwd.readFileAlloc(alloc, case.stderr_path, 10 * 1024 * 1024);
    defer alloc.free(golden_stderr);

    const exitcode_file = try cwd.readFileAlloc(alloc, case.exitcode_path, 32);
    defer alloc.free(exitcode_file);
    const golden_exit = try std.fmt.parseInt(u8, std.mem.trim(u8, exitcode_file, " \r\n\t"), 10);

    // 3. Compare with explicit failures
    std.testing.expectEqualStrings(golden_stdout, stdout_bytes) catch |err| {
        std.debug.print("STDOUT MISMATCH: {s}\nEXPECTED:\n{s}\nACTUAL:\n{s}\n", .{ case.name, golden_stdout, stdout_bytes });
        return err;
    };

    std.testing.expectEqualStrings(golden_stderr, stderr_bytes) catch |err| {
        std.debug.print("STDERR MISMATCH: {s}\nEXPECTED:\n{s}\nACTUAL:\n{s}\n", .{ case.name, golden_stderr, stderr_bytes });
        return err;
    };

    std.testing.expectEqual(golden_exit, got_exit) catch |err| {
        std.debug.print("EXIT CODE MISMATCH: {s}\nEXPECTED: {d}\nACTUAL: {d}\n", .{ case.name, golden_exit, got_exit });
        return err;
    };
}

test "golden: tokens/hello" {
    try runGolden(.{
        .name = "tokens/hello",
        .argv = &.{ "zig-out/bin/llm-cost", "tokens", "--format", "json", "--model", "gpt-4o", "testdata/golden/tokens/hello.in.txt" },
        .stdout_path = "testdata/golden/tokens/hello.stdout.json",
        .stderr_path = "testdata/golden/tokens/hello.stderr.txt",
        .exitcode_path = "testdata/golden/tokens/hello.exitcode.txt",
    });
}

test "golden: tokens/bad_model" {
    try runGolden(.{
        .name = "tokens/bad_model",
        .argv = &.{ "zig-out/bin/llm-cost", "tokens", "--format", "json", "--model", "foo/bar", "testdata/golden/tokens/bad_model.in.txt" },
        .stdout_path = "testdata/golden/tokens/bad_model.stdout.json",
        .stderr_path = "testdata/golden/tokens/bad_model.stderr.txt",
        .exitcode_path = "testdata/golden/tokens/bad_model.exitcode.txt",
    });
}

test "golden: price/simple_price" {
    try runGolden(.{
        .name = "price/simple_price",
        .argv = &.{ "zig-out/bin/llm-cost", "price", "--format", "json", "--model", "gpt-4o", "--tokens-in", "6", "--tokens-out", "0" },
        .stdout_path = "testdata/golden/price/simple_price.stdout.json",
        .stderr_path = "testdata/golden/price/simple_price.stderr.txt",
        .exitcode_path = "testdata/golden/price/simple_price.exitcode.txt",
    });
}

test "golden: pipe/one_line" {
    try runGolden(.{
        .name = "pipe/one_line",
        .argv = &.{ "zig-out/bin/llm-cost", "pipe", "--format", "json", "--summary", "--summary-format", "json", "--quiet", "--model", "gpt-4o", "--mode", "price" },
        .stdin_path = "testdata/golden/pipe/one_line.in.jsonl",
        .stdout_path = "testdata/golden/pipe/one_line.stdout.jsonl",
        .stderr_path = "testdata/golden/pipe/one_line.stderr.json",
        .exitcode_path = "testdata/golden/pipe/one_line.exitcode.txt",
    });
}

test "golden: pipe/partial_fail" {
    try runGolden(.{
        .name = "pipe/partial_fail",
        .argv = &.{ "zig-out/bin/llm-cost", "pipe", "--format", "json", "--summary", "--summary-format", "json", "--quiet", "--model", "gpt-4o", "--mode", "price" },
        .stdin_path = "testdata/golden/pipe/partial_fail.in.jsonl",
        .stdout_path = "testdata/golden/pipe/partial_fail.stdout.jsonl",
        .stderr_path = "testdata/golden/pipe/partial_fail.stderr.json",
        .exitcode_path = "testdata/golden/pipe/partial_fail.exitcode.txt",
    });
}
