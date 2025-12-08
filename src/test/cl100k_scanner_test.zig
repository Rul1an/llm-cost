const std = @import("std");
const scanner = @import("../tokenizer/cl100k_scanner.zig").Cl100kScanner;

test "cl100k contractions" {
    const alloc = std.testing.allocator;
    // " don't I'll"
    // " don" matches Word (Letter)
    // "'t" matches Contraction
    // " I" matches Word (Letter)
    // "'ll" matches Contraction
    const t = try scanner.tokenize(undefined, alloc, " don't I'll");
    defer alloc.free(t);

    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings(" don", t[0].text);
    try std.testing.expectEqualStrings("'t", t[1].text);
    try std.testing.expectEqualStrings(" I", t[2].text);
    try std.testing.expectEqualStrings("'ll", t[3].text);
}

test "cl100k words alphanumeric split" {
    const alloc = std.testing.allocator;
    // "Hello"
    const t1 = try scanner.tokenize(undefined, alloc, "Hello");
    defer alloc.free(t1);
    try std.testing.expectEqualStrings("Hello", t1[0].text);

    // "h3ll0" -> "h", "3", "ll", "0"
    // cl100k STRICT separation of Letters and Numbers.
    const t2 = try scanner.tokenize(undefined, alloc, "h3ll0");
    defer alloc.free(t2);
    try std.testing.expectEqual(@as(usize, 4), t2.len);
    try std.testing.expectEqualStrings("h", t2[0].text);
    try std.testing.expectEqualStrings("3", t2[1].text);
    try std.testing.expectEqualStrings("ll", t2[2].text);
    try std.testing.expectEqualStrings("0", t2[3].text);

    // " don't" (Prefix + Body + Suffix)
    // " don't" -> matches Contraction? No, contraction has no space prefix.
    // matches Word? " don" (prefix space, body 'd','o','n').
    // Remainder "'t" -> matches Contraction "'t".
    // So [" don", "'t"]
    const t3 = try scanner.tokenize(undefined, alloc, " don't");
    defer alloc.free(t3);
    try std.testing.expectEqual(@as(usize, 2), t3.len);
    try std.testing.expectEqualStrings(" don", t3[0].text);
    try std.testing.expectEqualStrings("'t", t3[1].text);
}

test "cl100k numbers breakdown" {
    const alloc = std.testing.allocator;
    // "12345" -> "123", "45"
    // Regex `\p{N}{1,3}`
    const t1 = try scanner.tokenize(undefined, alloc, "12345");
    defer alloc.free(t1);
    try std.testing.expectEqual(@as(usize, 2), t1.len);
    try std.testing.expectEqualStrings("123", t1[0].text);
    try std.testing.expectEqualStrings("45", t1[1].text);
}

test "cl100k punctuation" {
    const alloc = std.testing.allocator;
    const t = try scanner.tokenize(undefined, alloc, "! ...");
    defer alloc.free(t);
    // "!" -> Punctuation.
    // " ..." -> Punctuation (Regex ` ?[^\sLN]+`. Prefix space accepted).
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqualStrings("!", t[0].text);
    try std.testing.expectEqualStrings(" ...", t[1].text);
}

test "cl100k whitespace" {
    const alloc = std.testing.allocator;
    // Same as o200k
    const t = try scanner.tokenize(undefined, alloc, " \n ");
    defer alloc.free(t);
    try std.testing.expectEqualStrings(" \n", t[0].text);
    try std.testing.expectEqualStrings(" ", t[1].text);
}
