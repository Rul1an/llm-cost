const std = @import("std");
const bpe = @import("bpe.zig");
const registry = @import("registry.zig");
const pre_tokenizer = @import("pre_tokenizer.zig");

pub const Result = struct {
    tokens: usize,
    approximate: bool,
};

pub const Config = struct {
    spec: registry.EncodingSpec,
    approximate_ok: bool = false,
};

/// The OpenAI Tokenizer instance.
/// Wraps the low-level BPE engine (if available).
pub const OpenAITokenizer = struct {
    spec: registry.EncodingSpec,
    engine: ?bpe.BpeEngine = null,

    pub fn init(cfg: Config) !OpenAITokenizer {
        // Initialize BPE engine based on spec data
        var eng: ?bpe.BpeEngine = null;

        if (cfg.spec.vocab_data.len > 0) {
            eng = bpe.BpeEngine.init(cfg.spec.vocab_data) catch |err| {
                if (cfg.approximate_ok) return OpenAITokenizer{ .spec = cfg.spec, .engine = null };
                return err;
            };
        } else {
            // No data available (e.g. cl100k in v0.1)
            if (cfg.approximate_ok) {
                eng = null;
            } else {
                return error.UnsupportedModel;
            }
        }

        return OpenAITokenizer{
            .spec = cfg.spec,
            .engine = eng,
        };
    }

    pub fn count(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) !Result {
        if (self.engine) |eng| {
            // v0.2: Always use PreTokenizer first.
            // For now, hardcode LegacyPreTokenizer until we map Spec -> PreTokenizer
            var legacy = pre_tokenizer.LegacyPreTokenizer.interface(); // wait, implementation is struct. Interface is returned method.
            // tokenize method is static or method?
            // In definition: `pub fn tokenize(_: *anyopaque...`
            // Better to use the struct directly if possible or interface?
            // `legacy.tokenize(...)` implies `LegacyPreTokenizer` instance needed?
            // It has no state.
            // Let's use the struct function directly first for simplicity, or fix call.
            // The method `tokenize` is `pub fn tokenize(_: *anyopaque...`
            // So we need an instance or null ptr.
            // Let's use `LegacyPreTokenizer.interface().tokenize(...)`.
            // Wait, interface() returns `PreTokenizer`.
            const pt_interface = pre_tokenizer.LegacyPreTokenizer.interface();
            const pre_tokens = try pt_interface.tokenize(alloc, text);
            defer alloc.free(pre_tokens);

            const tokens = try eng.encode(alloc, pre_tokens);
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

/// map model name to EncodingSpec
pub fn resolveEncoding(model: []const u8) ?registry.EncodingSpec {
    if (std.mem.startsWith(u8, model, "gpt-4o")) return registry.Registry.o200k_base;
    if (std.mem.startsWith(u8, model, "gpt-4.1")) return registry.Registry.o200k_base;
    if (std.mem.startsWith(u8, model, "gpt-4")) return registry.Registry.cl100k_base;
    if (std.mem.startsWith(u8, model, "gpt-3.5")) return registry.Registry.cl100k_base;
    return null;
}
