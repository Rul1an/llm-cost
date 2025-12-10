const std = @import("std");
const root = @import("root");
const Pricing = root.pricing;
const Engine = root.engine;
const OpenAITokenizer = root.tokenizer.openai.OpenAITokenizer;

pub const InputMode = enum { Auto, Raw, JsonField };
pub const OutputFormat = enum { NdJson };

pub const PipeConfig = struct {
    input_mode: InputMode,
    json_field: []const u8 = "content",
    output_format: OutputFormat,
    max_tokens: ?u64 = null,
    max_cost: ?f64 = null,
    fail_on_error: bool = false,
    summary: bool = false,
    model_name: []const u8, // Needed for pricing
};

pub const PipeStats = struct {
    lines: u64 = 0,
    tokens_total: u64 = 0,
    cost_total: f64 = 0.0,
};

/// Interface wrapper for the tokenizer engine
pub const TokenizerWrapper = struct {
    impl: OpenAITokenizer,
    allocator: std.mem.Allocator,
    pricing_db: *const Pricing.PricingDB,

    pub fn count(self: TokenizerWrapper, text: []const u8) !usize {
        const res = try self.impl.count(self.allocator, text);
        return res.tokens;
    }

    pub fn estimateCost(self: TokenizerWrapper, tokens: usize, model_name: []const u8) !Engine.CostResult {
        // Output tokens for pipe mode is usually 0 (just counting input)
        // unless we want to predict output cost? For now assume measurement of input.
        return Engine.estimateCost(self.pricing_db, model_name, tokens, 0, 0);
    }
};

pub const StreamProcessor = struct {
    allocator: std.mem.Allocator,
    tokenizer: TokenizerWrapper,
    config: PipeConfig,
    stats: PipeStats,

    pub fn init(allocator: std.mem.Allocator, tokenizer: TokenizerWrapper, config: PipeConfig) StreamProcessor {
        return .{
            .allocator = allocator,
            .tokenizer = tokenizer,
            .config = config,
            .stats = .{},
        };
    }

    /// Hoofdloop: Leest van reader, verwerkt, schrijft naar writer.
    /// Gebruikt een ArenaAllocator per regel om memory leaks te garanderen.
    pub fn process(self: *StreamProcessor, reader: anytype, writer: anytype) !void {
        // 1. Setup Arena (herbruikt pages tussen iteraties)
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        // 2. Buffered I/O voor performance (64KB buffers)
        var buf_reader = std.io.bufferedReaderSize(65536, reader);
        var buf_writer = std.io.bufferedWriter(writer);
        const r = buf_reader.reader();
        const w = buf_writer.writer();

        // 3. Hot Loop
        while (true) {
            // A. Reset Arena - Alles van vorige iteratie wordt hier "vrijgegeven"
            // .retain_capacity zorgt dat we niet steeds syscalls doen voor geheugen
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();

            // B. Lees regel (max 10MB per regel als safety limit)
            const line = r.readUntilDelimiterOrEofAlloc(arena, '\n', 10 * 1024 * 1024) catch |err| {
                if (err == error.StreamTooLong) {
                    try self.writeError(w, "Line too long (max 10MB)");
                    continue;
                }
                return err;
            };

            if (line == null) break; // EOF

            // C. Verwerk regel (Enrichment logic)
            // We negeren errors per regel tenzij fail_on_error aan staat,
            // om de stream niet te breken bij 1 corrupte JSON.
            const stats = self.processLine(arena, line.?, w) catch |err| {
                if (self.config.fail_on_error) return err;
                try self.writeError(w, "Processing error");
                continue;
            };

            // D. Update Global Stats
            self.stats.lines += 1;
            self.stats.tokens_total += stats.tokens;
            self.stats.cost_total += stats.cost;

            // E. Circuit Breakers (Guardrails)
            if (self.checkQuota()) {
                // Flush wat we hebben en stop
                try buf_writer.flush();
                return error.QuotaExceeded;
            }
        }

        try buf_writer.flush();
        if (self.config.summary) {
            self.printSummary();
        }
    }

    const LineStats = struct { tokens: u64, cost: f64 };

    fn processLine(self: *StreamProcessor, arena: std.mem.Allocator, line: []const u8, writer: anytype) !LineStats {
        // Stap 1: Bepaal content en parsing strategy
        var root_json: ?std.json.Value = null;
        var text_to_count: []const u8 = line;

        // Probeer JSON te parsen als mode Auto of JsonField is
        if (self.config.input_mode != .Raw) {
            // std.json.parseFromSlice in Zig 0.14 returnt !Parsed(T)
            // Note: In 0.14.0 std.json.parseFromSlice returns Parsed(T)
            if (std.json.parseFromSlice(std.json.Value, arena, line, .{})) |parsed| {
                if (parsed.value == .object) {
                    root_json = parsed.value;
                    if (root_json.?.object.get(self.config.json_field)) |val| {
                        if (val == .string) {
                            text_to_count = val.string;
                        }
                    }
                }
            } else |_| {
                // Parse error: als mode strict JsonField is, is dit een error.
                // Bij Auto vallen we terug naar Raw.
                if (self.config.input_mode == .JsonField) {
                    return error.InvalidJson;
                }
            }
        }

        // Stap 2: Core Tokenization Logic
        const tokens = try self.tokenizer.count(text_to_count);

        // Calculate cost using the wrapper
        const cost_res = try self.tokenizer.estimateCost(tokens, self.config.model_name);
        const total_cost = cost_res.cost_total;

        // Stap 3: Construct Output (Enrichment)
        if (root_json != null) {
            // Enrich bestaand object
            var usage_map = std.json.ObjectMap.init(arena);
            try usage_map.put("input_tokens", std.json.Value{ .integer = @intCast(tokens) });
            try usage_map.put("cost_usd", std.json.Value{ .float = total_cost });

            // Voeg "usage" veld toe aan originele object
            try root_json.?.object.put("usage", std.json.Value{ .object = usage_map });

            try std.json.stringify(root_json.?, .{}, writer);
        } else {
            // Wrap raw string in nieuw object
            // { "content": "...", "usage": { ... } }
            // Using an anonymous struct for stringify
            const OutUsage = struct {
                input_tokens: u64,
                cost_usd: f64,
            };
            const OutputStruct = struct {
                content: []const u8,
                usage: OutUsage,
            };

            const out = OutputStruct{
                .content = text_to_count,
                .usage = .{
                    .input_tokens = tokens,
                    .cost_usd = total_cost,
                },
            };
            try std.json.stringify(out, .{}, writer);
        }

        try writer.writeByte('\n');

        return LineStats{ .tokens = tokens, .cost = total_cost };
    }

    fn writeError(self: *StreamProcessor, writer: anytype, msg: []const u8) !void {
        _ = self;
        try writer.writeAll("{\"error\": \"");
        try writer.writeAll(msg);
        try writer.writeAll("\"}\n");
    }

    fn checkQuota(self: *StreamProcessor) bool {
        if (self.config.max_tokens) |limit| {
            if (self.stats.tokens_total >= limit) return true;
        }
        if (self.config.max_cost) |limit| {
            if (self.stats.cost_total >= limit) return true;
        }
        return false;
    }

    fn printSummary(self: *StreamProcessor) void {
        const stderr = std.io.getStdErr().writer();
        // Atomic write naar stderr om interleaving te voorkomen
        stderr.print(
            \\
            \\--- Summary ---
            \\Lines: {d}
            \\Tokens: {d}
            \\Cost: ${d:.6}
            \\
            , .{ self.stats.lines, self.stats.tokens_total, self.stats.cost_total }
        ) catch {};
    }
};
