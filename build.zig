const std = @import("std");

// build.zig for Zig 0.14.0 (stable)
// Note: Using deprecated but working root_source_file API
// This avoids the 0.15 "Writergate" I/O breaking changes

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Policy Options
    const opt_strip = b.option(bool, "strip", "Strip symbols (default: true for non-Debug)") orelse (optimize != .Debug);

    // LTO defaults:
    // - Linux: true (works reliably with LLD)
    // - macOS: false (requires LLD, complicates native build)
    // - Windows: false (current toolchain issues with LTO+libc)
    // Summary: Linux on, Darwin/Windows off by default.
    const is_macos = target.result.os.tag == .macos;
    const is_windows = target.result.os.tag == .windows;
    const lto_default = (optimize != .Debug and !is_macos and !is_windows);

    const opt_lto = b.option(bool, "lto", "Enable LTO") orelse lto_default;

    // Target Resolution (CPU Policy)
    // -Dcpu is handled by standardTargetOptions. We trust 'target'.
    // Default usually implies baseline/native depending on context, but we want baseline distribution.
    // If target.query.cpu_model is not explicitly native via -Dcpu=native, we assume baseline is preferred for release.
    const resolved_target = target;
    // (Logic below checks if we strictly need to modify something, but standardTargetOptions is generally sufficient if we don't force native)

    // Main executable
    var version = std.SemanticVersion{ .major = 1, .minor = 7, .patch = 0 };
    if (b.option([]const u8, "version", "Override version string")) |ver_str| {
        version = std.SemanticVersion.parse(ver_str) catch std.debug.panic("Invalid version format: {s}", .{ver_str});
    }

    const exe = b.addExecutable(.{
        .name = "llm-cost",
        .root_source_file = b.path("src/main.zig"),
        .target = resolved_target,
        .optimize = optimize,
        .version = version,
    });

    // Apply Policies
    exe.root_module.strip = opt_strip;
    exe.want_lto = opt_lto;
    exe.linkLibC();

    b.installArtifact(exe);

    // Optional "Safe" Flavor
    const build_safe = b.option(bool, "build_safe", "Also build ReleaseSafe artifact (llm-cost-safe)") orelse false;
    if (build_safe) {
        const exe_safe = b.addExecutable(.{
            .name = "llm-cost-safe",
            .root_source_file = b.path("src/main.zig"),
            .target = resolved_target,
            .optimize = .ReleaseSafe,
            .version = version,
        });
        exe_safe.root_module.strip = opt_strip;
        exe_safe.want_lto = opt_lto;
        exe_safe.linkLibC();
        b.installArtifact(exe_safe);
    }

    // Create manifest module common to tools and tests
    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("src/core/pricing/manifest.zig"),
    });

    // Documentation generation disabled for 0.14.0 CI stability
    // const install_docs = b.addInstallDirectory(.{
    //    .source_dir = exe.getEmittedDocs(),
    //    .install_dir = .prefix,
    //    .install_subdir = "docs",
    // });
    // const docs_step = b.step("docs", "Generate documentation");
    // docs_step.dependOn(&install_docs.step);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run llm-cost");
    run_step.dependOn(&run_cmd.step);

    // Unit Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("manifest", manifest_mod);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| {
        run_unit_tests.addArgs(args);
    }

    // Security Tests
    const security_tests = b.addTest(.{
        .root_source_file = b.path("src/tests/security_test.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    security_tests.root_module.addImport("manifest", manifest_mod);
    const run_security_tests = b.addRunArtifact(security_tests);

    // Determinism Tests
    const determinism_tests = b.addTest(.{
        .root_source_file = b.path("src/determinism_test.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    const run_determinism_tests = b.addRunArtifact(determinism_tests);

    const test_calibration_core = b.addTest(.{
        .root_source_file = b.path("src/tests/calibration_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Expose calibration modules to test
    const cal_types = b.createModule(.{ .root_source_file = b.path("src/calibration/types.zig") });
    const cal_intern = b.createModule(.{ .root_source_file = b.path("src/calibration/key_intern.zig") });
    const cal_lines = b.createModule(.{ .root_source_file = b.path("src/calibration/line_reader.zig") });

    // focus_import depends on types + lines
    const cal_focus = b.createModule(.{
        .root_source_file = b.path("src/calibration/focus_import.zig"),
    });
    cal_focus.addImport("types.zig", cal_types);
    cal_focus.addImport("line_reader.zig", cal_lines);

    test_calibration_core.root_module.addImport("../calibration/types.zig", cal_types);
    test_calibration_core.root_module.addImport("../calibration/key_intern.zig", cal_intern);
    test_calibration_core.root_module.addImport("../calibration/line_reader.zig", cal_lines);
    test_calibration_core.root_module.addImport("../calibration/focus_import.zig", cal_focus);

    const run_calibration_core_tests = b.addRunArtifact(test_calibration_core);

    // New Integration Tests
    const test_calibration_integration = b.addTest(.{
        .root_source_file = b.path("src/tests/calibration_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Allow integration test to import mod.zig (which pulls in everything else via relative imports)
    // We create a "calibration" module for cleanliness
    const cal_mod = b.createModule(.{
        .root_source_file = b.path("src/calibration/mod.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    test_calibration_integration.root_module.addImport("calibration", cal_mod);

    const run_calibration_integration_tests = b.addRunArtifact(test_calibration_integration);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_security_tests.step);
    test_step.dependOn(&run_determinism_tests.step);
    test_step.dependOn(&run_calibration_core_tests.step);
    test_step.dependOn(&run_calibration_integration_tests.step);

    // Hybrid Parser Tests (PR7.2)
    const test_focus_hybrid = b.addTest(.{
        .root_source_file = b.path("src/tests/focus_hybrid.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Inject dependencies same as calibration core
    test_focus_hybrid.root_module.addImport("../calibration/types.zig", cal_types);
    test_focus_hybrid.root_module.addImport("../calibration/key_intern.zig", cal_intern);
    test_focus_hybrid.root_module.addImport("../calibration/line_reader.zig", cal_lines);
    test_focus_hybrid.root_module.addImport("../calibration/focus_import.zig", cal_focus);

    const run_focus_hybrid = b.addRunArtifact(test_focus_hybrid);
    test_step.dependOn(&run_focus_hybrid.step);

    // Cardinality Tests (PR7.4)
    const test_cardinality = b.addTest(.{
        .root_source_file = b.path("src/tests/cardinality_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Same dependencies as calibration integration
    test_cardinality.root_module.addImport("calibration", cal_mod);
    // Wire required calibration modules for cardinality tests.
    test_cardinality.root_module.addImport("calibration", cal_mod);

    const run_cardinality = b.addRunArtifact(test_cardinality);
    test_step.dependOn(&run_cardinality.step);
    const step_cardinality = b.step("test-cardinality", "Run cardinality tests (PR7.4)");
    step_cardinality.dependOn(&run_cardinality.step);

    // Persistence Tests (PR7.3)
    const test_persistence = b.addTest(.{
        .root_source_file = b.path("src/tests/persistence_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_persistence.root_module.addAnonymousImport("persistence", .{
        .root_source_file = b.path("src/core/pricing/persistence.zig"),
    });

    const run_persistence = b.addRunArtifact(test_persistence);
    test_step.dependOn(&run_persistence.step);
    // Fuzz/Chaos tests
    const fuzz_tests = b.addTest(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz/chaos tests");
    fuzz_step.dependOn(&run_fuzz.step);

    // Parity tests (vs tiktoken)
    const parity_tests = b.addTest(.{
        .root_source_file = b.path("src/parity_test.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    const parity_step = b.step("test-parity", "Run parity tests against tiktoken");
    parity_step.dependOn(&run_parity_tests.step);

    // Create Tokenizer Module
    const tokenizer_mod = b.createModule(.{
        .root_source_file = b.path("src/tokenizer/mod.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });

    // Create Core Module (needed for transitive imports if not package-based)
    // However, since we don't have a package manager setup for 'core',
    // we might need to add it to tokenizer_mod imports IF tokenizer/mod.zig used @import("core").
    // But tokenizer uses relative imports to ../core.
    // This usually requires the file to be under the same root.
    // If this fails, we will solve the import issue in the source.

    // Differential Fuzzing (SIMD vs Scalar)
    const simd_fuzz_tests = b.addTest(.{
        .root_source_file = b.path("src/tests/simd_compare.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    simd_fuzz_tests.root_module.addImport("tokenizer", tokenizer_mod);

    const run_simd_fuzz = b.addRunArtifact(simd_fuzz_tests);
    const simd_fuzz_step = b.step("test-simd-fuzz", "Run differential fuzzing (SIMD vs Scalar)");
    simd_fuzz_step.dependOn(&run_simd_fuzz.step);

    // Deep Verification: Deterministic SIMD Boundaries
    const simd_boundary_tests = b.addTest(.{
        .root_source_file = b.path("src/tests/simd_boundaries.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    simd_boundary_tests.root_module.addImport("tokenizer", tokenizer_mod);

    const run_simd_boundaries = b.addRunArtifact(simd_boundary_tests);
    const simd_boundary_step = b.step("test-simd-boundaries", "Run deterministic SIMD boundary traps");
    simd_boundary_step.dependOn(&run_simd_boundaries.step);

    // Golden tests (CLI contract)
    // Tokenizer Parity Runner (Executes src/tokenizer_parity_runner.zig)
    const parity_runner_exe = b.addExecutable(.{
        .name = "tokenizer-runner",
        .root_source_file = b.path("src/tokenizer_parity_runner.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    b.installArtifact(parity_runner_exe);

    const run_parity_runner = b.addRunArtifact(parity_runner_exe);
    if (b.args) |args| {
        run_parity_runner.addArgs(args);
    }

    const parity_runner_step = b.step("run-tokenizer-parity", "Run tokenizer parity runner (corpus_v2)");
    parity_runner_step.dependOn(&run_parity_runner.step);

    // Golden Tester (CLI harness)
    const golden_tests = b.addTest(.{
        .root_source_file = b.path("src/golden_test.zig"),
        .target = resolved_target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run golden tests (CLI contract)");
    golden_step.dependOn(&run_golden_tests.step);

    // Guardrail Tests (Memory/Fairness)
    const guardrail_tests = b.addTest(.{
        .root_source_file = b.path("src/calibrate/guardrail_test.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    const run_guardrail = b.addRunArtifact(guardrail_tests);
    const guardrail_step = b.step("test-guardrail", "Run guardrail tests (memory/fairness limits)");
    guardrail_step.dependOn(&run_guardrail.step);

    const meta = b.addTest(.{
        .root_source_file = b.path("src/tests/metamorphic/mod.zig"),
        .target = resolved_target,
        .optimize = optimize,
        .single_threaded = true,
    });
    // Inject dependencies matching those used in src/tests/metamorphic/mod.zig
    meta.root_module.addImport("calibration", cal_mod);

    // Create module for binary format to share with tools
    const pricing_binary_mod = b.createModule(.{
        .root_source_file = b.path("src/core/pricing/binary.zig"),
    });

    // Create pricing module to inject
    const pricing_mod = b.createModule(.{
        .root_source_file = b.path("src/core/pricing/mod.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    // Pricing needs binary_pricing likely
    pricing_mod.addImport("binary_pricing", pricing_binary_mod);
    // Defensively inject manifest
    pricing_mod.addImport("manifest", manifest_mod);

    meta.root_module.addImport("pricing", pricing_mod);
    meta.root_module.addImport("manifest", manifest_mod);

    // Inject helpers
    const helpers_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/helpers/mod.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    meta.root_module.addImport("helpers", helpers_mod);

    const run_meta = b.addRunArtifact(meta);
    const meta_step = b.step("test-metamorphic", "Run metamorphic/invariant tests");
    meta_step.dependOn(&run_meta.step);
    // Intentionally NOT wired into the default `test` step to keep CI fast.

    const tools_step = b.step("tools", "Install auxiliary tools (signer, publisher, converter)");

    // Tools: Vocabulary Converter
    const convert_vocab_exe = b.addExecutable(.{
        .name = "convert-vocab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/convert_vocab.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    // b.installArtifact(convert_vocab_exe);
    const install_vocab = b.addInstallArtifact(convert_vocab_exe, .{});
    tools_step.dependOn(&install_vocab.step);

    const run_convert_vocab = b.addRunArtifact(convert_vocab_exe);
    if (b.args) |args| {
        run_convert_vocab.addArgs(args);
    }
    const convert_step = b.step("run-convert-vocab", "Run vocabulary converter");
    convert_step.dependOn(&run_convert_vocab.step);

    // Tools: Pricing Compiler (Phase 2)
    const compile_pricing_exe = b.addExecutable(.{
        .name = "compile-pricing",
        .root_source_file = b.path("tools/compile_pricing.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });

    // Link binary pricing module to compile_pricing_exe
    compile_pricing_exe.root_module.addImport("binary_pricing", pricing_binary_mod);

    // b.installArtifact(compile_pricing_exe);
    const install_pricing = b.addInstallArtifact(compile_pricing_exe, .{});
    tools_step.dependOn(&install_pricing.step);

    const run_compile_pricing = b.addRunArtifact(compile_pricing_exe);
    if (b.args) |args| {
        run_compile_pricing.addArgs(args);
    }
    const compile_pricing_step = b.step("run-compile-pricing", "Run pricing DB compiler");
    compile_pricing_step.dependOn(&run_compile_pricing.step);

    // Benchmark
    const bench_exe = b.addExecutable(.{
        .name = "llm-cost-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_suite.zig"),
            .target = resolved_target,
            .optimize = optimize, // Enforced by bench_suite execution
        }),
    });

    const bench_step = b.step("bench", "Run performance benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);

    // Pass args to benchmark runner
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    bench_step.dependOn(&run_bench.step);

    // Tools: Manifest Signer
    const signer_exe = b.addExecutable(.{
        .name = "sign-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sign_manifest.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });

    // Create manifest module to allow access from tools/
    signer_exe.root_module.addImport("manifest", manifest_mod);

    // b.installArtifact(signer_exe);
    const install_signer = b.addInstallArtifact(signer_exe, .{});
    tools_step.dependOn(&install_signer.step);

    const run_signer = b.addRunArtifact(signer_exe);
    if (b.args) |args| {
        run_signer.addArgs(args);
    }
    const signer_step = b.step("run-signer", "Run manifest signer");
    signer_step.dependOn(&run_signer.step);

    // Tools: Release Publisher (Phase 5)
    // Compresses, Hashes, Signs, and Generates Manifest
    const publisher_exe = b.addExecutable(.{
        .name = "publish-release",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/publish_release.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    publisher_exe.root_module.addImport("manifest", manifest_mod);
    // b.installArtifact(publisher_exe);
    const install_publisher = b.addInstallArtifact(publisher_exe, .{});
    tools_step.dependOn(&install_publisher.step);

    const run_publisher = b.addRunArtifact(publisher_exe);
    if (b.args) |args| {
        run_publisher.addArgs(args);
    }
    const publisher_step = b.step("run-publisher", "Run release publisher");
    publisher_step.dependOn(&run_publisher.step); // Found usage from error log context, ensuring dependOn is called
}
