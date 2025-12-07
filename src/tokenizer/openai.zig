const std = @import("std");

pub const TokenizerError = error{
    UnsupportedModel,
};

/// Minimal metadata for v0.1.
pub const OpenAITokenizerKind = enum {
    cl100k,
    o200k,
};

/// Map logical model name to tokenizer kind.
pub fn resolveTokenizerKind(model_name: []const u8) ?OpenAITokenizerKind {
    if (std.mem.startsWith(u8, model_name, "gpt-4o")) return .o200k;
    if (std.mem.startsWith(u8, model_name, "gpt-4.1")) return .o200k;
    if (std.mem.startsWith(u8, model_name, "gpt-3.5")) return .cl100k;
    // Fallback for v1 is usually handling unknown models gracefully or default
    return null;
}

/// Core API for engine:
/// - Selects tokenizer based on kind.
/// - Counts tokens (approximate or exact).
pub fn estimateTokens(
    alloc: std.mem.Allocator,
    model_name: []const u8,
    text: []const u8,
) TokenizerError!usize {
    _ = alloc; // Future: BPE rank tables

    const kind = resolveTokenizerKind(model_name) orelse
        return TokenizerError.UnsupportedModel;

    return switch (kind) {
        .cl100k, .o200k => simpleApproximateCount(text),
    };
}

/// Placeholder until real BPE implementation.
fn simpleApproximateCount(text: []const u8) usize {
    var in_word = false;
    var count: usize = 0;

    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (!is_space and !in_word) {
            in_word = true;
            count += 1;
        } else if (is_space) {
            in_word = false;
        }
    }
    return count;
}
