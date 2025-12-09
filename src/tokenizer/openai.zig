const std = @import("std");
const bpe = @import("bpe_v2.zig");
const registry = @import("registry.zig");
const pre_tokenizer = @import("pre_tokenizer.zig");
const engine_mod = @import("../core/engine.zig"); // For BpeVersion enum

pub const Result = struct {
    tokens: usize,
    approximate: bool,
};

pub const Config = struct {
    spec: registry.EncodingSpec,
    approximate_ok: bool = false,
    bpe_version: engine_mod.BpeVersion = .v2,
};

/// The OpenAI Tokenizer instance.
/// Wraps the low-level BPE engine (if available).
pub const OpenAITokenizer = struct {
    spec: registry.EncodingSpec,
    engine: ?bpe.BpeEngineV2 = null,
    bpe_version: engine_mod.BpeVersion,

    pub fn init(alloc: std.mem.Allocator, cfg: Config) !OpenAITokenizer {
        // Initialize BPE engine based on spec data
        var eng: ?bpe.BpeEngineV2 = null;

        if (cfg.spec.vocab_data.len > 0) {
            eng = bpe.BpeEngineV2.init(alloc, cfg.spec.vocab_data) catch |err| {
                if (cfg.approximate_ok) return OpenAITokenizer{ .spec = cfg.spec, .engine = null, .bpe_version = cfg.bpe_version };
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
            .bpe_version = cfg.bpe_version,
        };
    }

    pub fn deinit(self: *OpenAITokenizer) void {
        if (self.engine) |*e| {
            e.deinit();
        }
    }

    pub fn count(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) !Result {
        if (self.engine) |*eng| {
            // Determine PreTokenizer
            var pt_interface: pre_tokenizer.PreTokenizer = undefined;
            if (std.mem.eql(u8, self.spec.name, "o200k_base")) {
                pt_interface = @import("o200k_scanner.zig").O200kScanner.interface();
            } else if (std.mem.eql(u8, self.spec.name, "cl100k_base")) {
                pt_interface = @import("cl100k_scanner.zig").Cl100kScanner.interface();
            } else {
                pt_interface = pre_tokenizer.LegacyPreTokenizer.interface();
            }

            const pre_tokens = try pt_interface.tokenize(alloc, text);
            defer alloc.free(pre_tokens);

            const tokens = try eng.encode(alloc, pre_tokens, self.bpe_version == .v2_1);
            defer alloc.free(tokens);
            return Result{ .tokens = tokens.len, .approximate = false };
        } else {
            // Fallback
            return Result{ .tokens = simpleApproximateCount(text), .approximate = true };
        }
    }

    /// Encode text to IDs (for testing/verification).
    pub fn encode(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) ![]u32 {
        if (self.engine) |*eng| {
            var pt_interface: pre_tokenizer.PreTokenizer = undefined;
            if (std.mem.eql(u8, self.spec.name, "o200k_base")) {
                pt_interface = @import("o200k_scanner.zig").O200kScanner.interface();
            } else if (std.mem.eql(u8, self.spec.name, "cl100k_base")) {
                pt_interface = @import("cl100k_scanner.zig").Cl100kScanner.interface();
            } else {
                pt_interface = pre_tokenizer.LegacyPreTokenizer.interface();
            }

            const pre_tokens = try pt_interface.tokenize(alloc, text);
            defer alloc.free(pre_tokens);

            return eng.encode(alloc, pre_tokens, self.bpe_version == .v2_1);
        } else {
            return error.NoEngine;
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
