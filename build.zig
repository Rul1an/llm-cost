const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded =
        b.option(bool, "single-threaded", "Build in single-threaded mode") orelse false;
    const strip =
        b.option(bool, "strip", "Strip debug info from binary") orelse false;

    // We rely on simple relative imports in src/, so no complex module wiring mostly.
    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_module = b.createModule(.{
             .root_source_file = b.path("src/main.zig"),
             .target = target,
             .optimize = optimize,
             .strip = strip,
             .single_threaded = single_threaded,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run llm-cost");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
