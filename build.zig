const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Hard: 0.13.x only. Patch versions allowed, 0.14+ not.
    if (!(builtin.zig_version.major == 0 and builtin.zig_version.minor == 13)) {
        @compileError("llm-cost v0.3 currently requires Zig 0.13.x; found " ++ builtin.zig_version_string);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});



    // Modules
    const lib_mod = b.addModule("llm_cost", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
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

    const registry_v2_test = b.addTest(.{
        .root_source_file = b.path("src/test/model_registry_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    registry_v2_test.root_module.addImport("llm_cost", lib_mod);

    const fuzz_tests = b.addTest(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const run_registry_v2 = b.addRunArtifact(registry_v2_test);
    const run_fuzz = b.addRunArtifact(fuzz_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_registry_v2.step);

    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz.step);

    // Parity Test
    const parity_test = b.addTest(.{
        .root_source_file = b.path("src/test/parity.zig"),
        .target = target,
        .optimize = optimize,
    });
    parity_test.root_module.addImport("llm_cost", lib_mod);
    const run_parity = b.addRunArtifact(parity_test);
    const parity_step = b.step("test-parity", "Run parity check against corpus");
    parity_step.dependOn(&run_parity.step);



    // Benchmark Tool
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("tools/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always benchmark in ReleaseFast
    });
    bench_exe.root_module.addImport("llm_cost", lib_mod);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("benchmark", "Run performance benchmark");
    bench_step.dependOn(&run_bench.step);

    // Microbenchmark BPE
    const bench_bpe_exe = b.addExecutable(.{
        .name = "bench_bpe",
        .root_source_file = b.path("src/bench/bench_bpe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_bpe_exe.root_module.addImport("llm_cost", lib_mod);

    const run_bench_bpe = b.addRunArtifact(bench_bpe_exe);
    const bench_bpe_step = b.step("bench-bpe", "Run BPE microbenchmark");
    bench_bpe_step.dependOn(&run_bench_bpe.step);

    // Microbenchmark BPE v2
    const bench_bpe_v2_exe = b.addExecutable(.{
        .name = "bench_bpe_v2",
        .root_source_file = b.path("src/bench/bench_bpe_v2.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_bpe_v2_exe.root_module.addImport("llm_cost", lib_mod);

    const run_bench_bpe_v2 = b.addRunArtifact(bench_bpe_v2_exe);
    const bench_bpe_v2_step = b.step("bench-bpe-v2", "Run BPE v2 microbenchmark");
    bench_bpe_v2_step.dependOn(&run_bench_bpe_v2.step);

    // Bench Legacy
    const bench_legacy_exe = b.addExecutable(.{
        .name = "bench_legacy",
        .root_source_file = b.path("src/bench/bench_legacy.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_legacy_exe.root_module.addImport("llm_cost", lib_mod);
    const run_bench_legacy = b.addRunArtifact(bench_legacy_exe);
    const bench_legacy_step = b.step("bench-legacy", "Run Legacy BPE benchmark");
    bench_legacy_step.dependOn(&run_bench_legacy.step);
    // Golden Tests
    const golden_tests = b.addTest(.{
        .root_source_file = b.path("src/test/golden.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_golden = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run CLI golden tests");
    golden_step.dependOn(&run_golden.step);
}
