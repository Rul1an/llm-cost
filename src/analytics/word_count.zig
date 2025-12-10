const std = @import("std");
const unicode = std.unicode;

/// Word counting mode for different language types
pub const WordCountMode = enum {
    /// Split on whitespace (Western languages)
    whitespace,
    /// Count Unicode codepoints (CJK approximation)
    character,
    /// Heuristic: auto-detect based on content
    heuristic,

    pub fn fromString(s: []const u8) ?WordCountMode {
        if (std.mem.eql(u8, s, "whitespace")) return .whitespace;
        if (std.mem.eql(u8, s, "character")) return .character;
        if (std.mem.eql(u8, s, "heuristic")) return .heuristic;
        return null;
    }

    pub fn toString(self: WordCountMode) []const u8 {
        return switch (self) {
            .whitespace => "whitespace",
            .character => "character",
            .heuristic => "heuristic",
        };
    }
};

/// Count words in text using specified mode
pub fn countWords(text: []const u8, mode: WordCountMode) usize {
    return switch (mode) {
        .whitespace => countWhitespaceSeparated(text),
        .character => countCodepoints(text),
        .heuristic => countHeuristic(text),
    };
}

/// Count whitespace-separated words (Western languages)
fn countWhitespaceSeparated(text: []const u8) usize {
    var count: usize = 0;
    var in_word = false;

    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (!is_space and !in_word) {
            count += 1;
            in_word = true;
        } else if (is_space) {
            in_word = false;
        }
    }

    return count;
}

/// Count Unicode codepoints (CJK approximation)
/// For CJK languages where words aren't space-separated
fn countCodepoints(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        const len = unicode.utf8ByteSequenceLength(text[i]) catch 1;
        count += 1;
        i += len;
    }

    return count;
}

/// Helper to decode UTF-8 codepoint from slice (manual implementation)
fn decodeUtf8Codepoint(bytes: []const u8, len: usize) !u21 {
    if (bytes.len < len) return error.InvalidUtf8;

    return switch (len) {
        1 => @as(u21, bytes[0]),
        2 => blk: {
            const b0: u21 = bytes[0] & 0x1F;
            const b1: u21 = bytes[1] & 0x3F;
            break :blk (b0 << 6) | b1;
        },
        3 => blk: {
            const b0: u21 = bytes[0] & 0x0F;
            const b1: u21 = bytes[1] & 0x3F;
            const b2: u21 = bytes[2] & 0x3F;
            break :blk (b0 << 12) | (b1 << 6) | b2;
        },
        4 => blk: {
            const b0: u21 = bytes[0] & 0x07;
            const b1: u21 = bytes[1] & 0x3F;
            const b2: u21 = bytes[2] & 0x3F;
            const b3: u21 = bytes[3] & 0x3F;
            break :blk (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;
        },
        else => error.InvalidUtf8,
    };
}

/// Heuristic word count: auto-detect CJK vs Western
/// If >30% CJK codepoints, use character mode; otherwise whitespace
fn countHeuristic(text: []const u8) usize {
    var cjk_count: usize = 0;
    var total_codepoints: usize = 0;
    var i: usize = 0;

    // First pass: analyze content
    while (i < text.len) {
        const len = unicode.utf8ByteSequenceLength(text[i]) catch 1;

        if (i + len <= text.len) {
            // Decode UTF-8 codepoint
            const codepoint = decodeUtf8Codepoint(text[i..], len) catch {
                i += 1;
                continue;
            };

            total_codepoints += 1;
            if (isCjkCodepoint(codepoint)) {
                cjk_count += 1;
            }
        }

        i += len;
    }

    // If >30% CJK, use character counting
    if (total_codepoints > 0 and cjk_count * 100 / total_codepoints > 30) {
        return countCodepoints(text);
    } else {
        return countWhitespaceSeparated(text);
    }
}

/// Check if codepoint is in CJK range
fn isCjkCodepoint(cp: u21) bool {
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return true;
    // CJK Unified Ideographs Extension B
    if (cp >= 0x20000 and cp <= 0x2A6DF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return true;
    // Hiragana
    if (cp >= 0x3040 and cp <= 0x309F) return true;
    // Katakana
    if (cp >= 0x30A0 and cp <= 0x30FF) return true;
    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;

    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "whitespace: basic English" {
    const text = "Hello world this is a test";
    try std.testing.expectEqual(@as(usize, 6), countWords(text, .whitespace));
}

test "whitespace: multiple spaces" {
    const text = "Hello   world    test";
    try std.testing.expectEqual(@as(usize, 3), countWords(text, .whitespace));
}

test "whitespace: empty string" {
    const text = "";
    try std.testing.expectEqual(@as(usize, 0), countWords(text, .whitespace));
}

test "whitespace: only spaces" {
    const text = "     ";
    try std.testing.expectEqual(@as(usize, 0), countWords(text, .whitespace));
}

test "character: ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(@as(usize, 5), countWords(text, .character));
}

test "character: Chinese" {
    const text = "你好世界"; // 4 Chinese characters
    try std.testing.expectEqual(@as(usize, 4), countWords(text, .character));
}

test "character: mixed" {
    const text = "Hello你好"; // 5 ASCII + 2 Chinese = 7 codepoints
    try std.testing.expectEqual(@as(usize, 7), countWords(text, .character));
}

test "heuristic: English defaults to whitespace" {
    const text = "Hello world this is English text";
    const whitespace_count = countWords(text, .whitespace);
    const heuristic_count = countWords(text, .heuristic);
    try std.testing.expectEqual(whitespace_count, heuristic_count);
}

test "heuristic: Chinese uses character mode" {
    const text = "你好世界这是中文"; // All Chinese
    const char_count = countWords(text, .character);
    const heuristic_count = countWords(text, .heuristic);
    try std.testing.expectEqual(char_count, heuristic_count);
}

test "WordCountMode: fromString" {
    try std.testing.expectEqual(WordCountMode.whitespace, WordCountMode.fromString("whitespace").?);
    try std.testing.expectEqual(WordCountMode.character, WordCountMode.fromString("character").?);
    try std.testing.expectEqual(WordCountMode.heuristic, WordCountMode.fromString("heuristic").?);
    try std.testing.expectEqual(@as(?WordCountMode, null), WordCountMode.fromString("invalid"));
}
