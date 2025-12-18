const std = @import("std");
const builtin = @import("builtin");

// Determine vector width based on target capabilities
// AVX2 = 256-bit (32 bytes)
// SSE2/NEON/WASM = 128-bit (16 bytes)
pub const VECTOR_WIDTH = if (builtin.cpu.arch == .x86_64) blk: {
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        break :blk 32;
    } else {
        break :blk 16; // SSE2/Baseline
    }
} else 16; // ARM NEON, etc.

pub const SkipMode = enum {
    letter, // A-Z, a-z
    upper, // A-Z
    lower, // a-z
    digit, // 0-9
};

const Vec = @Vector(VECTOR_WIDTH, u8);

/// Skips a run of "boring" ASCII characters using SIMD.
/// Returns the number of bytes to advance.
/// Stops at:
/// - Any byte >= 0x80 (Non-ASCII)
/// - Whitespace (' ', '\t', '\n', '\r')
/// - Leading punctuation/boundaries if specified (conservative list)
///
/// Current conservative "interesting" set:
/// - >= 0x80
/// - Whitespace
/// - ' (apostrophe) - common for contractions
/// - " (quote)
/// - . , ? ! : ; (punctuation)
/// - < > (HTML/XML)
/// - [ ] { } (brackets)
/// - @ # $ % & * + = ^ ` | ~ (symbols)
/// - \ (backslash)
/// - / (slash)
/// - ( ) (parentheses)
/// - - (hyphen) - sometimes inside words, but safe to stop
/// - _ (underscore) - usually allowed in words, but maybe stop to be safe?
///   Tiktoken regex is \p{L}+. Underscore is NOT \p{L}. So we should stop on _.
///
/// Basically, we ONLY skip: [A-Za-z0-9] (and maybe not even digits if we want to be super safe)
/// Tiktoken patterns:
/// - ' ?\p{L}+' (Words)
/// - ' ?\p{N}{1,3}' (Numbers)
/// - ' ?[^\s\p{L}\p{N}]+' (Punctuation/Other)
///
/// So "boring" = [A-Za-z0-9].
/// Wait, words can start with space OR be just letters.
/// If we are IN a word, we can skip letters.
/// If we are at start, we might see space then letters.
///
/// Use case 1: Fast-forward through a long English sentence.
/// "Hello world this is a test"
/// H -> skip letters -> e l l o -> stop at space
/// space -> stop (handled by scalar)
/// w -> skip letters -> o r l d -> stop at space
///
/// So we should skip [A-Za-z0-9].
/// Actually, just skipping [A-Za-z] is safer and covers 90% of text.
/// Skipping digits is safe too locally, but regex distinguishes letters vs numbers.
/// Let's stick to safe "ASCII Letters" skipping for v1.
///
/// Boundary condition: STOP if NOT (A-Z or a-z).
///
pub fn skip_ascii(input: []const u8, comptime mode: SkipMode) usize {
    var pos: usize = 0;
    const MaskInt = std.meta.Int(.unsigned, VECTOR_WIDTH);

    while (pos + VECTOR_WIDTH <= input.len) {
        const chunk = input[pos..][0..VECTOR_WIDTH];
        const vec: Vec = chunk.*;
        const VecBool = @Vector(VECTOR_WIDTH, bool);
        const true_vec = @as(VecBool, @splat(true));
        const false_vec = @as(VecBool, @splat(false));

        var is_safe: VecBool = false_vec;

        if (mode == .letter or mode == .upper) {
            // A-Z: (c -% 'A') <= ('Z' - 'A')
            const diff_upper = vec -% @as(Vec, @splat('A'));
            const is_upper = diff_upper <= @as(Vec, @splat('Z' - 'A'));

            // is_safe = is_safe OR is_upper
            is_safe = @select(bool, is_upper, true_vec, is_safe);
        }

        if (mode == .letter or mode == .lower) {
            // a-z: (c -% 'a') <= ('z' - 'a')
            const diff_lower = vec -% @as(Vec, @splat('a'));
            const is_lower = diff_lower <= @as(Vec, @splat('z' - 'a'));

            is_safe = @select(bool, is_lower, true_vec, is_safe);
        }

        if (mode == .digit) {
            // 0-9: (c -% '0') <= ('9' - '0')
            const diff_digit = vec -% @as(Vec, @splat('0'));
            const is_digit = diff_digit <= @as(Vec, @splat('9' - '0'));

            is_safe = @select(bool, is_digit, true_vec, is_safe);
        }

        // Invert mask -> 1 = UNSAFE (Stop)
        const safe_mask_int: MaskInt = @bitCast(is_safe);
        const unsafe_mask = ~safe_mask_int;

        if (unsafe_mask != 0) {
            const advance = @ctz(unsafe_mask);
            return pos + advance;
        }

        pos += VECTOR_WIDTH;
    }

    return pos;
}

pub fn skip_plain_ascii(input: []const u8) usize {
    return skip_ascii(input, .letter);
}

pub fn skip_upper_ascii(input: []const u8) usize {
    return skip_ascii(input, .upper);
}

pub fn skip_lower_ascii(input: []const u8) usize {
    return skip_ascii(input, .lower);
}

test "skip_plain_ascii scalar fallback" {
    // Vectors always available, but test small input behavior
    const text = "Hello world";
    // length 11, vec width 16 or 32.
    // Should return 0 (skipped none in SIMD loop).
    const skipped = skip_plain_ascii(text);
    try std.testing.expectEqual(0, skipped);
}

test "skip_plain_ascii long run" {
    // 64 bytes of output
    const text = "HereIsALongRunOfAsciiTextThatShouldBeSkippedByTheSimdScannerImpl";
    //            1234567890123456789012345678901234567890123456789012345678901234
    // Length 64.

    // It is all letters.
    const skipped = skip_plain_ascii(text);
    try std.testing.expect(skipped >= 32); // At least one vector, maybe 2
    if (VECTOR_WIDTH <= 64) {
        // It should consume whole multiples of vector width
        const expected = (text.len / VECTOR_WIDTH) * VECTOR_WIDTH;
        try std.testing.expectEqual(expected, skipped);
    }
}

test "skip_plain_ascii with boundary" {
    // 32 chars then space
    const text = "HereIsALongRunOfAsciiTextThatEnds Here";
    //            012345678901234567890123456789012 3
    // Index 33 is space.
    // Loop 1: 0..32. All letters. Advance 32.
    // Loop 2: 32..64. Byte at 33 is space (index 1 in vector).
    // mask should have bit 1 set. @ctz -> 1.
    // Total advance = 32 + 1 = 33.

    // Wait, "HereIsALongRunOfAsciiTextThatEnds" is 33 chars?
    // "Here" (4) "Is" (2) "A" (1) "Long" (4) "Run" (3) "Of" (2) ...

    const skipped = skip_plain_ascii(text);
    // It should stop at the space.
    // Space index is 33.
    // So it should return 33.

    // Only if 33 >= VECTOR_WIDTH though.
    // If width=32, it does one loop (32 bytes), pos=32.
    // Second loop sees space at index 1 (input[33]).
    // Returns 32 + 1 = 33.

    // If width=32, loop 1 advances 32. Loop 2 text.len < 64, stops.
    // Returns 32. Scalar handles the rest.
    // If width=16
    // Loop 1 (0-16): ok
    // Loop 2 (16-32): ok
    // Loop 3 (32-48): text.len < 48? 38 < 48. Stops.
    // Returns 32.

    // So for both 16 and 32, it returns 32.
    // (Unless width > 32).
    const expected = (33 / VECTOR_WIDTH) * VECTOR_WIDTH;
    try std.testing.expectEqual(expected, skipped);
}
