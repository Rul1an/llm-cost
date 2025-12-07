const std = @import("std");
const engine = @import("../core/engine.zig");
const format_lib = @import("format.zig");
const io = @import("io.zig");
const pricing = @import("../pricing.zig");

pub const OutputFormat = format_lib.OutputFormat;

pub const GlobalOptions = struct {
    model: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    format: OutputFormat = .text,
    config_path: ?[]const u8 = null,
};

pub const CliContext = struct {
    alloc: std.mem.Allocator,
    db: *pricing.PricingDB,
    opts: GlobalOptions,
    // Command-specific extras
    subcommand: []const u8,
    payload: ?[]const u8 = null,
    tokens_in: ?usize = null,
    tokens_out: ?usize = null,
};

// Error set that main() can handle appropriately
pub const CliError = error{
    UsageError,
    ModelNotFound,
    PricingError,
    IoError,
} || std.mem.Allocator.Error || engine.EngineError; // extend with engine errors

pub fn main(alloc: std.mem.Allocator) !void {
    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();

    // Skip executable name
    _ = args_it.skip();

    var ctx = CliContext{
        .alloc = alloc,
        .db = undefined,
        .opts = .{},
        .subcommand = "help",
    };

    var db = try pricing.PricingDB.init(alloc);
    defer db.deinit();
    ctx.db = &db;

    // 1. Parsing
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "tokens")) {
            ctx.subcommand = "tokens";
        } else if (std.mem.eql(u8, arg, "price")) {
            ctx.subcommand = "price";
        } else if (std.mem.eql(u8, arg, "models")) {
            ctx.subcommand = "models";
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            ctx.subcommand = "help";
        } else if (std.mem.eql(u8, arg, "--model")) {
             ctx.opts.model = args_it.next();
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
             if (args_it.next()) |fmt_str| {
                 ctx.opts.format = parseFormat(fmt_str);
             }
        } else if (std.mem.eql(u8, arg, "--tokens-in")) {
             if (args_it.next()) |n| ctx.tokens_in = std.fmt.parseInt(usize, n, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--tokens-out")) {
             if (args_it.next()) |n| ctx.tokens_out = std.fmt.parseInt(usize, n, 10) catch 0;
        } else {
             if (!std.mem.startsWith(u8, arg, "-")) {
                 ctx.payload = arg;
             }
        }
    }

    // 2. Dispatch
    if (std.mem.eql(u8, ctx.subcommand, "tokens")) {
        try runTokens(ctx);
    } else if (std.mem.eql(u8, ctx.subcommand, "price")) {
        try runPrice(ctx);
    } else if (std.mem.eql(u8, ctx.subcommand, "models")) {
        try runModels(ctx);
    } else {
        try printHelp();
    }
}

fn parseFormat(s: []const u8) OutputFormat {
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "ndjson")) return .ndjson;
    return .text;
}

fn printHelp() !void {
    const stdout = io.getStdoutWriter();
    try stdout.writeAll(
        \\Usage: llm-cost <command> [options] [file]
        \\
        \\Commands:
        \\  tokens    Estimate token count for input
        \\  price     Estimate cost for prompt or token counts
        \\  models    List available models
        \\  help      Show this help
        \\
        \\Options:
        \\  --model <name>    Model identifier (required for price)
        \\  --format <fmt>    Output format: text (default), json, ndjson
        \\  --tokens-in <N>   Manual input token count override
        \\  --tokens-out <N>  Manual output token count (for price)
        \\
        \\Examples:
        \\  echo "hello" | llm-cost tokens --model gpt-4o
        \\  llm-cost price --model gpt-4o --tokens-in 1000
        \\
    );
}

// TODO: Move this helper to some tokenizer-utils if logic gets complex
fn pickTokenizerKindFromModel(model_name: []const u8) engine.TokenizerKind {
    if (std.mem.startsWith(u8, model_name, "gpt-4o")) return .openai_o200k;
    if (std.mem.startsWith(u8, model_name, "gpt-4")) return .openai_cl100k;
    if (std.mem.startsWith(u8, model_name, "gpt-3.5")) return .openai_cl100k;
    return .generic_whitespace;
}

fn runTokens(ctx: CliContext) !void {
    var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);
    defer text_input.deinit(ctx.alloc);

    // I/O Logic: File > Stdin
    if (ctx.payload) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        try readAllInto(ctx.alloc, io.getFileReader(&f), &text_input);
    } else {
        const stdin = io.getStdinReader();
        try readAllInto(ctx.alloc, stdin, &text_input);
    }

    if (text_input.items.len == 0) {
        // If no input, effectively 0 tokens.
    }

    // Config for engine
    const model_name = ctx.opts.model orelse "generic";
    const tk_cfg = engine.TokenizerConfig{
        .kind = pickTokenizerKindFromModel(model_name),
        .model_name = model_name,
    };

    const t_res = try engine.estimateTokens(ctx.alloc, tk_cfg, text_input.items);

    // Optional: try to resolve cost if model is known
    var cost_usd: ?f64 = null;
    if (ctx.opts.model) |m| {
        // We set reasoning=0 for now in CLI v0.1
        if (engine.estimateCost(ctx.db, m, t_res.tokens, 0, 0)) |c| {
            cost_usd = c.cost_total;
        } else |_| {
            // Squelch pricing error here, as main intent is tokens command
            // But maybe debug log?
        }
    }

    const record = format_lib.ResultRecord{
        .model = model_name,
        .tokens_input = t_res.tokens,
        .tokens_output = 0,
        .cost_usd = cost_usd,
        .tokenizer = "unknown", // engine TokenResult doesn't return tokenizer name, maybe we should fix later
        .approximate = (cost_usd == null),
    };

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}

fn runPrice(ctx: CliContext) !void {
    const model = ctx.opts.model orelse {
        const stderr = std.io.getStdErr().writer(); // or io.getStderrWriter() if implemented
        try stderr.print("Error: --model required for price command.\n", .{});
        return error.UsageError;
    };

    var input_tokens: usize = 0;

    if (ctx.tokens_in) |n| {
        input_tokens = n;
    } else {
        // Consume input like token counter
        var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);
        defer text_input.deinit(ctx.alloc);

        if (ctx.payload) |path| {
            const f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            try readAllInto(ctx.alloc, io.getFileReader(&f), &text_input);
        } else {
             const stdin = io.getStdinReader();
             try readAllInto(ctx.alloc, stdin, &text_input);
        }

        if (text_input.items.len > 0) {
             const tk_cfg = engine.TokenizerConfig{
                 .kind = pickTokenizerKindFromModel(model),
                 .model_name = model,
             };
             const t_res = try engine.estimateTokens(ctx.alloc, tk_cfg, text_input.items);
             input_tokens = t_res.tokens;
        }
    }

    const output_tokens = ctx.tokens_out orelse 0;

    const cost_res = engine.estimateCost(ctx.db, model, input_tokens, output_tokens, 0) catch |err| {
        if (err == error.ModelNotFound) {
             // We print explicit error
             const stderr = std.io.getStdErr().writer();
             try stderr.print("Error: Model '{s}' not found in pricing database.\n", .{model});
             return error.ModelNotFound; // Bubble up
        }
        return err;
    };

    const record = format_lib.ResultRecord{
        .model = cost_res.model_name,
        .tokens_input = cost_res.input_tokens,
        .tokens_output = cost_res.output_tokens,
        // .tokens_reasoning = cost_res.reasoning_tokens, // Add to format.zig later
        .cost_usd = cost_res.cost_total,
        .tokenizer = "from_db", // TODO: cost_res doesn't have tokenizer field in senior struct?
        // Wait, senior struct CostResult HAS model_name, and pricing DB has info.
        // We can check the DB record again or trust engine returned clean data.
        .approximate = false,
    };

    // Note: The review struct for CostResult REMOVED `tokenizer` field that I added earlier!
    // The senior struct didn't have it.
    // I should strictly follow the senior struct.
    // So record.tokenizer will be "unknown" or I lookup model again?
    // Optimization: avoid double lookup. Ideally CostResult has metadata.
    // But adhering to strict instructions: use the struct provided.

    // Actually, I can stick to the user provided snippet for CostResult which does NOT have tokenizer.
    // But format_lib expects it.
    // I will pass "unknown" for now or re-resolve if I must.

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}

fn runModels(ctx: CliContext) !void {
    const stdout = io.getStdoutWriter();
    // Only "human" format supported for models list currently
    if (ctx.opts.format != .text) {
        // Fallback or explicit warning?
    }

    try stdout.print("Models in database:\n", .{});
    const root = ctx.db.parsed.value;
    if (root.object.get("models")) |models| {
         var it = models.object.iterator();
         while (it.next()) |entry| {
             try stdout.print("- {s}\n", .{entry.key_ptr.*});
         }
    }
}

pub fn readAllInto(alloc: std.mem.Allocator, reader: anytype, out: *std.ArrayList(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

fn runPricing(ctx: CliContext) !void {
     const root = ctx.db.parsed.value;
     var version: []const u8 = "unknown";
     if (root.object.get("version")) |v| {
         version = v.string;
     }

     std.debug.print("Pricing Database Meta:\n", .{});
     std.debug.print("  Version: {s}\n", .{version});

     if (root.object.get("models")) |models| {
         var it = models.object.iterator();
         while (it.next()) |entry| {
             std.debug.print("- {s}\n", .{entry.key_ptr.*});
         }
    }
}
