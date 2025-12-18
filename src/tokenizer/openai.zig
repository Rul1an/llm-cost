const std = @import("std");
const registry = @import("registry.zig");
const pre_tokenizer = @import("pre_tokenizer.zig");
// const engine_mod = @import("../core/engine.zig"); // Removed cycle
const BpeVersion = pre_tokenizer.BpeVersion;
const vocab_loader = @import("vocab_loader.zig");
const bpe_algo = @import("bpe_v2_1.zig");

pub const Result = struct {
    tokens: usize,
    approximate: bool,
};

pub const Config = struct {
    spec: registry.EncodingSpec,
    approximate_ok: bool = false,
    bpe_version: BpeVersion = .v2,
};

/// The OpenAI Tokenizer instance.
/// Wraps the low-level BPE engine (if available).
pub const OpenAITokenizer = struct {
    spec: registry.EncodingSpec,
    loader: ?vocab_loader.VocabLoader = null,
    bpe_version: BpeVersion,

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

    const EncodingContext = struct {
        alloc: std.mem.Allocator,
        loader: *const vocab_loader.VocabLoader,
        merge_table: *const vocab_loader.VocabMergeTable,
        bpe_ws: *bpe_algo.BpeWorkspace,
        arena: *std.heap.ArenaAllocator,
        total_tokens: usize = 0,
        output: ?*std.ArrayList(u32) = null,

        // Reusable encoding interface
        pub fn init(alloc: std.mem.Allocator, l: *const vocab_loader.VocabLoader, mt: *const vocab_loader.VocabMergeTable, ws: *bpe_algo.BpeWorkspace, ar: *std.heap.ArenaAllocator) EncodingContext {
            return .{
                .alloc = alloc,
                .loader = l,
                .merge_table = mt,
                .bpe_ws = ws,
                .arena = ar,
            };
        }

        pub fn handle(ptr: *anyopaque, token: pre_tokenizer.PreToken) !void {
            const self: *EncodingContext = @ptrCast(@alignCast(ptr));
            const l = self.loader;

            // Reset arena to free temp allocations from previous chunk
            _ = self.arena.reset(.retain_capacity);
            const arena_alloc = self.arena.allocator();

            // a. Convert bytes to initial tokens
            // This allocation is now very cheap (arena reset)
            const initial = try arena_alloc.alloc(u32, token.text.len);
            for (token.text, 0..) |byte, i| {
                initial[i] = l.getByteToken(byte);
            }

            // b. Run BPE
            // bpe_ws.encode reuse internal buffers. Returns slice valid until next call.
            const bpe_tokens = try self.bpe_ws.encode(initial, self.merge_table);

            self.total_tokens += bpe_tokens.len;
            if (self.output) |out| {
                try out.appendSlice(bpe_tokens);
            }
        }
    };

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

            // 2. Setup Context
            const merge_table = vocab_loader.VocabMergeTable{ .vocab = l };
            var bpe_ws = bpe_algo.BpeWorkspace.init(alloc);
            defer bpe_ws.deinit();
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();

            var ctx = EncodingContext{
                .alloc = alloc,
                .loader = l,
                .merge_table = &merge_table,
                .bpe_ws = &bpe_ws,
                .arena = &arena,
                .output = null,
            };

            // 3. Stream tokens
            try pt_interface.tokenize(text, &ctx, EncodingContext.handle);

            return Result{ .tokens = ctx.total_tokens, .approximate = false };
        } else {
            // Fallback
            return Result{ .tokens = simpleApproximateCount(text), .approximate = true };
        }
    }

    /// Encode text to IDs (for testing/verification).
    pub fn encode(self: OpenAITokenizer, alloc: std.mem.Allocator, text: []const u8) ![]u32 {
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

            // 2. Setup Context
            var result = std.ArrayList(u32).init(alloc);
            errdefer result.deinit();

            const merge_table = vocab_loader.VocabMergeTable{ .vocab = l };
            var bpe_ws = bpe_algo.BpeWorkspace.init(alloc);
            defer bpe_ws.deinit();
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();

            var ctx = EncodingContext{
                .alloc = alloc,
                .loader = l,
                .merge_table = &merge_table,
                .bpe_ws = &bpe_ws,
                .arena = &arena,
                .output = &result,
            };

            // 3. Stream tokens
            try pt_interface.tokenize(text, &ctx, EncodingContext.handle);

            return result.toOwnedSlice();
        } else {
            return error.NoEngine;
        }
    }

    /// Optimized encodeInto for fuzzing/benchmarking (avoids allocs)
    pub fn encodeInto(self: OpenAITokenizer, alloc: std.mem.Allocator, arena: *std.heap.ArenaAllocator, ws: *bpe_algo.BpeWorkspace, text: []const u8, out: *std.ArrayList(u32)) !void {
        if (self.loader) |*l| {
            var pt_interface: pre_tokenizer.PreTokenizer = undefined;
            if (std.mem.eql(u8, self.spec.name, "o200k_base")) {
                pt_interface = @import("o200k_scanner.zig").O200kScanner.interface();
            } else if (std.mem.eql(u8, self.spec.name, "cl100k_base")) {
                pt_interface = @import("cl100k_scanner.zig").Cl100kScanner.interface();
            } else {
                pt_interface = pre_tokenizer.LegacyPreTokenizer.interface();
            }

            const merge_table = vocab_loader.VocabMergeTable{ .vocab = l };
            var ctx = EncodingContext.init(alloc, l, &merge_table, ws, arena);
            ctx.output = out;

            try pt_interface.tokenize(text, &ctx, EncodingContext.handle);
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
