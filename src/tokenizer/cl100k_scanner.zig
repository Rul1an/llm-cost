const std = @import("std");
const pre_tokenizer = @import("pre_tokenizer.zig");
const unicode = @import("unicode_tables.zig");
const SafeUtf8Iterator = @import("utf8.zig").SafeUtf8Iterator;

/// A specialized pre-tokenizer for 'cl100k_base' that mimics the regex logic.
/// Regex (semantisch equivalent aan tiktoken cl100k_base):
/// `(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+`
pub const Cl100kScanner = struct {
    pub fn tokenize(_: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]pre_tokenizer.PreToken {
        var tokens = std.ArrayList(pre_tokenizer.PreToken).init(alloc);
        errdefer tokens.deinit();

        var i: usize = 0;
        while (i < text.len) {
            const remainder = text[i..];

            // 1. Contractions
            if (tryScanContraction(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // 2. Words (Letters only)
            if (tryScanWordLetters(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // 3. Numbers
            if (tryScanNumber(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // 4. Punctuation
            if (tryScanPunctuation(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // 5. Whitespace (Newline)
            if (tryScanWhitespaceBranch5(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // 6. Whitespace (Trailing)
            if (tryScanWhitespaceBranch6(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // 7. Whitespace (Generic)
            if (tryScanWhitespaceBranch7(remainder)) |len| {
                try tokens.append(.{ .text = remainder[0..len] });
                i += len;
                continue;
            }

            // Fallback: Consume 1 byte.
            try tokens.append(.{ .text = remainder[0..1] });
            i += 1;
        }

        return tokens.toOwnedSlice();
    }

    /// Helper for Words Letter prefix: [^\r\n\p{L}\p{N}]
    fn isLetterPrefix(cp: unicode.CodePoint) bool {
        return cp != '\r' and cp != '\n' and !unicode.isLetter(cp) and !unicode.isNumber(cp);
    }

    /// Branch 1: Contractions
    /// `(?i:'s|'t|'re|'ve|'m|'ll|'d)`
    fn tryScanContraction(slice: []const u8) ?usize {
        if (slice.len < 2) return null;
        if (slice[0] != '\'') return null; // Optimization: Must start with '

        // 's, 't, 'm, 'd
        const c2 = slice[1] | 0x20;
        if (c2 == 's' or c2 == 't' or c2 == 'm' or c2 == 'd') return 2;

        // 're, 've, 'll
        if (slice.len >= 3) {
            const c3 = slice[2] | 0x20;
            if ((c2 == 'r' and c3 == 'e') or
                (c2 == 'v' and c3 == 'e') or
                (c2 == 'l' and c3 == 'l')) return 3;
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
            // Consumed prefix. Check if there is a Letter body.
            const cp2 = it.nextCodepoint() orelse return null;
            if (!unicode.isLetter(cp2)) return null;
            // Valid prefix + Valid start of body.
            // Continue scanning body.
        } else if (!unicode.isLetter(first_cp)) {
            // No prefix, and first char is not a Letter -> Fail.
            return null;
        } else {
            // No prefix, first char IS a letter.
        }

        // We are inside the body (\p{L}+).
        // We scan greedily until non-Letter.
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
            // Peek or just run nextCodepoint?
            // If we consume and it's NOT a number, we must return the PREVIOUS end_idx.
            // prev_i not needed as we track end_idx
            if (it.nextCodepoint()) |cp| {
                if (unicode.isNumber(cp)) {
                    count += 1;
                    end_idx = it.i;
                } else {
                    // Not a number. Stop.
                    // `end_idx` is still valid for previous chars.
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
                body_end = prev_i; // Backtrack to before this char
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

    fn tryScanWhitespaceBranch6(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;
        if (!unicode.isWhitespace(cp1)) return null;

        var ws_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            ws_end = it.i;
        }

        if (ws_end < slice.len) return null;
        return ws_end;
    }

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
