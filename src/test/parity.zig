const std = @import("std");
const engine = @import("../core/engine.zig");
const registry = @import("../tokenizer/registry.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const file_path = "tools/corpus_small.jsonl";
    var file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Could not open {s}: {}\n", .{file_path, err});
        return err;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var buf: [16 * 1024]u8 = undefined;
    var line_count: usize = 0;
    var fail_count: usize = 0;

    std.debug.print("Running Parity Checks against {s}...\n", .{file_path});

    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        line_count += 1;
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const text = obj.get("text").?.string;
        const model = obj.get("model").?.string;
        const expected_tokens = obj.get("tokens").?.array;

        // TODO: Validate tokens content, not just count, later.
        const expected_count = expected_tokens.items.len;

        // Run Engine
        const spec = registry.Registry.get(obj.get("encoding").?.string) orelse {
            std.debug.print("SKIP: Unknown encoding\n", .{});
            continue;
        };

        const tk_cfg = engine.TokenizerConfig{
            .spec = spec,
            .model_name = model,
        };

        const result = engine.estimateTokens(alloc, tk_cfg, text) catch |err| {
            std.debug.print("FAIL: Engine error {}\n", .{err});
            fail_count += 1;
            continue;
        };

        if (result.tokens != expected_count) {
            std.debug.print("FAIL [L{d}]: Expected {d}, Got {d}. Text: '{s}'\n", .{
                line_count, expected_count, result.tokens, text
            });
            fail_count += 1;
        } else {
            // std.debug.print("PASS [L{d}]\n", .{line_count});
        }
    }

    std.debug.print("Done. {d}/{d} passed.\n", .{line_count - fail_count, line_count});
    if (fail_count > 0) {
        return error.ParityCheckFailed;
    }
}
