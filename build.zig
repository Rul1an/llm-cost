const std = @import("std");

pub fn build(b: *std.Build) void {
    // Cross-target from `-Dtarget=…`
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install binary to zig-out/bin + standard install prefix
    b.installArtifact(exe);

    // zig build run [-- args…]
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run llm-cost");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: always native host, not cross-target
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.host, // prevents cross-compilation of tests
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
