const std = @import("std");

/// Unicode codepoint type
pub const CodePoint = u21;

// =============================================================================
// Unicode General Category Classification
// =============================================================================

/// Check if codepoint is a Letter (L)
pub fn isLetter(cp: CodePoint) bool {
    return isLl(cp) or isLu(cp) or isLt(cp) or isLm(cp) or isLo(cp);
}

/// Check if codepoint is Lowercase Letter (Ll)
pub fn isLl(cp: CodePoint) bool {
    // Basic Latin lowercase
    if (cp >= 'a' and cp <= 'z') return true;

    // Latin Extended-A lowercase (selected ranges)
    if (cp >= 0x00E0 and cp <= 0x00F6) return true; // à-ö
    if (cp >= 0x00F8 and cp <= 0x00FF) return true; // ø-ÿ

    // Greek lowercase
    if (cp >= 0x03B1 and cp <= 0x03C9) return true; // α-ω

    // Cyrillic lowercase
    if (cp >= 0x0430 and cp <= 0x044F) return true; // а-я

    // Full Unicode Ll check would require lookup tables
    // This is a simplified version for common cases
    return false;
}

/// Check if codepoint is Uppercase Letter (Lu)
pub fn isLu(cp: CodePoint) bool {
    // Basic Latin uppercase
    if (cp >= 'A' and cp <= 'Z') return true;

    // Latin Extended-A uppercase
    if (cp >= 0x00C0 and cp <= 0x00D6) return true; // À-Ö
    if (cp >= 0x00D8 and cp <= 0x00DE) return true; // Ø-Þ

    // Greek uppercase
    if (cp >= 0x0391 and cp <= 0x03A9) return true; // Α-Ω

    // Cyrillic uppercase
    if (cp >= 0x0410 and cp <= 0x042F) return true; // А-Я

    return false;
}

/// Check if codepoint is Titlecase Letter (Lt)
pub fn isLt(cp: CodePoint) bool {
    // Titlecase letters are rare (e.g., Dž, Lj, Nj)
    return switch (cp) {
        0x01C5, 0x01C8, 0x01CB, 0x01F2 => true, // Dž, Lj, Nj, Dz
        0x1F88...0x1F8F => true, // Greek extended
        0x1F98...0x1F9F => true,
        0x1FA8...0x1FAF => true,
        0x1FBC, 0x1FCC, 0x1FFC => true,
        else => false,
    };
}

/// Check if codepoint is Modifier Letter (Lm)
pub fn isLm(cp: CodePoint) bool {
    return switch (cp) {
        0x02B0...0x02C1 => true, // Modifier letters
        0x02C6...0x02D1 => true,
        0x02E0...0x02E4 => true,
        0x02EC, 0x02EE => true,
        0x0374, 0x037A => true, // Greek
        0x0559 => true, // Armenian
        0x0640 => true, // Arabic tatweel
        0x06E5, 0x06E6 => true, // Arabic
        0x07F4, 0x07F5 => true, // NKo
        0x07FA => true,
        0x081A, 0x0824, 0x0828 => true, // Samaritan
        0x0971 => true, // Devanagari
        0x0E46 => true, // Thai
        0x0EC6 => true, // Lao
        0x10FC => true, // Georgian
        0x17D7 => true, // Khmer
        0x1843 => true, // Mongolian
        0x1AA7 => true, // Tai Tham
        0x1C78...0x1C7D => true, // Ol Chiki
        0x1D2C...0x1D6A => true, // Phonetic extensions
        0x1D78 => true,
        0x1D9B...0x1DBF => true,
        0x2071, 0x207F => true, // Superscripts
        0x2090...0x209C => true, // Subscripts
        0x2C7C, 0x2C7D => true, // Latin Extended-C
        0x2D6F => true, // Tifinagh
        0x2E2F => true, // Vertical tilde
        0x3005 => true, // CJK ideographic iteration mark
        0x3031...0x3035 => true, // CJK
        0x303B => true,
        0x309D, 0x309E => true, // Hiragana
        0x30FC...0x30FE => true, // Katakana
        0xA015 => true, // Yi
        0xA4F8...0xA4FD => true, // Lisu
        0xA60C => true, // Vai
        0xA67F => true, // Cyrillic
        0xA717...0xA71F => true, // Modifier tone letters
        0xA770 => true, // Latin Extended-D
        0xA788 => true,
        0xA7F8, 0xA7F9 => true,
        0xA9CF => true, // Javanese
        0xA9E6 => true, // Myanmar
        0xAA70 => true, // Myanmar Extended-A
        0xAADD => true, // Tai Viet
        0xAAF3, 0xAAF4 => true, // Meetei Mayek
        0xAB5C...0xAB5F => true, // Latin Extended-E
        0xFF70 => true, // Halfwidth Katakana
        0xFF9E, 0xFF9F => true,
        else => false,
    };
}

/// Check if codepoint is Other Letter (Lo)
pub fn isLo(cp: CodePoint) bool {
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;

    // CJK Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return true;

    // Hiragana
    if (cp >= 0x3041 and cp <= 0x3096) return true;

    // Katakana
    if (cp >= 0x30A1 and cp <= 0x30FA) return true;

    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;

    // Arabic letters (simplified)
    if (cp >= 0x0621 and cp <= 0x064A) return true;

    // Hebrew letters
    if (cp >= 0x05D0 and cp <= 0x05EA) return true;

    // Thai
    if (cp >= 0x0E01 and cp <= 0x0E3A) return true;

    // Devanagari
    if (cp >= 0x0905 and cp <= 0x0939) return true;

    return false;
}

/// Check if codepoint is a Mark (M)
pub fn isMark(cp: CodePoint) bool {
    // Combining Diacritical Marks
    if (cp >= 0x0300 and cp <= 0x036F) return true;

    // Combining Diacritical Marks Extended
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return true;

    // Combining Diacritical Marks Supplement
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return true;

    // Combining Diacritical Marks for Symbols
    if (cp >= 0x20D0 and cp <= 0x20FF) return true;

    // Combining Half Marks
    if (cp >= 0xFE20 and cp <= 0xFE2F) return true;

    return false;
}

/// Check if codepoint is a Number (N)
pub fn isNumber(cp: CodePoint) bool {
    // ASCII digits
    if (cp >= '0' and cp <= '9') return true;

    // Superscript/subscript digits
    if (cp == 0x00B2 or cp == 0x00B3 or cp == 0x00B9) return true; // ²³¹
    if (cp >= 0x2070 and cp <= 0x2079) return true;
    if (cp >= 0x2080 and cp <= 0x2089) return true;

    // Fullwidth digits
    if (cp >= 0xFF10 and cp <= 0xFF19) return true;

    // Roman numerals
    if (cp >= 0x2160 and cp <= 0x2188) return true;

    // Arabic-Indic digits
    if (cp >= 0x0660 and cp <= 0x0669) return true;

    // Extended Arabic-Indic digits
    if (cp >= 0x06F0 and cp <= 0x06F9) return true;

    // Devanagari digits
    if (cp >= 0x0966 and cp <= 0x096F) return true;

    // Bengali digits
    if (cp >= 0x09E6 and cp <= 0x09EF) return true;

    // CJK numbers
    if (cp == 0x3007) return true; // 〇
    if (cp >= 0x3021 and cp <= 0x3029) return true; // 〡-〩

    return false;
}

/// Check if codepoint is Whitespace
pub fn isWhitespace(cp: CodePoint) bool {
    return switch (cp) {
        // ASCII whitespace
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        // Unicode whitespace
        0x00A0 => true, // Non-breaking space
        0x1680 => true, // Ogham space mark
        0x2000...0x200A => true, // Various spaces (en quad, em quad, etc.)
        0x2028 => true, // Line separator
        0x2029 => true, // Paragraph separator
        0x202F => true, // Narrow no-break space
        0x205F => true, // Medium mathematical space
        0x3000 => true, // Ideographic space
        else => false,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "isLetter: ASCII" {
    try std.testing.expect(isLetter('a'));
    try std.testing.expect(isLetter('Z'));
    try std.testing.expect(!isLetter('0'));
    try std.testing.expect(!isLetter(' '));
}

test "isLetter: Unicode" {
    try std.testing.expect(isLetter(0x00E9)); // é
    try std.testing.expect(isLetter(0x03B1)); // α
    try std.testing.expect(isLetter(0x4E00)); // 一 (CJK)
}

test "isNumber: digits" {
    try std.testing.expect(isNumber('0'));
    try std.testing.expect(isNumber('9'));
    try std.testing.expect(!isNumber('a'));
    try std.testing.expect(isNumber(0xFF10)); // Fullwidth 0
}

test "isWhitespace: common cases" {
    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace('\n'));
    try std.testing.expect(isWhitespace(0x3000)); // Ideographic space
    try std.testing.expect(!isWhitespace('a'));
}

test "isLu: uppercase" {
    try std.testing.expect(isLu('A'));
    try std.testing.expect(isLu('Z'));
    try std.testing.expect(!isLu('a'));
    try std.testing.expect(isLu(0x0391)); // Α (Greek Alpha)
}

test "isLl: lowercase" {
    try std.testing.expect(isLl('a'));
    try std.testing.expect(isLl('z'));
    try std.testing.expect(!isLl('A'));
    try std.testing.expect(isLl(0x03B1)); // α (Greek alpha)
}
