const std = @import("std");

// build.zig for Zig 0.14.0 (stable)
// Note: Using deprecated but working root_source_file API
// This avoids the 0.15 "Writergate" I/O breaking changes

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run llm-cost");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Fuzz/Chaos tests
    // Changed from addExecutable to addTest because src/fuzz_test.zig uses 'test' blocks without 'main'
    const fuzz_tests = b.addTest(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz/chaos tests");
    fuzz_step.dependOn(&run_fuzz.step);

    // Parity tests (vs tiktoken)
    const parity_tests = b.addTest(.{
        .root_source_file = b.path("src/parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    const parity_step = b.step("test-parity", "Run parity tests against tiktoken");
    parity_step.dependOn(&run_parity_tests.step);

    // Golden tests (CLI contract)
    const golden_tests = b.addTest(.{
        .root_source_file = b.path("src/golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run golden CLI tests");
    golden_step.dependOn(&run_golden_tests.step);

    // Benchmark - DISABLED: src/bench.zig does not exist yet
    // Uncomment when bench.zig is created:
    // const bench_exe = b.addExecutable(.{
    //     .name = "llm-cost-bench",
    //     .root_source_file = b.path("src/bench.zig"),
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // b.installArtifact(bench_exe);
    // const bench_step = b.step("bench", "Build and run benchmarks");
    // const run_bench = b.addRunArtifact(bench_exe);
    // bench_step.dependOn(&run_bench.step);
}
