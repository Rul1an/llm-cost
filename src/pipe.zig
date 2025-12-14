const std = @import("std");
const root = @import("root");
const Pricing = @import("core/pricing/mod.zig");
const tokenizer_mod = @import("tokenizer/mod.zig");
const engine = @import("core/engine.zig");

// --- Config & Stats ---
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
    model_name: []const u8,
};

pub const PipeStats = struct {
    lines: u64 = 0,
    tokens_total: u64 = 0,
    cost_total: i128 = 0,
};

/// Efficient struct for partial parsing of logs (LLM Usage)
const LogEntry = struct {
    usage: ?struct {
        prompt_tokens: u64 = 0,
        completion_tokens: u64 = 0,
        total_tokens: u64 = 0,
        completion_tokens_details: ?struct {
            reasoning_tokens: u64 = 0,
        } = null,
    } = null,
    // Support flattened format
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
};

/// Interface wrapper for the tokenizer
pub const TokenizerWrapper = struct {
    impl: tokenizer_mod.openai.OpenAITokenizer,
    allocator: std.mem.Allocator,

    pub fn count(self: TokenizerWrapper, text: []const u8) !usize {
        const res = try self.impl.count(self.allocator, text);
        return res.tokens;
    }
};

pub const StreamProcessor = struct {
    allocator: std.mem.Allocator,
    tokenizer: TokenizerWrapper,
    price_def: Pricing.PriceDef,
    config: PipeConfig,
    stats: PipeStats,

    pub fn init(allocator: std.mem.Allocator, tokenizer: TokenizerWrapper, price_def: Pricing.PriceDef, config: PipeConfig) StreamProcessor {
        return .{
            .allocator = allocator,
            .tokenizer = tokenizer,
            .price_def = price_def,
            .config = config,
            .stats = .{},
        };
    }

    pub fn process(self: *StreamProcessor, reader: anytype, writer: anytype) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        var buf_reader = std.io.bufferedReaderSize(65536, reader);
        var buf_writer = std.io.bufferedWriter(writer);
        const r = buf_reader.reader();
        const w = buf_writer.writer();

        while (true) {
            // Reset Arena (Prevent fragmentation)
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();

            // Read line
            const line = r.readUntilDelimiterOrEofAlloc(arena, '\n', 10 * 1024 * 1024) catch |err| {
                if (err == error.StreamTooLong) {
                    try self.writeError(w, "Line too long (max 10MB)");
                    continue;
                }
                return err;
            };

            if (line == null) break;

            const stats = self.processLine(arena, line.?, w) catch |err| {
                if (self.config.fail_on_error) return err;
                try self.writeError(w, "Processing error");
                continue;
            };

            self.stats.lines += 1;
            self.stats.tokens_total += stats.tokens;
            self.stats.cost_total = std.math.add(i128, self.stats.cost_total, stats.cost) catch return error.Overflow;

            if (self.checkQuota()) {
                try buf_writer.flush();
                return error.QuotaExceeded;
            }
        }

        try buf_writer.flush();
        if (self.config.summary) {
            self.printSummary();
        }
    }

    const LineStats = struct { tokens: u64, cost: i128 };

    fn processLine(self: *StreamProcessor, arena: std.mem.Allocator, line: []const u8, writer: anytype) !LineStats {
        var tokens_in: u64 = 0;
        var tokens_out: u64 = 0;
        var tokens_reas: u64 = 0;
        var is_log_entry = false;
        var original_json: ?std.json.Value = null;

        // Try Parse as LogEntry (Weak Schema)
        if (std.json.parseFromSlice(LogEntry, arena, line, .{ .ignore_unknown_fields = true })) |parsed| {
            const log = parsed.value;
            // Check for usage match
            if (log.usage) |u| {
                is_log_entry = true;
                tokens_in = u.prompt_tokens;
                tokens_out = u.completion_tokens;
                if (u.completion_tokens_details) |d| {
                    tokens_reas = d.reasoning_tokens;
                }
            } else if (log.input_tokens != null or log.output_tokens != null) {
                is_log_entry = true;
                tokens_in = log.input_tokens orelse 0;
                tokens_out = log.output_tokens orelse 0;
            }
        } else |_| {}

        // If not log, maybe User JSON with "content" field? or Raw?
        if (!is_log_entry) {
            var text_to_count: []const u8 = line;
            if (self.config.input_mode != .Raw) {
                // Try Parse generic JSON to find "content" field
                if (std.json.parseFromSlice(std.json.Value, arena, line, .{})) |parsed| {
                    if (parsed.value == .object) {
                        original_json = parsed.value; // Keep for enrichment
                        if (parsed.value.object.get(self.config.json_field)) |val| {
                            if (val == .string) {
                                text_to_count = val.string;
                            }
                        }
                    }
                } else |_| {
                    if (self.config.input_mode == .JsonField) return error.InvalidJson;
                }
            }

            // Count input tokens
            const count = try self.tokenizer.count(text_to_count);
            tokens_in = @intCast(count);
        }

        // Calculate Cost using Registry logic
        const cost = Pricing.Registry.calculate(self.price_def, tokens_in, tokens_out, tokens_reas);

        // Format cost string (Canonical)
        // Format cost string (Canonical)
        const sign = if (cost < 0) "-" else "";
        const abs_val = @abs(cost);
        const whole = abs_val / 1_000_000;
        const frac = abs_val % 1_000_000;

        // Output
        if (is_log_entry) {
            // Echo usage + cost in NDJSON
            try writer.print("{{\"input\":{d},\"output\":{d},\"reasoning\":{d},\"cost\":\"{s}{d}.{d:0>6}\"}}\n", .{ tokens_in, tokens_out, tokens_reas, sign, whole, @as(u64, @intCast(frac)) });
        } else {
            if (original_json != null) {
                // Enrich original JSON
                var usage_map = std.json.ObjectMap.init(arena);
                try usage_map.put("input_tokens", std.json.Value{ .integer = @intCast(tokens_in) });

                // Use string for canonical cost in JSON
                const cost_str = try std.fmt.allocPrint(arena, "{s}{d}.{d:0>6}", .{ sign, whole, @as(u64, @intCast(frac)) });
                try usage_map.put("cost_usd", std.json.Value{ .string = cost_str });

                try original_json.?.object.put("usage", std.json.Value{ .object = usage_map });
                try std.json.stringify(original_json.?, .{}, writer);
                try writer.writeByte('\n');
            } else {
                // Raw text -> JSON Output
                try writer.print("{{\"tokens\":{d},\"cost\":\"{s}{d}.{d:0>6}\"}}\n", .{ tokens_in, sign, whole, @as(u64, @intCast(frac)) });
            }
        }

        return LineStats{ .tokens = tokens_in + tokens_out, .cost = cost };
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
        if (self.config.max_cost) |limit_usd| {
            // Convert limit (f64) to MicroUsd (i128)
            const limit_micro = @as(i128, @intFromFloat(@round(limit_usd * 1_000_000.0)));
            if (self.stats.cost_total >= limit_micro) return true;
        }
        return false;
    }

    fn printSummary(self: *StreamProcessor) void {
        const stderr = std.io.getStdErr().writer();
        // Convert accrued MicroUsd to f64 for summary (human readable)
        const cost_f = @as(f64, @floatFromInt(self.stats.cost_total)) / 1_000_000.0;

        stderr.print(
            \\
            \\--- Summary ---
            \\Lines: {d}
            \\Tokens: {d}
            \\Cost: ${d:.6}
            \\
            \\
        , .{ self.stats.lines, self.stats.tokens_total, cost_f }) catch {};
    }
};

/// Public entry point for CLI
pub fn run(allocator: std.mem.Allocator, args: []const []const u8, registry: *Pricing.Registry, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    var model: ?[]const u8 = null;
    var json_field: []const u8 = "content";
    var input_mode: InputMode = .Auto;
    var max_tokens: ?u64 = null;
    var max_cost: ?f64 = null;
    const output_format: OutputFormat = .NdJson;
    var fail_on_error: bool = false;
    var summary: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            model = args[i];
        } else if (std.mem.eql(u8, arg, "--field")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            json_field = args[i];
            input_mode = .JsonField;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            input_mode = .Raw;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            max_tokens = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-cost")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            max_cost = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_on_error = true;
        }
    }

    if (model == null) {
        return error.ModelRequired;
    }

    const config = PipeConfig{
        .input_mode = input_mode,
        .json_field = json_field,
        .output_format = output_format,
        .max_tokens = max_tokens,
        .max_cost = max_cost,
        .fail_on_error = fail_on_error,
        .summary = summary,
        .model_name = model.?,
    };

    const spec = tokenizer_mod.registry.Registry.getEncodingForModel(model.?);
    if (spec == null) {
        return error.UnknownModel;
    }

    const price_def = registry.getModel(model.?) orelse {
        return error.ModelNotFoundInPricing;
    };

    var tok_impl = try tokenizer_mod.openai.OpenAITokenizer.init(allocator, .{
        .spec = spec.?,
        .approximate_ok = true,
        .bpe_version = .v2_1,
    });
    defer tok_impl.deinit(allocator);

    const wrapper = TokenizerWrapper{
        .impl = tok_impl,
        .allocator = allocator,
    };

    var processor = StreamProcessor.init(allocator, wrapper, price_def, config);

    // We pass stdin as reader
    const stdin = std.io.getStdIn().reader();

    try processor.process(stdin, stdout);
}
