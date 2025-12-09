const std = @import("std");
const scanner = @import("../tokenizer/o200k_scanner.zig").O200kScanner;
const pre_tokenizer = @import("../tokenizer/pre_tokenizer.zig");

test "Branch 5: Whitespace ending in newline" {
    const alloc = std.testing.allocator;

    // Case 1: Simple match
    // "  \n" -> Branch 5 matches full string.
    const tokens1 = try scanner.tokenize(undefined, alloc, "  \n");
    defer alloc.free(tokens1);
    try std.testing.expectEqual(@as(usize, 1), tokens1.len);
    try std.testing.expectEqualStrings("  \n", tokens1[0].text);

    // Case 2: Mixed newline types
    // " \r\n" -> Branch 5 matches full string.
    const tokens2 = try scanner.tokenize(undefined, alloc, " \r\n");
    defer alloc.free(tokens2);
    try std.testing.expectEqual(@as(usize, 1), tokens2.len);
    try std.testing.expectEqualStrings(" \r\n", tokens2[0].text);
}

test "Branch 5 vs Branch 7 Priority" {
    const alloc = std.testing.allocator;

    // Case: "  \n  "
    // Branch 5 (`\s*[\r\n]+`) should match "  \n" first.
    // Leaving "  " to be matched by Branch 7.
    const tokens = try scanner.tokenize(undefined, alloc, "  \n  ");
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("  \n", tokens[0].text); // Branch 5
    try std.testing.expectEqualStrings("  ", tokens[1].text); // Branch 7
}

test "Branch 6: Trailing whitespace EOF" {
    const alloc = std.testing.allocator;

    // Case: "  " at EOF
    // Branch 5 fails (no newline).
    // Branch 6 matches (`\s+(?!\S)` and we are at EOF).
    const tokens = try scanner.tokenize(undefined, alloc, "  ");
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("  ", tokens[0].text);
}

test "Branch 7: Generic whitespace" {
    const alloc = std.testing.allocator;

    // Case: "   a"
    // "   " matches Branch 7.
    // "a" matches Branch 1 (or other).
    const tokens = try scanner.tokenize(undefined, alloc, "   a");
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("   ", tokens[0].text); // Branch 7
    try std.testing.expectEqualStrings("a", tokens[1].text);
}

test "Complex Mixed Whitespace" {
    const alloc = std.testing.allocator;

    // Input: " \n \r \n  a"
    // 1. " \n \r \n" -> Ends in newlines. Matches Branch 5.
    // Remainder: "  a"
    // 2. "  " -> Followed by 'a'. Not EOF. Br 5 fails. Br 6 fails (next is 'a'). Br 7 matches.
    // Remainder: "a"
    const tokens = try scanner.tokenize(undefined, alloc, " \n \r \n  a");
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings(" \n \r \n", tokens[0].text);
    try std.testing.expectEqualStrings("  ", tokens[1].text);
    try std.testing.expectEqualStrings("a", tokens[2].text);
}

test "Senior Review Edge Cases" {
    const alloc = std.testing.allocator;

    // Case 1: " \n "
    // Branch 5 (\s*[\r\n]+) should see " \n" as ending in newline.
    // Length 2. Remainder " ".
    // " " triggers Branch 6 (EOF) or 7.
    // Result: [" \n", " "]
    const t1 = try scanner.tokenize(undefined, alloc, " \n ");
    defer alloc.free(t1);
    try std.testing.expectEqual(@as(usize, 2), t1.len);
    try std.testing.expectEqualStrings(" \n", t1[0].text);
    try std.testing.expectEqualStrings(" ", t1[1].text);

    // Case 2: "\r\n\r\n"
    // Greedy \s* consumes all. [\r\n]+ consumes at least one.
    // TryScanWhitespaceBranch5 matches full string of newlines.
    const t2 = try scanner.tokenize(undefined, alloc, "\r\n\r\n");
    defer alloc.free(t2);
    try std.testing.expectEqual(@as(usize, 1), t2.len);
    try std.testing.expectEqualStrings("\r\n\r\n", t2[0].text);

    // Case 3: " \n\nx"
    // " \n\nx" -> " \n\n" (Br 5) + "x"
    const t3 = try scanner.tokenize(undefined, alloc, " \n\nx");
    defer alloc.free(t3);
    try std.testing.expectEqual(@as(usize, 2), t3.len);
    try std.testing.expectEqualStrings(" \n\n", t3[0].text);
    try std.testing.expectEqualStrings("x", t3[1].text);

    // Case 4: "a \r\n b"
    // "a" -> Br1
    // " \r\n " -> " \r\n" (Br 5) - Backtracks from space
    // " b" -> Br1 (Space is valid prefix for Word branch)
    const t4 = try scanner.tokenize(undefined, alloc, "a \r\n b");
    defer alloc.free(t4);
    try std.testing.expectEqual(@as(usize, 3), t4.len);
    try std.testing.expectEqualStrings("a", t4[0].text);
    try std.testing.expectEqualStrings(" \r\n", t4[1].text);
    try std.testing.expectEqualStrings(" b", t4[2].text);
}

test "strict whitespace scanner - invalid utf8 safety" {
    const alloc = std.testing.allocator;
    // scanner is imported as 'scanner' in this file (which is O200kScanner from line 2)

    // Sequence that previously caused panic in Utf8Iterator
    // 0xFF is invalid start byte.
    // 0xC0 0xAF is overlong encoding (sometimes panic or fallback).
    const invalid_input = "\xFF\xFF\xC0\x20\x80";

    // Should NOT panic
    const t = try scanner.tokenize(undefined, alloc, invalid_input);
    defer alloc.free(t);

    // We expect fallback bytes or replacement chars.
    // Just verify we got *something* and survived.
    try std.testing.expect(t.len > 0);
}
