const std = @import("std");
const engine = @import("core/engine.zig");
const openai = @import("tokenizer/openai.zig");
const tokenizer_mod = @import("tokenizer/mod.zig");
const model_registry = tokenizer_mod.model_registry;

/// Run deterministic chaos testing on a specific model
fn runChaosForModel(model_name: []const u8, seed: u64) !void {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const spec = model_registry.ModelRegistry.resolve(model_name);
    const cfg = engine.TokenizerConfig{
        .spec = spec.encoding,
        .model_name = spec.canonical_name,
    };

    const ITERATIONS = 2_000;
    var buf: [4096]u8 = undefined;

    for (0..ITERATIONS) |i| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        const input = buf[0..len];
        rand.bytes(input);

        // Run through engine (default strict mode)
        // We expect errors for special tokens (since random bytes might contain them),
        // but never a panic or crash.
        // We also try .ordinary to ensure no crash there either.

        // Test 1: Strict
        _ = engine.estimateTokens(allocator, cfg, input, .strict) catch |err| {
            if (err == error.DisallowedSpecialToken) {
                // Expected occasionally
            } else if (err == error.TokenizerInternalError) {
                // Should ideally not happen if tokenizer is robust, but not UB.
            } else {
                std.debug.print("Failed strict at itr {d}, len {d}. Error: {s}\n", .{ i, len, @errorName(err) });
                return err;
            }
        };

        // Test 2: Ordinary
        _ = engine.estimateTokens(allocator, cfg, input, .ordinary) catch |err| {
            std.debug.print("Failed ordinary at itr {d}, len {d}. Error: {s}\n", .{ i, len, @errorName(err) });
            return err;
        };
    }
}

test "chaos o200k (gpt-4o)" {
    try runChaosForModel("gpt-4o", 0x12345678);
}

test "chaos cl100k (gpt-4)" {
    try runChaosForModel("gpt-4", 0xDEADBEEF);
}

test "registry resolution fuzz" {
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        // Generate random model name string
        const len = rnd.uintLessThan(usize, 64);
        var buf: [64]u8 = undefined;
        var j: usize = 0;
        while (j < len) : (j += 1) {
            buf[j] = rnd.int(u8);
        }
        const input = buf[0..len];

        // Ensure resolve() never panics
        const spec = model_registry.ModelRegistry.resolve(input);

        // Invariants
        if (spec.accuracy == .exact) {
            // Exact matches must have encoding
            if (spec.encoding == null) @panic("Exact accuracy must have encoding");
        }
    }
}
