const std = @import("std");
const testing = std.testing;
const VocabLoader = @import("vocab_loader.zig").VocabLoader;
const pre_tokenizer = @import("pre_tokenizer.zig");
const scanner = @import("cl100k_scanner.zig");

// Fuzz config
const FUZZ_ITERATIONS = 1000;
const MAX_INPUT_LEN = 1024;

test "Property: Scanner Forward Progress & Conservation" {
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    const allocator = testing.allocator;
    var input_buf: [MAX_INPUT_LEN]u8 = undefined;

    for (0..FUZZ_ITERATIONS) |_| {
        // Generate random input
        const len = rand.intRangeAtMost(usize, 1, MAX_INPUT_LEN);
        const input = input_buf[0..len];
        rand.bytes(input);

        // Pre-tokenize
        // We use cl100k scanner interface
        const pt = scanner.Cl100kScanner.interface();

        var collector = std.ArrayList(pre_tokenizer.PreToken).init(allocator);
        defer collector.deinit();

        const Helper = struct {
            pub fn handle(ctx: *anyopaque, token: pre_tokenizer.PreToken) !void {
                const list: *std.ArrayList(pre_tokenizer.PreToken) = @ptrCast(@alignCast(ctx));
                try list.append(token);
            }
        };

        try pt.tokenize(input, &collector, Helper.handle);
        const tokens = collector.items;

        // Verify Properties
        // 1. Total length of tokens matches input length (Conservation of mass)
        var total_len: usize = 0;
        for (tokens) |tok| {
            // 2. Tokens are valid slices
            const ptr_int = @intFromPtr(tok.text.ptr);
            const start_int = @intFromPtr(input.ptr);
            const end_int = start_int + input.len;

            if (ptr_int < start_int or ptr_int >= end_int) {
                std.debug.print("Token ptr out of bounds\n", .{});
                return error.TestUnexpectedResult;
            }
            if (tok.text.len == 0) {
                std.debug.print("Token len is 0\n", .{});
                return error.TestUnexpectedResult;
            }

            total_len += tok.text.len;
        }

        try testing.expectEqual(input.len, total_len);
    }
}

test "Property: VocabLoader Robustness" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();
    const allocator = testing.allocator;

    for (0..FUZZ_ITERATIONS) |_| {
        // Generate random data
        const len = rand.intRangeAtMost(usize, 0, 4096);
        const data = try allocator.alloc(u8, len);
        defer allocator.free(data);
        rand.bytes(data);

        // Attempt load
        if (VocabLoader.load(allocator, data)) |vocab| {
            // If it succeeds (unlikely with random junk, but possible), check invariants
            defer @constCast(&vocab).deinit(allocator);

            // Access random token if count > 0
            if (vocab.token_count > 0) {
                const rid = rand.intRangeLessThan(u32, 0, vocab.token_count);
                const bytes = vocab.getBytes(rid);
                // Should fail if bytes is null for a valid rank, but getBytes returns ?[]u8
                if (bytes == null) return error.TestUnexpectedResult;
            }
        } else |_| {
            // Errors are expected and good.
            // We just care that it doesn't crash/panic.
        }
    }
}
