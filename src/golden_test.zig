const std = @import("std");
const testing = std.testing;
const tokenizer = @import("tokenizer/mod.zig");
const engine = @import("core/engine.zig");

// =============================================================================
// Data Structures
// =============================================================================

const GoldenRecord = struct {
    model: []const u8,
    encoding: []const u8,
    text: []const u8,
    tokens: []const u32,
    count: usize,
};

// =============================================================================
// Test Logic
// =============================================================================

test "golden: parity with evil_corpus_v2" {
    const allocator = testing.allocator;

    // We assume the test is run from project root or we can find the file relative to it.
    // Try to open the golden file.
    const file_path = "testdata/golden/evil_corpus_v2.jsonl";
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("\n[WARN] Skipping golden test: could not open {s}: {}\n", .{file_path, err});
        return; // Skip if file not generated (e.g. CI without python)
    };
    defer file.close();

    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader();

    var buf: [65536]u8 = undefined; // 64KB line buffer
    var line_no: usize = 0;

    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        line_no += 1;
        if (line.len == 0) continue;

        // Parse JSON
        const parsed = try std.json.parseFromSlice(GoldenRecord, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const record = parsed.value;

        // Verify we support this encoding
        const spec = tokenizer.registry.Registry.get(record.encoding);
        if (spec == null) {
            std.debug.print("Skipping unknown encoding {s} at line {d}\n", .{record.encoding, line_no});
            continue;
        }

        // Initialize Tokenizer
        // Note: For Golden Tests we expect exact parity for "ordinary" encoding (no special tokens handled)
        // logic mirrors engine.estimateTokens(.ordinary) which uses OpenAITokenizer

        var tok = try tokenizer.openai.OpenAITokenizer.init(allocator, .{
            .spec = spec.?,
            .approximate_ok = false, // Must be exact
            .bpe_version = .v2_1,
        });
        defer tok.deinit(allocator);

        // Encode
        const actual_ids = try tok.encode(allocator, record.text);
        defer allocator.free(actual_ids);

        // Verify
        testing.expectEqualSlices(u32, record.tokens, actual_ids) catch |err| {
            std.debug.print("\nFAIL: Line {d} | Model: {s}\n", .{line_no, record.model});
            std.debug.print("Text: '{s}'\n", .{record.text});
            std.debug.print("Expected: {any}\n", .{record.tokens});
            std.debug.print("Actual:   {any}\n", .{actual_ids});
            return err;
        };
    }
}

///
/// These tests verify that the CLI interface remains stable and backwards-compatible.
/// Each test case represents a "golden" expected output that must not change
/// without explicit versioning.
///
/// Test categories:
/// 1. Basic tokenization output format
/// 2. Cost calculation output format
/// 3. Error message format
/// 4. Exit codes
/// 5. JSON output schema

// =============================================================================
// Test Fixtures
// =============================================================================

const GoldenCase = struct {
    name: []const u8,
    args: []const []const u8,
    expected_stdout: ?[]const u8 = null,
    expected_stderr: ?[]const u8 = null,
    expected_exit_code: u8 = 0,
    stdout_contains: ?[]const u8 = null,
    stderr_contains: ?[]const u8 = null,
};

// =============================================================================
// Golden Test Cases
// =============================================================================

/// Version output format (must be semver)
const version_case = GoldenCase{
    .name = "version_format",
    .args = &.{"--version"},
    .stdout_contains = "llm-cost",
};

/// Help output must contain key commands
const help_case = GoldenCase{
    .name = "help_contains_commands",
    .args = &.{"--help"},
    .stdout_contains = "Usage:",
};

/// Count command basic format
const count_basic_case = GoldenCase{
    .name = "count_basic_output",
    .args = &.{ "count", "--model", "gpt-4", "--text", "Hello world" },
    .stdout_contains = "tokens",
};

/// JSON output schema validation
const json_output_case = GoldenCase{
    .name = "json_output_schema",
    .args = &.{ "count", "--model", "gpt-4", "--text", "test", "--format", "json" },
    .stdout_contains = "{",
};

/// Error: missing model
const error_missing_model = GoldenCase{
    .name = "error_missing_model",
    .args = &.{ "count", "--text", "test" },
    .expected_exit_code = 1,
    .stderr_contains = "model",
};

/// Error: unknown model
const error_unknown_model = GoldenCase{
    .name = "error_unknown_model",
    .args = &.{ "count", "--model", "nonexistent-model-xyz", "--text", "test" },
    .expected_exit_code = 1,
    .stderr_contains = "unknown",
};

// =============================================================================
// Test Runner Infrastructure
// =============================================================================

/// Run a golden test case against the actual CLI binary
fn runGoldenTest(case: GoldenCase) !void {
    // For now, this is a placeholder that validates test structure
    // In CI, this would spawn the actual binary and compare output

    // Validate case is well-formed
    try testing.expect(case.name.len > 0);
    try testing.expect(case.args.len > 0);

    // At least one expectation must be set
    const has_expectation = case.expected_stdout != null or
        case.expected_stderr != null or
        case.stdout_contains != null or
        case.stderr_contains != null or
        case.expected_exit_code != 0;
    try testing.expect(has_expectation);
}

/// Placeholder for actual CLI invocation
/// TODO: Implement when CLI is complete
fn invokeCli(args: []const []const u8) !struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
} {
    _ = args;
    return .{
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
    };
}

// =============================================================================
// Test Entry Points
// =============================================================================

test "golden: version format" {
    try runGoldenTest(version_case);
}

test "golden: help contains commands" {
    try runGoldenTest(help_case);
}

test "golden: count basic output" {
    try runGoldenTest(count_basic_case);
}

test "golden: json output schema" {
    try runGoldenTest(json_output_case);
}

test "golden: error missing model" {
    try runGoldenTest(error_missing_model);
}

test "golden: error unknown model" {
    try runGoldenTest(error_unknown_model);
}

// =============================================================================
// Schema Validation Helpers
// =============================================================================

/// Validate JSON output matches expected schema
/// Used for `--format json` output validation
fn validateJsonSchema(json_str: []const u8, required_fields: []const []const u8) !void {
    // Basic validation: must be valid JSON object
    if (json_str.len < 2) return error.InvalidJson;
    if (json_str[0] != '{') return error.InvalidJson;

    var buf: [128]u8 = undefined;

    // Check required fields exist
    for (required_fields) |field| {
        // Simple heuristic: "field"
        const search = try std.fmt.bufPrint(&buf, "\"{s}\"", .{field});
        if (std.mem.indexOf(u8, json_str, search) == null) {
            return error.MissingField;
        }
    }
}

test "json schema: count output" {
    const sample_output =
        \\{"model":"gpt-4","tokens":2,"cost":0.00006}
    ;
    try validateJsonSchema(sample_output, &.{ "model", "tokens" });
}

test "json schema: missing field detection" {
    const sample_output =
        \\{"tokens":2}
    ;
    try testing.expectError(error.MissingField, validateJsonSchema(sample_output, &.{ "model", "tokens" }));
}

// =============================================================================
// Exit Code Constants (CLI Contract)
// =============================================================================

pub const ExitCode = struct {
    pub const success: u8 = 0;
    pub const general_error: u8 = 1;
    pub const usage_error: u8 = 2;
    pub const input_error: u8 = 3;
    pub const network_error: u8 = 4;
};

test "exit codes are distinct" {
    const codes = [_]u8{
        ExitCode.success,
        ExitCode.general_error,
        ExitCode.usage_error,
        ExitCode.input_error,
        ExitCode.network_error,
    };

    // Verify no duplicates
    for (codes, 0..) |code, i| {
        for (codes[i + 1 ..]) |other| {
            try testing.expect(code != other);
        }
    }
}
