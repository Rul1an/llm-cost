const std = @import("std");
const json = std.json;
const tokenizer_mod = @import("tokenizer/mod.zig");
const registry = tokenizer_mod.registry;
const openai = tokenizer_mod.openai;

// Test case structure from JSONL
const GoldenCase = struct {
    id: []const u8,
    encoding: []const u8,
    category: []const u8,
    text: []const u8,
    tokens: []const u32, // Parsed from JSON array
    token_count: usize,
};

pub fn main() !void {
    // 1. Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default corpus path if not provided
    const corpus_path = if (args.len > 1) args[1] else "test/golden/corpus_v2.jsonl";
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Running Parity Tests against {s}...\n", .{corpus_path});

    // 2. Initialize Tokenizers
    // We try to init both cl100k and o200k. If vocab missing, we skip tests needing them.
    var cl100k_tok: ?openai.OpenAITokenizer = null;
    var o200k_tok: ?openai.OpenAITokenizer = null;
    defer if (cl100k_tok) |*t| t.deinit(allocator);
    defer if (o200k_tok) |*t| t.deinit(allocator);
    // Initialize cl100k_base
    if (openai.OpenAITokenizer.init(allocator, .{
        .spec = registry.Registry.cl100k_base,
        .approximate_ok = false,
        .bpe_version = .v2_1,
    })) |tok| {
        cl100k_tok = tok;
    } else |err| {
        try stdout.print("WARN: Failed to init cl100k_base: {}\n", .{err});
    }

    // Initialize o200k_base
    if (openai.OpenAITokenizer.init(allocator, .{
        .spec = registry.Registry.o200k_base,
        .approximate_ok = false,
        .bpe_version = .v2_1,
    })) |tok| {
        o200k_tok = tok;
    } else |err| {
        try stdout.print("WARN: Failed to init o200k_base: {}\n", .{err});
    }

    // 3. Open Corpus
    const file = std.fs.cwd().openFile(corpus_path, .{}) catch |err| {
        try stdout.print("ERROR: Could not open corpus file: {}\n", .{err});
        try stdout.print("Run 'python scripts/generate_golden.py' to generate it.\n", .{});
        std.process.exit(1);
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    // 4. Stream & Test
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var line_num: usize = 0;

    // Buffer for reading lines (support up to 2MB lines for long tests)
    const line_buf = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(line_buf);

    while (reader.readUntilDelimiterOrEof(line_buf, '\n')) |line_opt| {
        line_num += 1;
        const line = line_opt orelse break;
        if (line.len == 0) continue;

        // Verify JSON validity
        const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch |err| {
            try stdout.print("SKIP [Line {d}]: JSON parse error: {}\n", .{ line_num, err });
            skipped += 1;
            continue;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const case_id = obj.get("id").?.string;
        const encoding = obj.get("encoding").?.string;
        const text = obj.get("text").?.string;
        const expected_tokens_val = obj.get("tokens").?.array;

        // Select tokenizer
        const tok_ptr: ?*openai.OpenAITokenizer = if (std.mem.eql(u8, encoding, "cl100k_base"))
            if (cl100k_tok) |*t| t else null
        else if (std.mem.eql(u8, encoding, "o200k_base"))
            if (o200k_tok) |*t| t else null
        else
            null;

        if (tok_ptr == null) {
            // Cannot test this encoding (missing or unloadable)
            skipped += 1;
            continue;
        }

        // Encode
        const actual_tokens = tok_ptr.?.encode(allocator, text) catch |err| {
            try stdout.print("FAIL [{s}]: encode error: {}\n", .{ case_id, err });
            failed += 1;
            continue;
        };
        defer allocator.free(actual_tokens);

        // Compare
        var mismatch = false;
        if (actual_tokens.len != expected_tokens_val.items.len) {
            mismatch = true;
        } else {
            for (actual_tokens, 0..) |actual, i| {
                const expected_val = expected_tokens_val.items[i];
                // JSON parser might parse numbers as integer or float? Usually integer.
                // Safely cast.
                const expected: u32 = switch (expected_val) {
                    .integer => |vals| @intCast(vals),
                    else => 0, // Should not happen for valid golden file
                };

                if (actual != expected) {
                    mismatch = true;
                    break;
                }
            }
        }

        if (mismatch) {
            try stdout.print("FAIL [{s}]: Mismatch\n", .{case_id});
            try stdout.print("  Text (len={d}): \"{s}\"\n", .{ text.len, truncate(text, 50) });
            try stdout.print("  Expected ({d}): ", .{expected_tokens_val.items.len});
            printTokensPrefix(stdout, expected_tokens_val.items, 10);
            try stdout.print("\n", .{});
            try stdout.print("  Actual   ({d}): ", .{actual_tokens.len});
            printTokensSlicePrefix(stdout, actual_tokens, 10);
            try stdout.print("\n", .{});
            failed += 1;
        } else {
            passed += 1;
            if (passed % 100 == 0) {
                try stdout.print(".", .{}); // Progress dot
            }
        }
    } else |err| {
        try stdout.print("\nREAD ERROR: {}\n", .{err});
        failed += 1;
    }

    try stdout.print("\n\n=== Golden Test Results ===\n", .{});
    try stdout.print("Passed:  {d}\n", .{passed});
    try stdout.print("Failed:  {d}\n", .{failed});
    try stdout.print("Skipped: {d}\n", .{skipped});
    try stdout.print("Total:   {d}\n", .{passed + failed + skipped});

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

fn printTokensPrefix(writer: anytype, items: []const json.Value, prefix_len: usize) void {
    const n = @min(items.len, prefix_len);
    writer.writeAll("[") catch {};
    for (0..n) |i| {
        if (i > 0) writer.writeAll(", ") catch {};
        const val = items[i];
        switch (val) {
            .integer => |v| writer.print("{d}", .{v}) catch {},
            else => {},
        }
    }
    if (items.len > prefix_len) writer.writeAll(", ...") catch {};
    writer.writeAll("]") catch {};
}

fn printTokensSlicePrefix(writer: anytype, items: []const u32, prefix_len: usize) void {
    const n = @min(items.len, prefix_len);
    writer.writeAll("[") catch {};
    for (0..n) |i| {
        if (i > 0) writer.writeAll(", ") catch {};
        writer.print("{d}", .{items[i]}) catch {};
    }
    if (items.len > prefix_len) writer.writeAll(", ...") catch {};
    writer.writeAll("]") catch {};
}
