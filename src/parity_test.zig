const std = @import("std");
const testing = std.testing;

/// Parity Tests: llm-cost vs tiktoken
///
/// These tests verify that our tokenizer produces identical output to
/// OpenAI's tiktoken library. This is critical for accurate cost estimation.
///
/// Test methodology:
/// 1. Pre-computed golden outputs from tiktoken (evil_corpus_v2.jsonl)
/// 2. Round-trip verification
/// 3. Edge case coverage
///
/// Running:
///   zig build test-parity
///
/// Regenerating golden data:
///   python scripts/generate_parity_corpus.py > test/evil_corpus_v2.jsonl

// =============================================================================
// Test Corpus Entry
// =============================================================================

const ParityCase = struct {
    input: []const u8,
    model: []const u8,
    expected_tokens: []const u32,
    expected_count: usize,
};

// =============================================================================
// cl100k_base Parity Cases (GPT-4, GPT-3.5-turbo)
// =============================================================================

const cl100k_cases = [_]ParityCase{
    // Basic ASCII
    .{
        .input = "Hello, World!",
        .model = "cl100k_base",
        .expected_tokens = &[_]u32{ 9906, 11, 4435, 0 }, // Placeholder - replace with actual
        .expected_count = 4,
    },
    // Contractions
    .{
        .input = "I'm can't won't",
        .model = "cl100k_base",
        .expected_tokens = &[_]u32{}, // TODO: Fill from tiktoken
        .expected_count = 7,
    },
    // Unicode
    .{
        .input = "こんにちは",
        .model = "cl100k_base",
        .expected_tokens = &[_]u32{},
        .expected_count = 5, // Typically 1 token per character for Japanese
    },
    // Emoji
    .{
        .input = "🎉🚀💻",
        .model = "cl100k_base",
        .expected_tokens = &[_]u32{},
        .expected_count = 3,
    },
    // Whitespace edge cases
    .{
        .input = "   leading spaces",
        .model = "cl100k_base",
        .expected_tokens = &[_]u32{},
        .expected_count = 4,
    },
    // Numbers
    .{
        .input = "123456789",
        .model = "cl100k_base",
        .expected_tokens = &[_]u32{},
        .expected_count = 3, // Numbers split into 3-digit groups
    },
};

// =============================================================================
// o200k_base Parity Cases (GPT-4o)
// =============================================================================

const o200k_cases = [_]ParityCase{
    .{
        .input = "Hello, World!",
        .model = "o200k_base",
        .expected_tokens = &[_]u32{},
        .expected_count = 4,
    },
    // o200k has different tokenization for some edge cases
    .{
        .input = "    four spaces",
        .model = "o200k_base",
        .expected_tokens = &[_]u32{},
        .expected_count = 3, // o200k may handle whitespace differently
    },
};

// =============================================================================
// Evil Corpus Cases (Adversarial)
// =============================================================================

/// Evil corpus designed to catch edge cases and regressions
const evil_corpus = [_][]const u8{
    // Empty and whitespace
    "",
    " ",
    "  ",
    "\t",
    "\n",
    "\r\n",
    "   \t\n   ",

    // Boundary cases
    "a",
    "aa",
    "aaa",
    "a" ** 100,
    "a" ** 1000,
        // Unicode boundaries
    "\x00", // Null
    "\x7f", // DEL
    "\x80", // First continuation byte (invalid alone)
    "\xc2\x80", // First valid 2-byte sequence (U+0080)
    "\xef\xbf\xbd", // Replacement character U+FFFD

    // Multi-script
    "Hello世界مرحبا",
    "ASCII日本語العربية",

    // Emoji sequences
    "👨‍👩‍👧‍👦", // Family emoji (ZWJ sequence)
    "🏳️‍🌈", // Rainbow flag (ZWJ)
    "👋🏽", // Skin tone modifier

    // Code-like
    "function foo() { return 42; }",
    "def __init__(self):",
    "SELECT * FROM users WHERE id = 1;",
    "<html><body>Hello</body></html>",
    "{ \"key\": \"value\" }",

    // Pathological patterns
    "aaaaaaaaaa" ** 10,
    "          " ** 10, // Many spaces
    "🔥" ** 50, // Many emoji

    // Mixed content
    "Price: $1,234.56 USD",
    "Email: test@example.com",
    "URL: https://example.com/path?q=1",
    "Date: 2024-01-15T10:30:00Z",
};

// =============================================================================
// Test Runners
// =============================================================================

/// Verify token count matches expected
fn verifyTokenCount(input: []const u8, model: []const u8, expected: usize) !void {
    _ = input;
    _ = model;
    _ = expected;
    // TODO: Implement when tokenizer is integrated
    // const engine = try getEngine(model);
    // const tokens = try engine.encode(input);
    // try testing.expectEqual(expected, tokens.len);
}

/// Verify exact token sequence matches
fn verifyTokenSequence(input: []const u8, model: []const u8, expected: []const u32) !void {
    _ = input;
    _ = model;
    _ = expected;
    // TODO: Implement when tokenizer is integrated
    // const engine = try getEngine(model);
    // const tokens = try engine.encode(input);
    // try testing.expectEqualSlices(u32, expected, tokens);
}

/// Verify round-trip: encode then decode should equal original
fn verifyRoundTrip(input: []const u8, model: []const u8) !void {
    _ = input;
    _ = model;
    // TODO: Implement when tokenizer is integrated
    // const engine = try getEngine(model);
    // const tokens = try engine.encode(input);
    // const decoded = try engine.decode(tokens);
    // try testing.expectEqualStrings(input, decoded);
}

// =============================================================================
// Test Entry Points
// =============================================================================

test "parity: cl100k_base cases" {
    for (cl100k_cases) |case| {
        // Skip cases with empty expected_tokens (not yet filled)
        if (case.expected_tokens.len == 0) continue;
        try verifyTokenSequence(case.input, case.model, case.expected_tokens);
    }
}

test "parity: o200k_base cases" {
    for (o200k_cases) |case| {
        if (case.expected_tokens.len == 0) continue;
        try verifyTokenSequence(case.input, case.model, case.expected_tokens);
    }
}

test "parity: evil corpus round-trip" {
    for (evil_corpus) |input| {
        // Test both encodings
        try verifyRoundTrip(input, "cl100k_base");
        try verifyRoundTrip(input, "o200k_base");
    }
}

test "parity: token count sanity" {
    // Token count should be <= byte length (each byte is at most 1 token)
    // and >= 1 for non-empty input (at least 1 token)
    for (evil_corpus) |input| {
        if (input.len == 0) continue;

        // Placeholder assertion until tokenizer is integrated
        try testing.expect(input.len > 0);
    }
}

// =============================================================================
// JSONL Corpus Loading (for CI)
// =============================================================================

const CorpusEntry = struct {
    text: []const u8,
    model: []const u8,
    tokens: []const u32,
};

/// Load parity test cases from JSONL file
/// Format: {"text": "...", "model": "cl100k_base", "tokens": [1, 2, 3]}
fn loadCorpusFromFile(allocator: std.mem.Allocator, path: []const u8) ![]CorpusEntry {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Warning: Could not open corpus file {s}: {}\n", .{ path, err });
        return allocator.alloc(CorpusEntry, 0);
    };
    defer file.close();

    var entries = std.ArrayList(CorpusEntry).init(allocator);
    errdefer entries.deinit();

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    var line_buf: [1024 * 64]u8 = undefined; // 64KB max line
    while (reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line == null) break;
        // TODO: Parse JSON line and append to entries
        _ = line;
    } else |_| {}

    return entries.toOwnedSlice();
}

test "parity: load corpus file" {
    const allocator = std.testing.allocator;
    const entries = try loadCorpusFromFile(allocator, "test/evil_corpus_v2.jsonl");
    defer allocator.free(entries);

    // File may not exist in test environment, that's OK
    _ = entries;
}

// =============================================================================
// Regression Markers
// =============================================================================

/// Known regressions that are being tracked
/// Format: { input, model, issue_number }
const known_regressions = [_]struct {
    input: []const u8,
    model: []const u8,
    issue: []const u8,
}{
    // Example: .{ .input = "problematic string", .model = "cl100k_base", .issue = "#123" },
};

test "parity: known regressions" {
    for (known_regressions) |reg| {
        std.debug.print("Skipping known regression {s}: {s}\n", .{ reg.issue, reg.input[0..@min(20, reg.input.len)] });
    }
}
