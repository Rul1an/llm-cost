const std = @import("std");

/// A complete specification for a BPE tokenizer encoding.
/// This struct holds all static configuration data needed to reconstruct the tokenizer.
pub const EncodingSpec = struct {
    /// Canonical name of the encoding (e.g. "cl100k_base", "o200k_base")
    name: []const u8,

    /// Regex pattern used for pre-tokenization splitting.
    /// This is strictly for documentation/verification in v0.2,
    /// as we might implement hand-written splitters for performance.
    pat_str: []const u8,

    /// Raw BPE vocabulary data (tiktoken binary format).
    vocab_data: []const u8,

    /// Special tokens map (name -> rank).
    /// For the static registry, we can use a slice of pairs for zero-alloc lookup.
    special_tokens: []const SpecialToken,

    pub const SpecialToken = struct {
        token: []const u8,
        rank: u32,
    };
};

/// known encodings registry
pub const Registry = struct {
    pub const cl100k_specials = [_]EncodingSpec.SpecialToken{
         .{ .token = "<|endoftext|>", .rank = 100257 },
         .{ .token = "<|fim_prefix|>", .rank = 100258 },
         .{ .token = "<|fim_middle|>", .rank = 100259 },
         .{ .token = "<|fim_suffix|>", .rank = 100260 },
         .{ .token = "<|endofprompt|>", .rank = 100276 },
    };

    pub const cl100k_base = EncodingSpec{
        .name = "cl100k_base",
        .pat_str = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
        .vocab_data = "", // Empty for now; cl100k not fully supported in v0.2
        .special_tokens = &cl100k_specials,
    };

    pub const o200k_specials = [_]EncodingSpec.SpecialToken{
        .{ .token = "<|endoftext|>", .rank = 199999 },
        .{ .token = "<|endofprompt|>", .rank = 200018 },
    };

    pub const o200k_base = EncodingSpec{
        .name = "o200k_base",
        .pat_str = "[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]*[\\p{Ll}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]+|[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]+(?=[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]|\\s|\\p{P}|\\p{S}|\\p{C}|$)|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n/]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
        .vocab_data = @embedFile("../data/o200k_base.bin"),
        .special_tokens = &o200k_specials,
    };

    pub fn get(name: []const u8) ?EncodingSpec {
        if (std.mem.eql(u8, name, "cl100k_base")) return cl100k_base;
        if (std.mem.eql(u8, name, "o200k_base")) return o200k_base;
        return null;
    }
};
