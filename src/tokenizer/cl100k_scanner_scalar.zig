const std = @import("std");
const pre_tokenizer = @import("pre_tokenizer.zig");
const unicode = @import("unicode_tables.zig");
const SafeUtf8Iterator = @import("utf8.zig").SafeUtf8Iterator;

/// A specialized pre-tokenizer for 'cl100k_base' - SCALAR REFERENCE IMPLEMENTATION.
/// This matches `cl100k_scanner.zig` logic but explicitly excludes SIMD optimizations.
/// Used for differential fuzzing/verification.
pub const Cl100kScannerScalar = struct {
    pub fn tokenize(_: *anyopaque, text: []const u8, handler_ctx: *anyopaque, handler: pre_tokenizer.TokenHandler) !void {
        var i: usize = 0;
        while (i < text.len) {
            const remainder = text[i..];

            // Priority order matches tiktoken cl100k_base regex branches:
            // 1. Contractions: (?i:'s|'t|'re|'ve|'m|'ll|'d)
            // 2. Words: [^\r\n\p{L}\p{N}]?\p{L}+
            // 3. Numbers: \p{N}{1,3}
            // 4. Punctuation: ?[^\s\p{L}\p{N}]+[\r\n]*
            // 5. Whitespace (newline): \s*[\r\n]
            // 6. Whitespace (trailing): \s+(?!\S)
            // 7. Whitespace (generic): \s+

            // --- ASCII Fastpath (Defensive) ---
            const c = remainder[0];
            if (c < 0x80) {
                const cls = ASCII_CLASSES[c];
                switch (cls) {
                    // Branch 2: Words (Letters)
                    .Letter => {
                        var len: usize = 1;
                        var valid = true;

                        // NO SIMD HERE - Pure Scalar Loop

                        // Scan contiguous letters (Scalar cleanup)
                        while (len < remainder.len) {
                            const b = remainder[len];
                            if (b >= 0x80) break; // Unicode -> Fallback/Stop
                            if (ASCII_CLASSES[b] == .Letter) {
                                len += 1;
                            } else {
                                break;
                            }
                        }

                        // Check if stopped by Unicode?
                        if (len < remainder.len and remainder[len] >= 0x80) {
                            // If we hit Unicode letters, strict regex might merge them `\p{L}+`.
                            // So we must abort fastpath to allow full regex logic to see "ascii" + "unicode".
                            // But if we stopped at non-letter ascii (space, number), we are safe to yield.
                            // Wait, `\p{L}+` matches `ascii` + `unicode`.
                            // So if `abc` is followed by `é`, `abcé` is one token.
                            // If we yield `abc`, we split it. Incorrect.
                            // So if next char is >= 0x80, we MUST abort.
                            valid = false;
                        }

                        if (valid) {
                            try handler(handler_ctx, .{ .text = remainder[0..len] });
                            i += len;
                            continue;
                        }
                    },
                    // Branch 3: Numbers (1-3 chars)
                    .Digit => {
                        var len: usize = 1;
                        // Regex: \p{N}{1,3}
                        if (len < remainder.len and len < 3 and remainder[len] < 0x80 and ASCII_CLASSES[remainder[len]] == .Digit) len += 1;
                        if (len < remainder.len and len < 3 and remainder[len] < 0x80 and ASCII_CLASSES[remainder[len]] == .Digit) len += 1;

                        // Strict check as in original
                        if (len < remainder.len and remainder[len] >= 0x80) {
                            // abort
                        } else {
                            try handler(handler_ctx, .{ .text = remainder[0..len] });
                            i += len;
                            continue;
                        }
                    },
                    // Branch 7: Whitespace (Generic)
                    // Note: Branch 5/6 may overlap.
                    .Whitespace => {
                        var len: usize = 1;
                        var valid = true;
                        var found_newline = (c == '\r' or c == '\n');
                        var last_newline_idx: usize = if (found_newline) 0 else 0;

                        while (len < remainder.len) {
                            const b = remainder[len];
                            if (b >= 0x80) {
                                valid = false;
                                break;
                            }

                            const cls_b = ASCII_CLASSES[b];
                            if (cls_b == .Whitespace) {
                                if (b == '\r' or b == '\n') {
                                    found_newline = true;
                                    last_newline_idx = len;
                                }
                                len += 1;
                            } else {
                                break;
                            }
                        }

                        // If valid, apply Branch 5 (End at newline) priority
                        if (valid) {
                            // Priority Check logic
                            if (len == 1 and len < remainder.len) {
                                if (c != '\r' and c != '\n') {
                                    const next = remainder[len];
                                    // Check if next is a Digit (safe to split)
                                    var next_is_digit = false;
                                    if (next < 0x80 and ASCII_CLASSES[next] == .Digit) {
                                        next_is_digit = true;
                                    }

                                    if (!next_is_digit) {
                                        valid = false;
                                    }
                                }
                            }
                        }

                        if (valid) {
                            if (found_newline) {
                                // Branch 5: \s*[\r\n]
                                // Yield up to and including last newline
                                len = last_newline_idx + 1;
                            }
                            // Else Branch 6/7: Yield full run

                            try handler(handler_ctx, .{ .text = remainder[0..len] });
                            i += len;
                            continue;
                        }
                    },
                    else => {},
                }
            }
            // ----------------------

            if (tryScanContraction(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            if (tryScanWordLetters(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            if (tryScanNumber(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            if (tryScanPunctuation(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            if (tryScanWhitespaceBranch5(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            if (tryScanWhitespaceBranch6(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            if (tryScanWhitespaceBranch7(remainder)) |len| {
                try handler(handler_ctx, .{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // Fallback: Consume 1 byte for forward progress
            const token = pre_tokenizer.PreToken{ .text = remainder[0..1] };
            try handler(handler_ctx, token);
            i += token.text.len;
        }
    }

    const ByteClass = enum {
        Other,
        Letter, // a-z A-Z
        Digit, // 0-9
        Whitespace, // \n \r \t space
        ContractionStart, // '
    };

    const ASCII_CLASSES = init: {
        var table: [128]ByteClass = undefined;
        for (0..128) |i| {
            table[i] = .Other;
        }

        // Whitespace
        table[' '] = .Whitespace;
        table['\t'] = .Whitespace;
        table['\n'] = .Whitespace;
        table['\r'] = .Whitespace;

        // Letters
        for ('a'..'z' + 1) |c| table[c] = .Letter;
        for ('A'..'Z' + 1) |c| table[c] = .Letter;

        // Digits
        for ('0'..'9' + 1) |c| table[c] = .Digit;

        // Contraction
        table['\''] = .ContractionStart;

        break :init table;
    };

    /// Helper: Check if codepoint is valid letter prefix [^\r\n\p{L}\p{N}]
    fn isLetterPrefix(cp: u21) bool {
        return cp != '\r' and cp != '\n' and !unicode.isLetter(cp) and !unicode.isNumber(cp);
    }

    /// Branch 1: Contractions
    /// `(?i:'s|'t|'re|'ve|'m|'ll|'d)`
    fn tryScanContraction(slice: []const u8) ?usize {
        if (slice.len < 2) return null;
        if (slice[0] != '\'') return null;

        // 's, 't, 'm, 'd (2 chars)
        const c2 = slice[1] | 0x20; // lowercase
        if (c2 == 's' or c2 == 't' or c2 == 'm' or c2 == 'd') return 2;

        // 're, 've, 'll (3 chars)
        if (slice.len >= 3) {
            const c3 = slice[2] | 0x20;
            if ((c2 == 'r' and c3 == 'e') or
                (c2 == 'v' and c3 == 'e') or
                (c2 == 'l' and c3 == 'l'))
            {
                return 3;
            }
        }
        return null;
    }

    /// Branch 2: Words (Letters Only)
    /// `[^\r\n\p{L}\p{N}]?\p{L}+`
    fn tryScanWordLetters(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const first_cp = it.nextCodepoint() orelse return null;

        // Optional Prefix
        if (isLetterPrefix(first_cp)) {
            const cp2 = it.nextCodepoint() orelse return null;
            if (!unicode.isLetter(cp2)) return null;
        } else if (!unicode.isLetter(first_cp)) {
            return null;
        }

        // Greedy scan \p{L}+
        var body_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (unicode.isLetter(cp)) {
                body_end = it.i;
            } else {
                break;
            }
        }

        return body_end;
    }

    /// Branch 3: Numbers
    /// `\p{N}{1,3}`
    fn tryScanNumber(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;

        if (!unicode.isNumber(cp1)) return null;

        var count: usize = 1;
        var end_idx = it.i;

        while (count < 3) {
            if (it.nextCodepoint()) |cp| {
                if (unicode.isNumber(cp)) {
                    count += 1;
                    end_idx = it.i;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        return end_idx;
    }

    /// Branch 4: Punctuation
    /// ` ?[^\s\p{L}\p{N}]+[\r\n]*`
    fn tryScanPunctuation(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const first_cp = it.nextCodepoint() orelse return null;

        var body_cp = first_cp;

        // Optional Space Prefix
        if (first_cp == ' ') {
            body_cp = it.nextCodepoint() orelse return null;
        }

        // Body Check: [^\s\p{L}\p{N}]
        if (unicode.isWhitespace(body_cp) or unicode.isLetter(body_cp) or unicode.isNumber(body_cp)) {
            return null;
        }

        var body_end = it.i;
        var prev_i = it.i;
        while (it.nextCodepoint()) |cp| {
            if (unicode.isWhitespace(cp) or unicode.isLetter(cp) or unicode.isNumber(cp)) {
                body_end = prev_i;
                break;
            }
            body_end = it.i;
            prev_i = it.i;
        }

        // Suffix: [\r\n]*
        var suffix_end = body_end;
        var it_suffix = SafeUtf8Iterator{ .bytes = slice, .i = body_end };
        while (it_suffix.nextCodepoint()) |cp| {
            if (cp == '\r' or cp == '\n') {
                suffix_end = it_suffix.i;
            } else {
                break;
            }
        }

        return suffix_end;
    }

    /// Branch 5: Whitespace (Newline) `\s*[\r\n]+`
    fn tryScanWhitespaceBranch5(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;
        if (!unicode.isWhitespace(cp1)) return null;

        var ws_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            ws_end = it.i;
        }

        // Backtrack to find last newline
        var i = ws_end;
        while (i > 0) {
            i -= 1;
            const c = slice[i];
            if (c == '\r' or c == '\n') {
                return i + 1;
            }
        }
        return null;
    }

    /// Branch 6: Trailing whitespace `\s+(?!\S)`
    fn tryScanWhitespaceBranch6(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;
        if (!unicode.isWhitespace(cp1)) return null;

        var ws_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            ws_end = it.i;
        }

        // ws_end is the end of the whitespace run.
        // Check lookahead character (the one that stopped the loop, or EOF).

        // If we reached EOF (ws_end == slice.len), then lookahead is "EOF" (which is not \S).
        // So the condition (?!\S) is satisfied for the full run.
        if (ws_end == slice.len) return ws_end;

        // If we stopped because of a non-whitespace character,
        // then the full run is followed by \S (Fail).
        // But the run of length (ws_end - 1) is followed by the last whitespace char,
        // which matches (?!\S).
        // So we yield (ws_end - <last_char_len>).
        // Since we know the last char was whitespace, we can backtrack one codepoint.
        // Or simply: find the start of the last character.

        var i: usize = 0;
        var prev_i: usize = 0;
        var iter = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            prev_i = i;
            i = iter.i;
        }

        // logic: 'i' is the end of whitespace run.
        // if i == slice.len (EOF), return i.
        // if i < slice.len (stopped at non-ws), return prev_i (backtrack 1 char).
        // If prev_i is 0 (only 1 whitespace char matched), returns 0 -> null.

        if (i == slice.len) return i;
        if (prev_i > 0) return prev_i;

        return null;
    }

    /// Branch 7: Generic whitespace `\s+`
    fn tryScanWhitespaceBranch7(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;
        if (!unicode.isWhitespace(cp1)) return null;

        var ws_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            ws_end = it.i;
        }
        return ws_end;
    }

    const DummyContext = struct {};
    var dummy_ctx: DummyContext = .{};

    pub fn interface() pre_tokenizer.PreTokenizer {
        return .{
            .ptr = @ptrCast(&dummy_ctx),
            .vtable = &.{ .tokenize = tokenize },
        };
    }
};
