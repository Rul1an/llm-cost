const std = @import("std");
const engine = @import("core/engine.zig");
const Pricing = @import("core/pricing/mod.zig");

pub const ReportConfig = struct {
    model: []const u8 = "gpt-4o",
    file_path: ?[]const u8 = null,
    format: enum { text, json } = .text,
};

pub const ReportStats = struct {
    file_size_bytes: u64 = 0,
    token_count: u64 = 0,
    word_count: u64 = 0,
    cost_usd: f64 = 0.0,

    // Derived Metrics
    pub fn bytesPerToken(self: ReportStats) f64 {
        if (self.token_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.file_size_bytes)) / @as(f64, @floatFromInt(self.token_count));
    }

    pub fn tokensPerWord(self: ReportStats) f64 {
        if (self.word_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.token_count)) / @as(f64, @floatFromInt(self.word_count));
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    registry: *const Pricing.Registry, // Received registry
    stdout: anytype,
) !void {
    var config = ReportConfig{};

    // 1. Parse Args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            config.model = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.format = .json;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            config.file_path = arg;
        }
    }

    // 2. Load Data (File or Stdin)
    const content = if (config.file_path) |path| blk: {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB limit
    } else blk: {
        break :blk try std.io.getStdIn().readToEndAlloc(allocator, 1024 * 1024 * 100);
    };
    defer allocator.free(content);

    // 3. Analyze
    var stats = ReportStats{};
    stats.file_size_bytes = content.len;
    stats.word_count = countWords(content);

    // Tokenize
    const tokenizer_config = try engine.resolveConfig(config.model);
    stats.token_count = try engine.countTokens(allocator, content, tokenizer_config);

    // Cost (Input Only assumption for corpus analysis)
    if (registry.get(config.model)) |def| {
        stats.cost_usd = Pricing.Registry.calculate(def, stats.token_count, 0, 0);
    }

    // 4. Report
    if (config.format == .json) {
        try stdout.print(
            \\{{
            \\  "model": "{s}",
            \\  "stats": {{
            \\    "bytes": {d},
            \\    "tokens": {d},
            \\    "words": {d},
            \\    "cost_usd": {d:.6}
            \\  }},
            \\  "metrics": {{
            \\    "bytes_per_token": {d:.2},
            \\    "tokens_per_word": {d:.2}
            \\  }}
            \\}}
            \\
        , .{ config.model, stats.file_size_bytes, stats.token_count, stats.word_count, stats.cost_usd, stats.bytesPerToken(), stats.tokensPerWord() });
    } else {
        try stdout.print("\n=== Tokenizer Report: {s} ===\n", .{config.model});
        try stdout.print("Corpus Size:    {d} bytes\n", .{stats.file_size_bytes});
        try stdout.print("Word Count:     {d} words\n", .{stats.word_count});
        try stdout.print("Token Count:    {d} tokens\n", .{stats.token_count});
        try stdout.print("Est. Cost:      ${d:.6}\n", .{stats.cost_usd});
        try stdout.print("\n--- Efficiency Metrics ---\n", .{});
        try stdout.print("Compression:    {d:.2} bytes/token  (Higher is better)\n", .{stats.bytesPerToken()});
        try stdout.print("Fertility:      {d:.2} tokens/word  (Lower is better)\n", .{stats.tokensPerWord()});
    }
}

fn countWords(text: []const u8) u64 {
    var count: u64 = 0;
    var in_word = false;
    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (in_word and is_space) {
            in_word = false;
        } else if (!in_word and !is_space) {
            in_word = true;
            count += 1;
        }
    }
    return count;
}
