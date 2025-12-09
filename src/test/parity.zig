const std = @import("std");
const llm_cost = @import("llm_cost");
// registry is inside tokenizer module in lib.zig
const registry = llm_cost.tokenizer.registry;
// Import OpenAITokenizer and its Config
const OpenAITokenizer = llm_cost.tokenizer.OpenAITokenizer;

const TEST_FILE = "testdata/evil_corpus_v2.jsonl";

test "parity evil corpus v2" {
    const alloc = std.testing.allocator;

    // Check if file exists
    const file = std.fs.cwd().openFile(TEST_FILE, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("\nSkipping Parity Tests: {s} not found. Run tools/gen_evil_corpus.py first.\n", .{TEST_FILE});
            return;
        }
        return err;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var buf: [16384]u8 = undefined;

    // Pre-load encodings to avoid re-init cost?
    // Or just init per line for correctness testing (stateless)?
    // Re-init is safer for isolation but slower.
    // Let's optimize slightly by caching if expensive?
    // Tokenizer init parses vocab. That IS expensive (mb's of data).
    // Better to cache tokenizers.
    // However, for cl100k, vocab is missing.

    // Simple approach: Map(String -> Tokenizer)
    // Zig doesn't have easy AutoHashMap of String->Object without management.
    // I'll just check "o200k_base" and "cl100k_base".

    // We need to load o200k.
    // But this test runs in "test" mode.
    // Does it have access to `embedFile` data? Yes.

    var line_no: usize = 0;
    while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        line_no += 1;
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();

        const root = parsed.value;
        const model_name = root.object.get("model").?.string;
        const text = root.object.get("text").?.string;
        const expected_ids_val = root.object.get("expected_ids").?.array;

        // Skip cl100k if not enabled/vocab missing
        const spec = registry.Registry.get(model_name) orelse {
             std.debug.print("Unknown model: {s}\n", .{model_name});
             continue;
        };

        if (spec.vocab_data.len == 0) {
            // implicit skip
            continue;
        }

        // Initialize Tokenizer
        const config = .{
            .spec = spec,
            .approximate_ok = false,
        };
        var tok = try OpenAITokenizer.init(alloc, config);
        defer tok.deinit();
        // Note: OpenAITokenizer holds reference to spec, doesn't need deinit explicitly unless it allocates?
        // OpenAITokenizer.init allocates BpeEngine (which references embedded data).
        // It does not allocate memory on heap for structure, just returns struct.
        // Wait, BpeEngine copies data?
        // BpeEngine.init(embedded_data) creates slices pointing to embedded data. Zero copy.
        // So no deinit needed for Tokenizer itself.

        const encoded_ids = try tok.encode(alloc, text);
        defer alloc.free(encoded_ids);

        // Verify length
        if (encoded_ids.len != expected_ids_val.items.len) {
            std.debug.print("FAILURE: Model {s} \nText: '{s}'\nExpected Len: {d}, Got: {d}\n", .{model_name, text, expected_ids_val.items.len, encoded_ids.len});
            // Print details
            return error.TestParityFailed;
        }

        // Verify content
        for (encoded_ids, 0..) |id, i| {
            // JSON array items are values. `.integer` is i64.
            const raw = expected_ids_val.items[i].integer;

            // Safety check for u32 cast
            if (raw < 0 or raw > std.math.maxInt(u32)) {
                std.debug.print("FAILURE: Invalid ID in expected vector: {d}\n", .{raw});
                return error.InvalidParityVector;
            }

            const expected_id = @as(u32, @intCast(raw));
            if (id != expected_id) {
                 std.debug.print("FAILURE: Model {s} \nText: '{s}'\nMismatch at index {d}: Expected {d}, Got {d}\n", .{model_name, text, i, expected_id, id});
                 return error.TestParityFailed;
            }
        }
    }
}
