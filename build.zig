const std = @import("std");

// build.zig for Zig 0.14.0 (stable)
// Note: Using deprecated but working root_source_file API
// This avoids the 0.15 "Writergate" I/O breaking changes

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const version = std.SemanticVersion{ .major = 0, .minor = 7, .patch = 0 };
    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .version = version,
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
    // Golden tests (Streaming Parity Runner)
    const golden_exe = b.addExecutable(.{
        .name = "golden-test",
        .root_source_file = b.path("src/golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(golden_exe);

    const run_golden = b.addRunArtifact(golden_exe);
    if (b.args) |args| {
        run_golden.addArgs(args);
    }

    const golden_step = b.step("test-golden", "Run golden parity tests against tiktoken");
    golden_step.dependOn(&run_golden.step);

    // Tools: Vocabulary Converter
    const convert_vocab_exe = b.addExecutable(.{
        .name = "convert-vocab",
        .root_source_file = b.path("tools/convert_vocab.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(convert_vocab_exe);

    const run_convert_vocab = b.addRunArtifact(convert_vocab_exe);
    if (b.args) |args| {
        run_convert_vocab.addArgs(args);
    }
    const convert_step = b.step("run-convert-vocab", "Run vocabulary converter");
    convert_step.dependOn(&run_convert_vocab.step);

    // Benchmark
    const bench_exe = b.addExecutable(.{
        .name = "llm-cost-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize for benchmarks
    });

    // Provide access to tokenizer modules
    // Add module imports if tokenizer/mod.zig depends on others (it uses local imports, so should be fine if paths are relative to mod.zig)

    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run performance benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);

    // Pass args to benchmark runner
    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    bench_step.dependOn(&run_bench.step);
}
