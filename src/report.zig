const std = @import("std");
const pipe = @import("pipe.zig");
const tokenizer_mod = @import("tokenizer/mod.zig");
const OpenAITokenizer = tokenizer_mod.OpenAITokenizer;

pub const ReportConfig = struct {
    input_mode: pipe.InputMode = .Auto,
    json_field: []const u8 = "content",
    model_name: []const u8 = "gpt-4o",
    top_k: usize = 10,
};

pub const ReportStats = struct {
    bytes_in: u64 = 0,
    tokens_out: u64 = 0,
    vocab_size: u32 = 0,
};

pub const ReportProcessor = struct {
    allocator: std.mem.Allocator,
    tokenizer: OpenAITokenizer,
    config: ReportConfig,

    // Arrays for aggregation (heap allocated)
    freq: []u64,
    seen: []bool,
    vocab_size: u32,

    stats: ReportStats,

    pub fn init(allocator: std.mem.Allocator, tokenizer: OpenAITokenizer, config: ReportConfig) !ReportProcessor {
        var vocab_size: u32 = 200_000; // Safe default
        if (tokenizer.loader) |l| {
            vocab_size = l.token_count;
        } else {
            // Fallback based on model name if loader is missing (approx mode)
            if (std.mem.startsWith(u8, config.model_name, "gpt-4")) {
                vocab_size = 100_300; // cl100k approx
            }
            if (std.mem.startsWith(u8, config.model_name, "gpt-4o")) {
                vocab_size = 200_020; // o200k approx
            }
        }

        const freq = try allocator.alloc(u64, vocab_size);
        @memset(freq, 0);

        const seen = try allocator.alloc(bool, vocab_size);
        @memset(seen, false);

        return ReportProcessor{
            .allocator = allocator,
            .tokenizer = tokenizer,
            .config = config,
            .freq = freq,
            .seen = seen,
            .vocab_size = vocab_size,
            .stats = .{ .vocab_size = vocab_size },
        };
    }

    pub fn deinit(self: *ReportProcessor) void {
        self.allocator.free(self.freq);
        self.allocator.free(self.seen);
    }

    pub fn processStream(self: *ReportProcessor, reader: anytype) !void {
        var buf_reader = std.io.bufferedReaderSize(65536, reader);
        const r = buf_reader.reader();

        // Arena for per-line allocations
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        while (true) {
            // Reset Arena (O(1))
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();

            // Read line
            const line = r.readUntilDelimiterOrEofAlloc(arena, '\n', 10 * 1024 * 1024) catch |err| {
                if (err == error.StreamTooLong) continue; // Skip massive lines? Or error? Report implies analytics, maybe skipping bad lines is safer.
                return err;
            };

            if (line == null) break;

            // Extract content
            var text_to_count: []const u8 = line.?;

            if (self.config.input_mode != .Raw) {
                // Try Parse JSON
                if (std.json.parseFromSlice(std.json.Value, arena, line.?, .{})) |parsed| {
                    if (parsed.value == .object) {
                        if (parsed.value.object.get(self.config.json_field)) |val| {
                            if (val == .string) {
                                text_to_count = val.string;
                            }
                        }
                    }
                } else |_| {
                    if (self.config.input_mode == .JsonField) {
                        // Strict mode: skip or error? Let's skip invalid lines in report mode
                        // to avoid failing a huge job on one bad line.
                        continue;
                    }
                }
            }

            // Encode (we need actual tokens to update stats)
            // tokenizer.encode returns []u32 allocated in passed allocator
            const tokens = try self.tokenizer.encode(arena, text_to_count);

            // Aggregation
            self.stats.bytes_in += text_to_count.len; // Measure content bytes, not raw line bytes? User spec: "bytes_total += text.len".
            self.stats.tokens_out += tokens.len;

            for (tokens) |id| {
                if (id < self.vocab_size) {
                    self.freq[id] += 1;
                    self.seen[id] = true;
                }
            }
        }
    }

    pub fn printReport(self: *ReportProcessor, writer: anytype) !void {
        // 1. Calculate Metrics
        const compression_ratio = if (self.stats.tokens_out > 0)
            @as(f64, @floatFromInt(self.stats.bytes_in)) / @as(f64, @floatFromInt(self.stats.tokens_out))
        else
            0.0;

        var unique_tokens: u32 = 0;
        for (self.seen) |s| {
            if (s) unique_tokens += 1;
        }

        const vocab_utilization = if (self.vocab_size > 0)
            @as(f64, @floatFromInt(unique_tokens)) / @as(f64, @floatFromInt(self.vocab_size))
        else
            0.0;

        // 2. Identify Rare Tokens
        // "Rare = highest rank". Sort SEEN tokens by Rank Descending.
        // Wait, rank == id usually for BPE?
        // In tiktoken, tokens are roughly ordered by merge priority?
        // Actually, usually lower ID = earlier merge/character?
        // User spec says: "lookup 'rank' ... sorteren op rank desc".
        // In our VocabLoader, we have `rank_map` which maps bytes -> rank.
        // `byte_to_token` maps byte -> rank.
        // And `token_slices` is indexed by rank.
        // So ID IS Rank in our system.
        // "Higher rank = later merge = more specific/rare".
        // So we just sort by ID descending.

        var seen_ids = std.ArrayList(u32).init(self.allocator);
        defer seen_ids.deinit();

        for (self.seen, 0..) |s, id| {
            if (s) try seen_ids.append(@intCast(id));
        }

        // Sort Descending (Highest ID first)
        std.mem.sort(u32, seen_ids.items, {}, std.sort.desc(u32));

        // 3. Construct JSON
        var root = std.json.ObjectMap.init(self.allocator);
        defer root.deinit();

        try root.put("model", std.json.Value{ .string = self.config.model_name });
        try root.put("encoding", std.json.Value{ .string = self.tokenizer.spec.name });
        try root.put("bytes_in", std.json.Value{ .integer = @intCast(self.stats.bytes_in) });
        try root.put("tokens_out", std.json.Value{ .integer = @intCast(self.stats.tokens_out) });
        try root.put("compression_ratio", std.json.Value{ .float = compression_ratio });
        try root.put("vocab_size", std.json.Value{ .integer = self.vocab_size });
        try root.put("unique_tokens", std.json.Value{ .integer = unique_tokens });
        try root.put("vocab_utilization", std.json.Value{ .float = vocab_utilization });

        // Rare Tokens Array
        var rare_list = std.ArrayList(std.json.Value).init(self.allocator);
        defer rare_list.deinit();

        const limit = @min(self.config.top_k, seen_ids.items.len);
        for (seen_ids.items[0..limit]) |id| {
            var entry = std.json.ObjectMap.init(self.allocator);
            // We transfer ownership of map to list later, or rely on stringify to handle it?
            // Zig std.json.Value deep copies or references?
            // Value.object is a HashMap.

            try entry.put("id", std.json.Value{ .integer = id });
            try entry.put("rank", std.json.Value{ .integer = id }); // ID is Rank
            try entry.put("count", std.json.Value{ .integer = @intCast(self.freq[id]) });

            // Repr: Get bytes from tokenizer
            if (self.tokenizer.loader) |l| {
                if (l.getBytes(id)) |bytes| {
                    // Safety: escape bytes to valid UTF-8 string or hex
                    // For JSON, we can just print it? std.json.stringify handles escaping?
                    // But if it's invalid UTF-8 (binary token), json stringify might fail or produce garbage.
                    // Let's assume valid UTF-8 for now or use std.fmt.fmtSliceEscapeLower
                    // Actually, let's use a heuristic: if valid utf8, use string. Else hex.
                    if (std.unicode.utf8ValidateSlice(bytes)) {
                        try entry.put("repr", std.json.Value{ .string = bytes });
                    } else {
                        // Hex repr for binary
                        // We need to allocate a string for this
                        const hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(bytes)});
                        try entry.put("repr", std.json.Value{ .string = hex });
                    }
                }
            } else {
                try entry.put("repr", std.json.Value{ .string = "?" });
            }

            try rare_list.append(std.json.Value{ .object = entry });
        }

        try root.put("rare_tokens", std.json.Value{ .array = rare_list });

        try std.json.stringify(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }, writer);
        try writer.writeByte('\n');
    }
};
