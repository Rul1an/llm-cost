const std = @import("std");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const openai_tok = tokenizer_mod.openai;
const registry = tokenizer_mod.registry;
const BpeVersion = tokenizer_mod.pre_tokenizer.BpeVersion;

pub const EngineError = error{
    ModelNotFound,
    InvalidPricing,
    TokenizerNotSupported,
    TokenizerInternalError,
    DisallowedSpecialToken,
};

pub const SpecialMode = union(enum) {
    /// Default: behave like tiktoken's `encode`:
    /// any occurrence of a special token in text is an error.
    strict,

    /// Treat all specials as ordinary text, like tiktoken's `encode_ordinary`.
    ordinary,

    /// Only these special token names are allowed; others cause an error.
    allow_list: []const []const u8,
};

pub const TokenizerConfig = struct {
    spec: ?registry.EncodingSpec = null,
    /// Logical model name (e.g. "gpt-4o").
    model_name: []const u8,
    bpe_version: BpeVersion = .v2,
};

pub const TokenResult = struct {
    tokens: usize,
    // Add other fields if needed, e.g. text offsets
};

fn isAllowedSpecial(name: []const u8, mode: SpecialMode) bool {
    return switch (mode) {
        .strict => false,
        .ordinary => true,
        .allow_list => |list| blk: {
            for (list) |allowed| {
                if (std.mem.eql(u8, allowed, name)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Returns byte index of first disallowed special token in `text`,
/// or null if none found.
fn findDisallowedSpecial(
    text: []const u8,
    spec: registry.EncodingSpec,
    mode: SpecialMode,
) ?usize {
    // Fast exit: in ordinary mode we never treat specials specially.
    switch (mode) {
        .ordinary => return null,
        else => {},
    }

    // Simple O(#specials * N * len) approach.
    var best: ?usize = null;

    for (spec.special_tokens) |tok| {
        if (isAllowedSpecial(tok.token, mode)) continue;

        if (std.mem.indexOfPos(u8, text, 0, tok.token)) |idx| {
            // Found a match, check if it's the earliest so far
            if (best == null or idx < best.?) {
                best = idx;
            }
        }
    }
    return best;
}

/// Resolves best tokenizer configuration for a given model ID.
pub fn resolveConfig(model_id: []const u8) !TokenizerConfig {
    const spec = registry.Registry.getEncodingForModel(model_id);
    return TokenizerConfig{
        .spec = spec,
        .model_name = model_id,
        // Approximate is handled internally by estimateTokens
    };
}

/// Core API: calculate token count for text using specified tokenizer.
pub fn countTokens(
    alloc: std.mem.Allocator,
    text: []const u8,
    cfg: TokenizerConfig,
) !usize {
    const res = try estimateTokens(alloc, cfg, text, .strict);
    return res.tokens;
}

pub fn estimateTokens(
    alloc: std.mem.Allocator,
    cfg: TokenizerConfig,
    text: []const u8,
    special_mode: SpecialMode,
) EngineError!TokenResult {
    if (cfg.spec) |spec| {
        // Check for disallowed special tokens before processing
        if (findDisallowedSpecial(text, spec, special_mode)) |_| {
            return EngineError.DisallowedSpecialToken;
        }

        // Use OpenAI-style tokenizer for known specs (BPE based)
        var tok = openai_tok.OpenAITokenizer.init(alloc, .{
            .spec = spec,
            .approximate_ok = true,
            .bpe_version = cfg.bpe_version,
        }) catch return EngineError.TokenizerInternalError;
        defer tok.deinit(alloc);

        const res = tok.count(alloc, text) catch return EngineError.TokenizerInternalError;
        return .{ .tokens = res.tokens };
    } else {
        // Fallback to simple whitespace
        const count = simpleWordLikeCount(text);
        return .{ .tokens = count };
    }
}

/// Simple whitespace-word counter as fallback.
fn simpleWordLikeCount(text: []const u8) usize {
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

test "findDisallowedSpecial logic" {
    // Create a dummy spec for testing
    const specials = [_]registry.EncodingSpec.SpecialToken{
        .{ .token = "<|endoftext|>", .rank = 1 },
        .{ .token = "<|special|>", .rank = 2 },
    };
    const spec = registry.EncodingSpec{
        .name = "test_spec",
        .pat_str = "",
        .vocab_data = "",
        .special_tokens = &specials,
    };

    const text = "Hello <|endoftext|> world";

    // Strict mode: should find it
    if (findDisallowedSpecial(text, spec, .strict)) |idx| {
        try std.testing.expectEqual(@as(usize, 6), idx);
    } else {
        return error.TestExpectedFound;
    }

    // Ordinary mode: should not find it
    if (findDisallowedSpecial(text, spec, .ordinary)) |_| {
        return error.TestExpectedNull;
    }

    // Allow list (not allowed): should find it
    const allowed = [_][]const u8{"<|special|>"};
    if (findDisallowedSpecial(text, spec, .{ .allow_list = &allowed })) |idx| {
        try std.testing.expectEqual(@as(usize, 6), idx);
    } else {
        return error.TestExpectedFound;
    }

    // Allow list (allowed): should not find it
    const allowed_eot = [_][]const u8{"<|endoftext|>"};
    if (findDisallowedSpecial(text, spec, .{ .allow_list = &allowed_eot })) |_| {
        return error.TestExpectedNull;
    }

    // Test text with no special tokens
    const safe_text = "Just normal text";
    if (findDisallowedSpecial(safe_text, spec, .strict)) |_| {
        return error.TestExpectedNull;
    }

    // Test Earliest Occurrence:
    // Text has <|special|> at index 6 and <|endoftext|> at index 20.
    // Logic must return 6, not 20, regardless of spec iteration order.
    // Note: in our dummy spec, endoftext is first in list (rank 1), special is second (rank 2).
    // If logic was "return first match in loop", it might find endoftext first if it processed full text for each token in order.
    // Wait, simple loop `for (specials) |tok| { indexOf }` finds `endoftext` at 20. Then finds `special` at 6.
    // If we didn't track min, we'd return 20 (first iteration match).
    // With tracking min, we should get 6.
    const multi_text = "Hello <|special|> and <|endoftext|>";
    if (findDisallowedSpecial(multi_text, spec, .strict)) |idx| {
        try std.testing.expectEqual(@as(usize, 6), idx);
    } else {
        return error.TestExpectedFound;
    }
}
