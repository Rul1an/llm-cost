const std = @import("std");
const args = @import("../cli/args.zig");
const GlobalFlags = args.GlobalFlags;
// Verbosity is not pub in args, but we can verify it via the enum value or import verbosity relative
const Verbosity = @import("../cli/verbosity.zig").Verbosity;

test "global flags: pre-command only (legacy behavior)" {
    const argv = [_][]const u8{ "-v", "estimate" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expectEqual(Verbosity.verbose, result.global.verbosity);
    try std.testing.expect(result.command == .estimate);
}

test "global flags: post-command (new behavior)" {
    const argv = [_][]const u8{ "estimate", "-v" };
    // In new parser, this should set verbosity to verbose.
    // In old parser, it might error or ignore.
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expectEqual(Verbosity.verbose, result.global.verbosity);
    try std.testing.expect(result.command == .estimate);
}

test "global flags: mixed positioning" {
    // Last wins: -q (start) vs --verbose (end) -> verbose
    const argv = [_][]const u8{ "-q", "calibrate", "--verbose" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expectEqual(Verbosity.verbose, result.global.verbosity);
    try std.testing.expect(result.command == .calibrate);
}

test "global flags: precedence quiet wins if last" {
    const argv = [_][]const u8{ "--verbose", "check", "--quiet" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expectEqual(Verbosity.quiet, result.global.verbosity);
    try std.testing.expect(result.command == .check);
}

test "global flags: help precedence - global" {
    // llm-cost --help calibrate -> global help
    const argv = [_][]const u8{ "--help", "calibrate" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expect(result.global.help);
    // Command parsing might stop at help, or return calibrate.
    // Usually if global help is set, runnable executes help.
    // Important: parsing shouldn't error.
}

test "global flags: help precedence - command" {
    // llm-cost calibrate --help -> calibrate help
    const argv = [_][]const u8{ "calibrate", "--help" };
    const result = try args.parse(std.testing.allocator, &argv);

    // Global help should be FALSE
    try std.testing.expect(!result.global.help);
    // Command should be calibrate with help=true
    switch (result.command) {
        .calibrate => |c| try std.testing.expect(c.help),
        else => return error.TestExpectedCalibrate,
    }
}

test "global flags: zone2 help not global" {
    // llm-cost calibrate --help --quiet -> calibrate help, quiet
    const argv = [_][]const u8{ "calibrate", "--help", "--quiet" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expect(!result.global.help);
    try std.testing.expectEqual(Verbosity.quiet, result.global.verbosity);

    switch (result.command) {
        .calibrate => |c| try std.testing.expect(c.help),
        else => return error.TestExpectedCalibrate,
    }
}

test "global flags: terminator stops global parsing" {
    // llm-cost --quiet -- calibrate
    // -- stops global scan. "calibrate" becomes command (if logic supports it) OR "calibrate" is just an arg to... wait.
    // Spec: "Check for --. If found, stop scanning; the next arg is the Command".
    // So "llm-cost --quiet -- calibrate" ->
    // -q found (global).
    // -- found (terminator).
    // Next arg "calibrate" -> Command.

    const argv = [_][]const u8{ "--quiet", "--", "calibrate" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expectEqual(Verbosity.quiet, result.global.verbosity);
    try std.testing.expect(result.command == .calibrate);
}

test "global flags: terminator treats flags as positional" {
    // llm-cost Check -- --quiet
    // --quiet should be in Check args, NOT global.
    const argv = [_][]const u8{ "check", "--", "--quiet" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expectEqual(Verbosity.normal, result.global.verbosity);
    switch (result.command) {
        .check => |c| {
            // Legacy commands receive raw tail, including terminator.
            try std.testing.expectEqualStrings("--", c.args[0]);
            try std.testing.expectEqualStrings("--quiet", c.args[1]);
        },
        else => return error.TestExpectedCheck,
    }
}

test "global flags: unknown flag in zone 1 is error" {
    // llm-cost --unknown calibrate
    const argv = [_][]const u8{ "--unknown", "calibrate" };
    // Should return UnknownFlag, NOT silently ignore
    try std.testing.expectError(args.ParseError.UnknownFlag, args.parse(std.testing.allocator, &argv));
}

test "global flags: help overrides command" {
    // llm-cost --help calibrate
    // Should return result.command = .help, NOT .calibrate
    const argv = [_][]const u8{ "--help", "calibrate" };
    const result = try args.parse(std.testing.allocator, &argv);

    try std.testing.expect(result.global.help);
    try std.testing.expect(result.command == .help);
}

test "calibrate: fails on positional args" {
    // llm-cost calibrate some-file
    // Calibrate currently takes no positionals. Should error.
    const argv = [_][]const u8{ "calibrate", "some-file" };
    // parse will call parseCommand -> parseCalibrate.
    // parseCalibrate should return specific error or UnknownFlag
    // User suggests UnknownFlag or InvalidValue.
    // Let's assume UnknownFlag for anything it doesn't parse.
    try std.testing.expectError(args.ParseError.UnknownFlag, args.parse(std.testing.allocator, &argv));
}

test "calibrate: fails on positional args after terminator" {
    // llm-cost calibrate -- --quiet
    // --quiet is positional here. Should error.
    // Note: Zone 2 global parsing stops at --.
    // parseCalibrate receives "--", "--quiet".
    const argv = [_][]const u8{ "calibrate", "--", "--quiet" };
    try std.testing.expectError(args.ParseError.UnknownFlag, args.parse(std.testing.allocator, &argv));
}

test "global flags: version overrides command" {
    const argv = [_][]const u8{ "--version", "estimate" };
    const result = try args.parse(std.testing.allocator, &argv);
    try std.testing.expect(result.global.version);
    try std.testing.expect(result.command == .version);
}
