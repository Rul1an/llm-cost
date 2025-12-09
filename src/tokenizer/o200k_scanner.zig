const std = @import("std");
const pre_tokenizer = @import("pre_tokenizer.zig");
const unicode = @import("unicode_tables.zig");
const SafeUtf8Iterator = @import("utf8.zig").SafeUtf8Iterator;

/// A specialized pre-tokenizer for 'o200k_base' that mimics the regex logic.
/// See `docs/o200k_pre_tokenizer.md` for branch definitions.
pub const O200kScanner = struct {
    /// Main tokenization loop matching regex priority.
    pub fn tokenize(_: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]pre_tokenizer.PreToken {
        var tokens = std.ArrayList(pre_tokenizer.PreToken).init(alloc);
        errdefer tokens.deinit();

        var i: usize = 0;
        while (i < text.len) {
            // Strict Priority Order:
            // 1. Branch 1: Words (Lower suffix)
            // 2. Branch 2: Words (Upper / Lookahead)
            // 3. Branch 3: Numbers
            // 4. Branch 4: Punctuation
            // 5. Branch 5, 6, 7: Whitespace

            if (tryScanWordBranch1(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            if (tryScanWordBranch2(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            if (tryScanNumber(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            if (tryScanPunctuation(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            if (tryScanWhitespaceBranch5(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            if (tryScanWhitespaceBranch6(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            if (tryScanWhitespaceBranch7(text[i..])) |len| {
                try tokens.append(.{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            // Fallback: Consume 1 byte for forward progress
            try tokens.append(.{ .text = text[i .. i + 1] });
            i += 1;
        }

        return tokens.toOwnedSlice();
    }

    fn isWordUpperBody(cp: u21) bool {
        return unicode.isLu(cp) or unicode.isLt(cp) or unicode.isLm(cp) or unicode.isLo(cp) or unicode.isMark(cp);
    }

    fn isWordLowerBody(cp: u21) bool {
        return unicode.isLl(cp) or unicode.isLm(cp) or unicode.isLo(cp) or unicode.isMark(cp);
    }

    fn isPrefixChar(cp: u21) bool {
        return cp != '\r' and cp != '\n' and !unicode.isLetter(cp) and !unicode.isNumber(cp);
    }

    /// Branch 1: Words (Lower Suffix)
    /// Regex: `[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?`
    fn tryScanWordBranch1(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        var start_body_idx: usize = 0;

        // Check first CP for optional prefix
        var cp_peek = it.peek() orelse return null;
        if (isPrefixChar(cp_peek)) {
            _ = it.nextCodepoint();
            start_body_idx = it.i;
            cp_peek = it.peek() orelse return null;
        }

        _ = it.nextCodepoint();

        // Backtrack loop for `Upperish* Lowerish+`
        var upper_it = SafeUtf8Iterator{ .bytes = slice, .i = start_body_idx };
        var upper_end_candidate: usize = start_body_idx;
        var last_upper_i: usize = start_body_idx;

        while (upper_it.nextCodepoint()) |c| {
            if (isWordUpperBody(c)) {
                upper_end_candidate = upper_it.i;
            } else {
                upper_it.i = last_upper_i;
                break;
            }
            last_upper_i = upper_it.i;
        }

        var current_upper_end = upper_end_candidate;
        while (true) {
            var lower_it = SafeUtf8Iterator{ .bytes = slice, .i = current_upper_end };
            var lower_matched_len: usize = 0;
            var has_lower = false;

            var last_lower_i: usize = current_upper_end;
            while (lower_it.nextCodepoint()) |c_low| {
                if (isWordLowerBody(c_low)) {
                    has_lower = true;
                    lower_matched_len = lower_it.i;
                } else {
                    lower_it.i = last_lower_i;
                    break;
                }
                last_lower_i = lower_it.i;
            }

            if (has_lower) {
                const suffix_len = checkContractionSuffix(slice, lower_matched_len);
                return lower_matched_len + suffix_len;
            }

            if (current_upper_end == start_body_idx) {
                return null;
            }

            var prev_char_start = current_upper_end - 1;
            while (prev_char_start > start_body_idx and (slice[prev_char_start] & 0xC0) == 0x80) {
                prev_char_start -= 1;
            }
            current_upper_end = prev_char_start;
        }
    }

    /// Branch 2: Words (Upper)
    /// Regex: `[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?`
    fn tryScanWordBranch2(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        var cp = it.nextCodepoint() orelse return null;

        // 1. Optional Prefix
        if (isPrefixChar(cp)) {
            cp = it.nextCodepoint() orelse return null;
        }

        // 2. Body: Upperish+
        if (!isWordUpperBody(cp)) return null;

        var body_end_idx = it.i;
        var prev_i = it.i;
        while (it.nextCodepoint()) |c| {
            if (isWordUpperBody(c)) {
                body_end_idx = it.i;
            } else {
                it.i = prev_i;
                break;
            }
            prev_i = it.i;
        }

        // 3. Optional Suffix
        const suffix_len = checkContractionSuffix(slice, body_end_idx);
        return body_end_idx + suffix_len;
    }

    /// Branch 4: Punctuation
    fn tryScanPunctuation(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        var cp = it.nextCodepoint() orelse return null;

        // Optional space prefix
        if (cp == ' ') {
            cp = it.nextCodepoint() orelse return null;
        }

        // Body: 1+ chars of [^\s\p{L}\p{N}]
        if (unicode.isWhitespace(cp) or unicode.isLetter(cp) or unicode.isNumber(cp)) {
            return null;
        }
        var end_body = it.i;

        while (it.nextCodepoint()) |c| {
            if (unicode.isWhitespace(c) or unicode.isLetter(c) or unicode.isNumber(c)) {
                end_body = it.i - (std.unicode.utf8CodepointSequenceLength(c) catch 1);
                break;
            }
            end_body = it.i;
        }

        // Check Suffix: [\r\n/]*
        var it_suffix = SafeUtf8Iterator{ .bytes = slice, .i = end_body };
        var end_suffix = end_body;

        while (it_suffix.nextCodepoint()) |s| {
            if (s == '\r' or s == '\n' or s == '/') {
                end_suffix = it_suffix.i;
            } else {
                break;
            }
        }

        return end_suffix;
    }

    /// Branch 3: \p{N}{1,3}
    fn tryScanNumber(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;

        if (!unicode.isNumber(cp1)) return null;

        var len_bytes: usize = it.i;
        var count: usize = 1;

        while (count < 3) {
            if (it.nextCodepoint()) |cp| {
                if (unicode.isNumber(cp)) {
                    count += 1;
                    len_bytes = it.i;
                    continue;
                }
            }
            break;
        }

        return len_bytes;
    }

    /// Branch 5: `\s*[\r\n]+`
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

    /// Branch 6: `\s+(?!\S)`
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

    /// Branch 7: `\s+`
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

    fn checkContractionSuffix(slice: []const u8, start_idx: usize) usize {
        if (start_idx >= slice.len) return 0;
        const s = slice[start_idx..];

        if (s[0] != '\'') return 0;
        if (s.len < 2) return 0;

        const c1 = s[1];
        const c1_lower = c1 | 0x20;

        if (c1_lower == 's' or c1_lower == 't' or c1_lower == 'm' or c1_lower == 'd') {
            return 2;
        }

        if (s.len >= 3) {
            const c2 = s[2];
            const c2_lower = c2 | 0x20;
            if ((c1_lower == 'r' and c2_lower == 'e') or
                (c1_lower == 'v' and c2_lower == 'e') or
                (c1_lower == 'l' and c2_lower == 'l'))
            {
                return 3;
            }
        }

        return 0;
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
