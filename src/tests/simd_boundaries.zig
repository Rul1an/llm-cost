const std = @import("std");
const tok = @import("tokenizer");
const Cl100kScanner = tok.Cl100kScanner;
const pre_tokenizer = tok.pre_tokenizer;
// We assume vector width is 32 (AVX2/Neon common case),
// but even if slightly off, we check a range around it.
const LANES = 32;

test "Deep Verification: SIMD Boundary Traps" {
    const allocator = std.testing.allocator;
    std.debug.print("\nRunning Deterministic SIMD Boundary Traps...\n", .{});

    // Patterns to test at every boundary
    const patterns = [_][]const u8{
        // 1. CRLF Split (classic scanner killer)
        "aaaaaaaaaaaaaaaa\r\nbbbb",
        "aaaaaaaaaaaaaaaa\r\n",

        // 2. UTF-8 Spanning (4-byte seq)
        "aaaaaaaaaaaaaaa\xF0\x9F\x92\xA9", // Poop emoji
        "aaa\xF0\x9F\x92\xA9aaa",

        // 3. Delimiters
        "aaaaa aaaaa",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?",
        "test's",

        // 4. Invalid UTF-8
        "\xFF\xFF\xFF",
        "a\xC0\x80b", // Overlong null

        // 5. Null bytes
        "abc\x00def",
    };

    // Reusable buffers
    var out_scalar = std.ArrayList(u32).init(allocator);
    defer out_scalar.deinit();
    var out_simd = std.ArrayList(u32).init(allocator);
    defer out_simd.deinit();

    // Helper for TokenHandler
    const CollectionContext = struct {
        tokens: *std.ArrayList(u32),
        pub fn handle(ctx: *anyopaque, token: pre_tokenizer.PreToken) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.tokens.append(@intCast(token.text.len));
        }
    };

    var buf: [512]u8 = undefined;

    // We scan around boundaries: 0..[2 * LANES + 16]
    inline for (0..(2 * LANES + 16)) |off| {
        for (patterns) |p| {
            // Fill background with noise to detect over-reads
            @memset(&buf, 'x');

            // Construct input
            const start = off;
            const end = start + p.len;
            if (end > buf.len) continue;

            @memcpy(buf[start..end], p);
            const input = buf[start..end];

            // 1. Scalar
            Cl100kScanner.setScanMode(.scalar);
            out_scalar.clearRetainingCapacity();
            var ctx_scalar = CollectionContext{ .tokens = &out_scalar };
            try Cl100kScanner.tokenize(undefined, input, &ctx_scalar, CollectionContext.handle);

            // 2. SIMD
            Cl100kScanner.setScanMode(.simd);
            out_simd.clearRetainingCapacity();
            var ctx_simd = CollectionContext{ .tokens = &out_simd };
            try Cl100kScanner.tokenize(undefined, input, &ctx_simd, CollectionContext.handle);

            // 3. Compare
            if (!std.mem.eql(u32, out_scalar.items, out_simd.items)) {
                std.debug.print("\nMISMATCH at offset {d}\nInput: '{s}'\n", .{ off, input });
                std.debug.print("Scalar: {any}\nSIMD:   {any}\n", .{ out_scalar.items, out_simd.items });
                return error.DeepBoundaryMismatch;
            }
        }
    }
}
