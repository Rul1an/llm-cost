const std = @import("std");
const pre_tokenizer = @import("pre_tokenizer.zig");
const Cl100kScanner = @import("cl100k_scanner.zig").Cl100kScanner;
const Cl100kScannerScalar = @import("cl100k_scanner_scalar.zig").Cl100kScannerScalar;

// Helper to capture tokens
const TokenList = std.ArrayList([]const u8);

const FuzzContext = struct {
    tokens: TokenList,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FuzzContext {
        return .{
            .tokens = TokenList.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FuzzContext) void {
        self.tokens.deinit();
    }

    pub fn reset(self: *FuzzContext) void {
        self.tokens.clearRetainingCapacity();
    }

    pub fn handler(ctx: *anyopaque, token: pre_tokenizer.PreToken) anyerror!void {
        const self: *FuzzContext = @ptrCast(@alignCast(ctx));
        try self.tokens.append(token.text);
    }
};

fn runFuzzIteration(allocator: std.mem.Allocator, input: []const u8) !void {
    var ctx_simd = FuzzContext.init(allocator);
    defer ctx_simd.deinit();

    var ctx_scalar = FuzzContext.init(allocator);
    defer ctx_scalar.deinit();

    // 1. Run SIMD
    const pt_simd = Cl100kScanner.interface();
    try pt_simd.tokenize(input, &ctx_simd, FuzzContext.handler);

    // 2. Run Scalar
    const pt_scalar = Cl100kScannerScalar.interface();
    try pt_scalar.tokenize(input, &ctx_scalar, FuzzContext.handler);

    // 3. Compare
    if (ctx_simd.tokens.items.len != ctx_scalar.tokens.items.len) {
        std.debug.print("\nMISMATCH: Token Count. SIMD={} Scalar={}\n", .{ ctx_simd.tokens.items.len, ctx_scalar.tokens.items.len });
        std.debug.print("Input (Hex): {x}\n", .{input});
        return error.FuzzMismatch;
    }

    for (ctx_simd.tokens.items, 0..) |simd_tok, i| {
        const scalar_tok = ctx_scalar.tokens.items[i];
        if (!std.mem.eql(u8, simd_tok, scalar_tok)) {
            std.debug.print("\nMISMATCH: Token[{}] content.\nSIMD:   '{s}'\nScalar: '{s}'\n", .{ i, simd_tok, scalar_tok });
            std.debug.print("Input (Hex): {x}\n", .{input});
            return error.FuzzMismatch;
        }
    }
}

test "Differential Fuzzing: SIMD vs Scalar" {
    const allocator = std.testing.allocator;

    // Simple XorShift32 for deterministic fuzzing
    var rng_state: u32 = 12345;
    const next_rand = struct {
        fn call(state: *u32) u32 {
            var x = state.*;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            state.* = x;
            return x;
        }
    }.call;

    // Helper to get bounded random
    const next_bounded = struct {
        fn call(state: *u32, limit: usize) usize {
            return next_rand(state) % limit;
        }
    }.call;

    const iterations = 1000;
    std.debug.print("\nRunning {} fuzz iterations...\n", .{iterations});

    for (0..iterations) |i| {
        if (i % 500 == 0) std.debug.print(".", .{});

        // Strategy 1: Random ASCII (SIMD heavy)
        var buf: [256]u8 = undefined;
        const len_rand = next_bounded(&rng_state, buf.len);
        const len = if (len_rand == 0) 1 else len_rand;

        for (0..len) |j| {
            // Mixed letters and random bytes
            const r = next_rand(&rng_state);
            if (r % 2 == 0) {
                // a-z: 97-122
                buf[j] = @intCast((r % 26) + 97);
            } else if (r % 3 == 0) {
                buf[j] = ' '; // whitespace important
            } else {
                buf[j] = @intCast(r % 255); // full chaos
            }
        }

        try runFuzzIteration(allocator, buf[0..len]);

        // Strategy 2: High Contiguity ASCII (Test bulk skip)
        var buf2: [512]u8 = undefined;
        // Generate long runs of a-z
        for (0..buf2.len) |j| {
            buf2[j] = 'a';
        }
        // Insert sporadic breaks
        for (0..10) |_| {
            const idx = next_bounded(&rng_state, buf2.len);
            buf2[idx] = ' ';
        }
        // Insert unicode
        for (0..5) |_| {
            const idx = next_bounded(&rng_state, buf2.len);
            buf2[idx] = 0xC3; // Start of UTF-8 ??
        }

        try runFuzzIteration(allocator, &buf2);
    }
    std.debug.print("\nPASS\n", .{});
}
