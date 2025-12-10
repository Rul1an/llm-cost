const std = @import("std");
const testing = std.testing;
const tokenizer = @import("tokenizer/mod.zig");

// =============================================================================
// Data Structures
// =============================================================================

const GoldenRecord = struct {
    model: []const u8, // Contains encoding name e.g. "o200k_base"
    text: []const u8,
    expected_ids: []const u32,
};

// =============================================================================
// Test Logic
// =============================================================================

test "parity: parity with evil_corpus_v2" {
    const allocator = testing.allocator;

    // We assume the test is run from project root or we can find the file relative to it.
    // Try to open the golden file.
    const file_path = "testdata/evil_corpus_v2.jsonl"; // Moved to testdata root? Or testdata/golden?
    // User context said "testdata/evil_corpus_v2.jsonl". src/golden_test.zig used "testdata/golden/evil_corpus_v2.jsonl".
    // I previously verified "testdata/evil_corpus_v2.jsonl" exists in 'step 2553'.
    // Let's use "testdata/evil_corpus_v2.jsonl".

    // Note: We need to check if absolute path is safer, but relative to CWD (project root) is standard for `zig build`.

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        // If file not found, we fail/skip. For release parity, we SHOULD fail if missing.
        std.debug.print("\n[ERROR] Parity test failed: could not open {s}: {}\n", .{ file_path, err });
        return err;
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

        // Verify we support this encoding (model field contains encoding name in corpus)
        const encoding_name = record.model;
        const spec = tokenizer.registry.Registry.get(encoding_name);
        if (spec == null) {
            std.debug.print("Skipping unknown encoding {s} at line {d}\n", .{ encoding_name, line_no });
            continue;
        }

        // Initialize Tokenizer
        // Reference logic: Must match OpenAITokenizer behavior exactly
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
        testing.expectEqualSlices(u32, record.expected_ids, actual_ids) catch |err| {
            std.debug.print("\nFAIL: Line {d} | Encoding: {s}\n", .{ line_no, record.model });
            std.debug.print("Text: '{s}'\n", .{record.text});
            std.debug.print("Expected: {any}\n", .{record.expected_ids});
            std.debug.print("Actual:   {any}\n", .{actual_ids});
            return err;
        };
    }
}
