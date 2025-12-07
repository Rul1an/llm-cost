const std = @import("std");

pub fn build(b: *std.Build) void {
    // Global options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded =
        b.option(bool, "single-threaded", "Build in single-threaded mode") orelse false;
    const strip =
        b.option(bool, "strip", "Strip debug info from binary") orelse false;

    // --- Main executable ----------------------------------------------------
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .strip = strip,
    });

    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_module = root_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run llm-cost");
    run_step.dependOn(&run_cmd.step);

    // --- Tests: always on host target --------------------------------------
    const host_target = b.resolveTargetQuery(.{});

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .strip = strip,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
