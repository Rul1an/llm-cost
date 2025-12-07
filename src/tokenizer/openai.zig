const std = @import("std");
const bpe = @import("bpe.zig");

pub const Kind = enum {
    cl100k_base,
    o200k_base,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .cl100k_base => "cl100k_base",
            .o200k_base => "o200k_base",
        };
    }
};

pub const Result = struct {
    tokens: usize,
    approximate: bool,
};

pub const Config = struct {
    kind: Kind,
    approximate_ok: bool = false,
};

/// The OpenAI Tokenizer instance.
/// Wraps the low-level BPE engine (if available).
pub const OpenAITokenizer = struct {
    kind: Kind,
    engine: ?bpe.BpeEngine = null,

    // Static data embedding
    const o200k_data = @embedFile("../data/o200k_base.bin");

    pub fn init(cfg: Config) !OpenAITokenizer {
        // Initialize BPE engine based on kind
        var eng: ?bpe.BpeEngine = null;

        if (cfg.kind == .o200k_base) {
            // Lazy-init logic or just direct init since it's zero-copy?
            // Zero-copy init is cheap. We can do it every time or store it.
            // BpeEngine is small (2 slices).
            eng = bpe.BpeEngine.init(o200k_data) catch |err| {
                if (cfg.approximate_ok) return OpenAITokenizer{ .kind = cfg.kind, .engine = null };
                return err;
            };
        } else if (cfg.kind == .cl100k_base) {
            // No data yet
            if (cfg.approximate_ok) {
                eng = null;
            } else {
                return error.UnsupportedModel;
            }
        }

        return OpenAITokenizer{
            .kind = cfg.kind,
            .engine = eng,
        };
    }

    pub fn count(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) !Result {
        if (self.engine) |eng| {
            const tokens = try eng.encode(alloc, text);
            defer alloc.free(tokens);
            return Result{ .tokens = tokens.len, .approximate = false };
        } else {
            // Fallback
            return Result{ .tokens = simpleApproximateCount(text), .approximate = true };
        }
    }
};

fn simpleApproximateCount(text: []const u8) usize {
    var in_word = false;
    var count: usize = 0;
    for (text) |c| {
        const is_ws = std.ascii.isWhitespace(c);
        if (!is_ws and !in_word) {
            count += 1;
            in_word = true;
        } else if (is_ws) {
            in_word = false;
        }
    }
    if (count == 0 and text.len > 0) return 1;
    return count;
}

pub fn resolveTokenizerKind(model: []const u8) ?Kind {
    if (std.mem.startsWith(u8, model, "gpt-4o")) return .o200k_base;
    if (std.mem.startsWith(u8, model, "gpt-4.1")) return .o200k_base;
    if (std.mem.startsWith(u8, model, "gpt-4")) return .cl100k_base;
    if (std.mem.startsWith(u8, model, "gpt-3.5")) return .cl100k_base;
    return null;
}
