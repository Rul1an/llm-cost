const std = @import("std");
const openai = @import("tokenizer/openai.zig");

// Fuzz entry point
// Zig's fuzz testing infrastructure (AFL+/libFuzzer) typically hooks into `export fn LLVMFuzzerTestOneInput`
// But in Zig 0.13, we can likely use `std.testing.fuzz` if available, or just a simple test runner.
// For now, we'll write a simple property-based test that can be run repeatedly.

test "fuzz tokenizer with random bytes" {
    const allocator = std.testing.allocator;

    // We can't generate true random in a deterministic test without seed.
    // But we can iterate over some chaotic patterns.
    // Or we can just rely on `std.testing.fuzz` if available (std.testing.fuzz is not yet standard in 0.13 for test blocks).
    // Let's stick to a robust "Chaos Input" test.

    // 1. Init tokenizer
    var tok = try openai.OpenAITokenizer.init(.{
        .kind = .o200k_base,
        .approximate_ok = true
    });

    // 2. Define edge case inputs
    const inputs = [_][]const u8{
        "",
        " ",
        "\n",
        "\x00",
        "\xff",
        "\x00\xff",
        "invalid utf8 \x80 \xff",
        "long_word_without_spaces_goes_here_and_never_stops_unless_we_force_it",
        "Mixed \t whitespace \n and \r\n control \x00 chars"
    };

    for (inputs) |input| {
        const res = tok.count(allocator, input) catch |err| {
            std.debug.print("Failed on input '{any}': {s}\n", .{input, @errorName(err)});
            return err;
        };
        _ = res;
    }
}
