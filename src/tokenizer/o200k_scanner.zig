const std = @import("std");
const pre_tokenizer = @import("pre_tokenizer.zig");
const unicode = @import("unicode_tables.zig");
const SafeUtf8Iterator = @import("utf8.zig").SafeUtf8Iterator;

/// A specialized pre-tokenizer for 'o200k_base' that mimics the regex logic.
/// See `docs/o200k_pre_tokenizer.md` for branch definitions.
pub const O200kScanner = struct {
    /// Main tokenization loop matching regex priority.
    pub fn tokenize(_: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]pre_tokenizer.PreToken {
        var tokens = std.ArrayList(pre_tokenizer.PreToken).initCapacity(alloc, text.len / 4) catch return error.OutOfMemory;
        errdefer tokens.deinit(alloc);

        var i: usize = 0;
        while (i < text.len) {

            // Decode first codepoint (fallback to byte if invalid utf8, effectively Latin-1 replacement or error handling)
            // Tiktoken generally assumes valid UTF-8.
            // We use standard iterator-like decoding.

            // Decode codepoint

            // Strict Priority Order:
            // 1. Branch 1: Words (Lower suffix)
            // 2. Branch 2: Words (Upper / Lookahead)
            // 3. Branch 3: Numbers
            // 4. Branch 4: Punctuation
            // 5. Branch 5, 6, 7: Whitespace

            // We must try branches in order because regexes overlap (especially with optional prefixes).
            // Example: ".Hello" matches Punctuation (Branch 4)? No, Branch 1 allows prefix!
            // Regex Branch 1: `[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?`
            // ".Hello" -> Prefix "." (not L/N), Body "Hello" (Upper "H", Lower "ello"). Wait, Body must be Upper* Lower+.
            // "Hello": H (Upper), ello (Lower+). Matches Branch 1. Prefix empty.

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
                try tokens.append(alloc, .{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            // Note: Tiktoken regex order puts whitespace last (ish)?
            // Actually regex has 7 branches.
            // Branch 7 is `\s+`. Branch 5/6 are specific whitespace.
            // Branch 4 is Punctuation `?[^\s\p{L}\p{N}]+`.
            // If we have "   ", Branch 7 matches.
            // If punctuation fails, try whitespace.
            // 5. Branch 5: Whitespace ending in newline `\s*[\r\n]+`
            if (tryScanWhitespaceBranch5(text[i..])) |len| {
                try tokens.append(alloc, .{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            // 6. Branch 6: Trailing whitespace `\s+(?!\S)`
            if (tryScanWhitespaceBranch6(text[i..])) |len| {
                try tokens.append(alloc, .{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            // 7. Branch 7: Generic whitespace `\s+`
            if (tryScanWhitespaceBranch7(text[i..])) |len| {
                try tokens.append(alloc, .{ .text = text[i .. i + len] });
                i += len;
                continue;
            }

            // Fallback: Consume 1 byte.
            // This ensures forward progress on invalid UTF-8 or uncovered chars.
            try tokens.append(alloc, .{ .text = text[i .. i + 1] });
            i += 1;
        }

        return tokens.toOwnedSlice(alloc);
    }

    fn isWordUpperBody(cp: unicode.CodePoint) bool {
        return unicode.isLu(cp) or unicode.isLt(cp) or unicode.isLm(cp) or unicode.isLo(cp) or unicode.isMark(cp);
    }

    fn isWordLowerBody(cp: unicode.CodePoint) bool {
        return unicode.isLl(cp) or unicode.isLm(cp) or unicode.isLo(cp) or unicode.isMark(cp);
    }

    fn isPrefixChar(cp: unicode.CodePoint) bool {
        // [^\r\n\p{L}\p{N}]
        return cp != '\r' and cp != '\n' and !unicode.isLetter(cp) and !unicode.isNumber(cp);
    }

    /// Branch 1: Words (Lower Suffix)
    /// Regex: `[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?`
    fn tryScanWordBranch1(slice: []const u8) ?usize {
        // Now `cp` is the first character after the optional prefix.

        // Use prev_i trick or re-peek?
        // We need the index of `cp`.
        // Simplest: we know we just consumed `cp`.
        // But simply relying on `it.i` implies we need valid consumption logic.
        // Better refactor: Get `cp` and its `start_index` directly?
        // SafeUtf8Iterator doesn't return index.
        // Let's manually backtrack to "before cp".
        // BUT we don't know how much we advanced if it was invalid.
        // Actually, we do: `it.i` is current. We need `it.i` before the last call.
        // We can't know easily without tracking it.

        // Let's rewrite loop to peek or track prev_i.

        // Re-decoding:
        var it2 = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        var cp2 = it2.nextCodepoint() orelse return null;
        if (isPrefixChar(cp2)) {
            cp2 = it2.nextCodepoint() orelse return null;
        }
        // `it2.i` is now AFTER cp2. We want `it2.i` BEFORE cp2.
        // No wait, we need `start_body_idx` which is the index of `cp` (the first body char).
        // That is simply `it.i` from the line 114 (init) + prefix consumption.
        // If there was a prefix, `start_body_idx` is `it.i` (after prefix).
        // If no prefix, `start_body_idx` is 0.

        // Let's fix lines 114-128:
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        var start_body_idx: usize = 0;

        // Check first CP
        var cp_peek = it.peek() orelse return null;
        if (isPrefixChar(cp_peek)) {
            _ = it.nextCodepoint();
            start_body_idx = it.i;
            cp_peek = it.peek() orelse return null;
        }

        // Now `cp_peek` is the candidate first char of Body. `start_body_idx` is its position.
        // We consume it to match original local `cp` variable.
        _ = it.nextCodepoint();
        // cp is not used subsequently as we re-init iterators from start_body_idx

        // Backtrack loop for `Upperish* Lowerish+`
        // `upper_end_candidate` represents the end of the `Upperish*` part.
        // We start by greedily consuming all `Upperish` characters.
        var upper_it = SafeUtf8Iterator{ .bytes = slice, .i = start_body_idx };
        var upper_end_candidate: usize = start_body_idx;
        var last_upper_i: usize = start_body_idx;

        while (upper_it.nextCodepoint()) |c| {
            if (isWordUpperBody(c)) {
                upper_end_candidate = upper_it.i;
            } else {
                // Not an Upperish char, so this is the end of the greedy Upperish run.
                // Backtrack the iterator to the start of this non-Upperish char.
                // Not an Upperish char. Backtrack to before this char.
                // We need to know previous `it.i`.
                // SafeUtf8Iterator logic: we need to track `prev_i` inside loop.
                upper_it.i = last_upper_i;
                break;
            }
            last_upper_i = upper_it.i;
        }

        // Now, `upper_end_candidate` is the end of the maximal `Upperish*` run.
        // `upper_it.i` is also at `upper_end_candidate`.

        // We need to try to match `Lowerish+` starting from `upper_end_candidate`.
        // If it fails, we "backtrack" by shortening the `Upperish*` run by one character
        // and trying `Lowerish+` again. This continues until `Upperish*` is empty
        // or `Lowerish+` matches.

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
                    // Not a Lowerish char, end of Lowerish run.
                    // Not a Lowerish char. Backtrack.
                    lower_it.i = last_lower_i;
                    break;
                }
                last_lower_i = lower_it.i;
            }

            if (has_lower) {
                // Branch 1 Matched Body!
                // Check Suffix (e.g. 's, 't)
                const suffix_len = checkContractionSuffix(slice, lower_matched_len);
                return lower_matched_len + suffix_len;
            }

            // Failed to match Lowerish+. Need to backtrack the Upperish* part.
            // Shorten `current_upper_end` by one character.
            if (current_upper_end == start_body_idx) {
                // Cannot backtrack further, Upperish* is already empty.
                return null;
            }

            // Find the start of the character *before* `current_upper_end`.
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

        var prefix_len: usize = 0;
        // 1. Optional Prefix
        if (isPrefixChar(cp)) {
            prefix_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            cp = it.nextCodepoint() orelse return null; // Advance past prefix
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

    /// Branch 4: Punctuation (Everything Else)
    fn tryScanPunctuation(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        var cp = it.nextCodepoint() orelse return null;
        var start_body: usize = 0;

        // Optional space prefix
        if (cp == ' ') {
            start_body = it.i;
            cp = it.nextCodepoint() orelse return null; // consumed prefix, if EOF fail pattern `[^\sLN]+` requires 1 char
        }

        // Body: 1+ chars of [^\s\p{L}\p{N}]
        if (unicode.isWhitespace(cp) or unicode.isLetter(cp) or unicode.isNumber(cp)) {
            return null;
        }
        var end_body = it.i;

        while (it.nextCodepoint()) |c| {
            if (unicode.isWhitespace(c) or unicode.isLetter(c) or unicode.isNumber(c)) {
                // End of body
                // Back up? Regex `[...]+` is greedy.
                // So we stop here.
                // Logic: regex `[^\sLN]+` matches as many as possible.
                // So we stop at first mismatch.
                // We do NOT backup the iterator because `it.i` is at end of `c`.
                // The body ENDS before `c`.
                // `start_body` to `it.i - len(c)`
                end_body = it.i - (std.unicode.utf8CodepointSequenceLength(c) catch 1);
                // We need to verify logic about suffix handling next.
                // Reset iterator to end_body to scan suffix?
                // Actually we can just proceed.
                // `c` is the char that failed the body check.
                // Does it match suffix `[\r\n/]*` ?
                // Suffix is optional.
                // If `c` matches suffix, we consume it.
                break;
            }
            end_body = it.i;
        }

        // Check Suffix: [\r\n/]*
        // Start scanning suffix from `end_body`.
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
        // Must start with Number (checked by caller dispatch usually, but safe to check)
        // Need to decode codepoints!
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;

        if (!unicode.isNumber(cp1)) return null;

        // Consumed 1 char. Approx length?
        // We need byte length of the matched sequence.
        // It's `it.i` so far? No, `it.i` is current index.
        // First char ended at `it.i`.

        var len_bytes: usize = it.i;
        var count: usize = 1;

        // Greedy consume up to 2 more digits
        while (count < 3) {
            // Peek next char? Iterator modifies state.
            // Use clone or just continue relative to slice.
            if (it.nextCodepoint()) |cp| {
                if (unicode.isNumber(cp)) {
                    count += 1;
                    len_bytes = it.i;
                    continue;
                }
                // Not a number, stop
            }
            break;
        }

        return len_bytes;
    }

    /// Branch 5: `\s*[\r\n]+`
    /// Matches whitespace that ends in at least one newline/CR.
    fn tryScanWhitespaceBranch5(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;
        if (!unicode.isWhitespace(cp1)) return null;

        // 1. Scan greedy whitespace
        var ws_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            ws_end = it.i;
        }

        // 2. Backtrack to find the last newline in this run.
        // The match is the longest prefix of the run that ends in [\r\n].
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
    /// Matches greedy whitespace ONLY if it reaches EOF (or followed by whitespace, impossible since greedy).
    fn tryScanWhitespaceBranch6(slice: []const u8) ?usize {
        var it = SafeUtf8Iterator{ .bytes = slice, .i = 0 };
        const cp1 = it.nextCodepoint() orelse return null;
        if (!unicode.isWhitespace(cp1)) return null;

        var ws_end = it.i;
        while (it.nextCodepoint()) |cp| {
            if (!unicode.isWhitespace(cp)) break;
            ws_end = it.i;
        }

        // Lookahead: Must be EOF.
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

        // Suffixes: 's, 't, 're, 've, 'm, 'll, 'd (case insensitive)
        // Must start with "'" (0x27)
        if (s[0] != '\'') return 0;

        if (s.len < 2) return 0;

        // Len 2 candidates: 's, 't, 'm, 'd
        const c1 = s[1];
        // Lowercase conversion for ASCII is simple (c | 0x20).
        const c1_lower = c1 | 0x20;

        if (c1_lower == 's' or c1_lower == 't' or c1_lower == 'm' or c1_lower == 'd') {
            return 2;
        }

        if (s.len >= 3) {
            const c2 = s[2];
            const c2_lower = c2 | 0x20;
            // Len 3 candidates: 're, 've, 'll
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
