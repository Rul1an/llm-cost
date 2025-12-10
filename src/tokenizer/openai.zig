const std = @import("std");
const registry = @import("registry.zig");
const pre_tokenizer = @import("pre_tokenizer.zig");
const engine_mod = @import("../core/engine.zig"); // For BpeVersion enum
const vocab_loader = @import("vocab_loader.zig");
const bpe_algo = @import("bpe_v2_1.zig");

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
    loader: ?vocab_loader.VocabLoader = null,
    bpe_version: engine_mod.BpeVersion,

    pub fn init(alloc: std.mem.Allocator, cfg: Config) !OpenAITokenizer {
        // Initialize VocabLoader if data is available
        var loader: ?vocab_loader.VocabLoader = null;

        if (cfg.spec.vocab_data.len > 0) {
            loader = vocab_loader.VocabLoader.load(alloc, cfg.spec.vocab_data) catch |err| {
                if (cfg.approximate_ok) return OpenAITokenizer{ .spec = cfg.spec, .loader = null, .bpe_version = cfg.bpe_version };
                return err;
            };
        } else {
            // No data available
            if (cfg.approximate_ok) {
                loader = null;
            } else {
                return error.UnsupportedModel;
            }
        }

        return OpenAITokenizer{
            .spec = cfg.spec,
            .loader = loader,
            .bpe_version = cfg.bpe_version,
        };
    }

    pub fn deinit(self: *OpenAITokenizer, alloc: std.mem.Allocator) void {
        if (self.loader) |*l| {
            l.deinit(alloc);
        }
    }

    pub fn count(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) !Result {
        if (self.loader) |*l| {
            // 1. Determine PreTokenizer
            var pt_interface: pre_tokenizer.PreTokenizer = undefined;
            if (std.mem.eql(u8, self.spec.name, "o200k_base")) {
                pt_interface = @import("o200k_scanner.zig").O200kScanner.interface();
            } else if (std.mem.eql(u8, self.spec.name, "cl100k_base")) {
                pt_interface = @import("cl100k_scanner.zig").Cl100kScanner.interface();
            } else {
                pt_interface = pre_tokenizer.LegacyPreTokenizer.interface();
            }

            // 2. Pre-tokenize
            const pre_tokens = try pt_interface.tokenize(alloc, text);
            defer alloc.free(pre_tokens);

            // 3. Process chunks
            var total_tokens: usize = 0;
            const merge_table = vocab_loader.VocabMergeTable{ .vocab = l };

            // Arena for per-chunk BPE allows fast cleanup
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            for (pre_tokens) |chunk| {
                // a. Convert bytes to initial tokens
                var initial = try arena_alloc.alloc(u32, chunk.text.len);
                for (chunk.text, 0..) |byte, i| {
                    initial[i] = l.getByteToken(byte);
                }

                // b. Run BPE
                const bpe_tokens = try bpe_algo.encodeLinear(arena_alloc, initial, &merge_table);
                total_tokens += bpe_tokens.len;

                // Reset arena periodically? For CLI count on reasonable text, just defer deinit is fine.
                // But for huge files, we might want to reset.
                // Given pre_tokenizer returns all chunks at once, memory is usage is O(N).
                // Phase 2 optimization: streaming pre-tokenizer.
                // For now, this is correct.
            }

            return Result{ .tokens = total_tokens, .approximate = false };
        } else {
            // Fallback
            return Result{ .tokens = simpleApproximateCount(text), .approximate = true };
        }
    }

    /// Encode text to IDs (for testing/verification).
    pub fn encode(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) ![]u32 {
        if (self.loader) |*l| {
            // Similar logic to count but collects tokens
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

            var result = std.ArrayList(u32).init(alloc);
            errdefer result.deinit();

            const merge_table = vocab_loader.VocabMergeTable{ .vocab = l };

            // Use separate arena for temp BPE structs
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            for (pre_tokens) |chunk| {
                var initial = try arena_alloc.alloc(u32, chunk.text.len);
                for (chunk.text, 0..) |byte, i| {
                    initial[i] = l.getByteToken(byte);
                }

                const bpe_tokens = try bpe_algo.encodeLinear(arena_alloc, initial, &merge_table);
                try result.appendSlice(bpe_tokens);
            }

            return result.toOwnedSlice();
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
