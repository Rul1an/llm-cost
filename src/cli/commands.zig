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
    const help_text =
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
    ;
    try io.writeStdout(help_text);
}

// TODO: Move this helper to some tokenizer-utils if logic gets complex
fn pickTokenizerKindFromModel(model_name: []const u8) engine.TokenizerKind {
    if (std.mem.startsWith(u8, model_name, "gpt-4o")) return .openai_o200k;
    if (std.mem.startsWith(u8, model_name, "gpt-4")) return .openai_cl100k;
    if (std.mem.startsWith(u8, model_name, "gpt-3.5")) return .openai_cl100k;
    return .generic_whitespace;
}

fn runTokens(ctx: CliContext) !void {
    // I/O Logic: Read entire input
    const input_data = if (ctx.payload) |path|
        try io.readFileAll(ctx.alloc, path)
    else
        try io.readStdinAll(ctx.alloc);

    defer ctx.alloc.free(input_data);

    if (input_data.len == 0) {
        // If no input, effectively 0 tokens.
    }

    // Config for engine
    const model_name = ctx.opts.model orelse "generic";
    const tk_cfg = engine.TokenizerConfig{
        .kind = pickTokenizerKindFromModel(model_name),
        .model_name = model_name,
    };

    const t_res = try engine.estimateTokens(ctx.alloc, tk_cfg, input_data);

    // Optional: try to resolve cost if model is known
    var cost_usd: ?f64 = null;
    if (ctx.opts.model) |m| {
        // We set reasoning=0 for now in CLI v0.1
        if (engine.estimateCost(ctx.db, m, t_res.tokens, 0, 0)) |c| {
            cost_usd = c.cost_total;
        } else |_| {
            // Squelch pricing error here
        }
    }

    const record = format_lib.ResultRecord{
        .model = model_name,
        .tokens_input = t_res.tokens,
        .tokens_output = 0,
        .cost_usd = cost_usd,
        .tokenizer = "unknown",
        .approximate = (cost_usd == null),
    };

    var buf = std.ArrayList(u8).init(ctx.alloc);
    defer buf.deinit();

    try format_lib.formatOutput(ctx.alloc, buf.writer(), ctx.opts.format, record);
    try io.writeStdout(buf.items);
}

fn runPrice(ctx: CliContext) !void {
    const model = ctx.opts.model orelse {
        try io.writeStderr("Error: --model required for price command.\n");
        return error.UsageError;
    };

    var input_tokens: usize = 0;

    if (ctx.tokens_in) |n| {
        input_tokens = n;
    } else {
        // Consume input like token counter
        const input_data = if (ctx.payload) |path|
            try io.readFileAll(ctx.alloc, path)
        else
            try io.readStdinAll(ctx.alloc);
        defer ctx.alloc.free(input_data);

        if (input_data.len > 0) {
             const tk_cfg = engine.TokenizerConfig{
                 .kind = pickTokenizerKindFromModel(model),
                 .model_name = model,
             };
             const t_res = try engine.estimateTokens(ctx.alloc, tk_cfg, input_data);
             input_tokens = t_res.tokens;
        }
    }

    const output_tokens = ctx.tokens_out orelse 0;

    const cost_res = engine.estimateCost(ctx.db, model, input_tokens, output_tokens, 0) catch |err| {
        if (err == error.ModelNotFound) {
             // We print explicit error
             try io.writeStderr("Error: Model not found in pricing database.\n");
             return error.ModelNotFound;
        }
        return err;
    };

    const record = format_lib.ResultRecord{
        .model = cost_res.model_name,
        .tokens_input = cost_res.input_tokens,
        .tokens_output = cost_res.output_tokens,
        .cost_usd = cost_res.cost_total,
        .tokenizer = "from_db",
        .approximate = false,
    };

    var buf = std.ArrayList(u8).init(ctx.alloc);
    defer buf.deinit();

    try format_lib.formatOutput(ctx.alloc, buf.writer(), ctx.opts.format, record);
    try io.writeStdout(buf.items);
}

fn runModels(ctx: CliContext) !void {
    var buf = std.ArrayList(u8).init(ctx.alloc);
    defer buf.deinit();

    // Only "human" format supported for models list currently
    if (ctx.opts.format != .text) {
        // Fallback
    }

    try buf.writer().print("Models in database:\n", .{});
    const root = ctx.db.parsed.value;
    if (root.object.get("models")) |models| {
         var it = models.object.iterator();
         while (it.next()) |entry| {
             try buf.writer().print("- {s}\n", .{entry.key_ptr.*});
         }
    }

    try io.writeStdout(buf.items);
}
