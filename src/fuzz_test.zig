const std = @import("std");
const engine = @import("core/engine.zig");
const openai = @import("tokenizer/openai.zig");
const tokenizer_mod = @import("tokenizer/mod.zig");
const model_registry = tokenizer_mod.model_registry;

/// Run deterministic chaos testing on a specific model
fn runChaosForModel(model_name: []const u8, seed: u64) !void {
    const allocator = std.testing.allocator;

    // Deterministic seed for reproducibility
    var prng = std.rand.DefaultPrng.init(seed);
    const rand = prng.random();

    // 1. Init tokenizer in STRICT mode (no approximate fallback)
    // We want to verify the actual scanner and BPE engine handle garbage gracefully.
    var tok = try openai.OpenAITokenizer.init(.{
        .spec = openai.resolveEncoding(model_name).?,
        .approximate_ok = false
    });

    const ITERATIONS = 2_000;
    var buf: [4096]u8 = undefined; // Larger buffer for more interesting patterns

    for (0..ITERATIONS) |i| {
        // Generate random length and content
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        const input = buf[0..len];
        rand.bytes(input);

        // Test 1: No Panic / UB
        const res1 = tok.count(allocator, input) catch |err| {
             std.debug.print("Failed on iteration {d} (model {s}), len {d}. Error: {s}\n", .{i, model_name, len, @errorName(err)});
             // Dump hex for repro
             std.debug.print("Input hex: {x}\n", .{input});
             return err;
        };

        // Test 2: Determinism check (Result should be identical for same input)
        const res2 = tok.count(allocator, input) catch unreachable;
        try std.testing.expectEqual(res1.tokens, res2.tokens);
    }
}

test "chaos o200k (gpt-4o)" {
    try runChaosForModel("gpt-4o", 0x12345678);
}

test "chaos cl100k (gpt-4)" {
    try runChaosForModel("gpt-4", 0xDEADBEEF);
}

test "registry resolution fuzz" {
    var prng = std.rand.DefaultPrng.init(0xCAFEBABE);
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
