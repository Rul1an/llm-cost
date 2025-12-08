const std = @import("std");
const engine = @import("../core/engine.zig");
const format_lib = @import("format.zig");
const io = @import("io.zig");
const pricing = @import("../pricing.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const model_registry = tokenizer_mod.model_registry;
const pipe_cmd = @import("pipe.zig"); // Added import

pub const OutputFormat = format_lib.OutputFormat;

pub const GlobalOptions = struct {
    model: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    format: OutputFormat = .text,
    config_path: ?[]const u8 = null,
    allow_special_tokens: bool = false,

    // Pipe specific
    field: []const u8 = "text",
    pipe_mode: pipe_cmd.PipeMode = .tokens,
    fail_on_error: bool = false,
    workers: usize = 1,
    max_tokens: usize = 0,
    max_cost: f64 = 0.0,
    show_summary: bool = false,
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
        } else if (std.mem.eql(u8, arg, "pipe")) {
            ctx.subcommand = "pipe";
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
        } else if (std.mem.eql(u8, arg, "--allow-special-tokens")) {
             ctx.opts.allow_special_tokens = true;
        } else if (std.mem.eql(u8, arg, "--field")) {
             if (args_it.next()) |val| ctx.opts.field = val;
        } else if (std.mem.eql(u8, arg, "--mode")) {
             if (args_it.next()) |val| {
                 if (std.mem.eql(u8, val, "price")) ctx.opts.pipe_mode = .price
                 else ctx.opts.pipe_mode = .tokens;
             }
        } else if (std.mem.eql(u8, arg, "--fail-on-error")) {
             ctx.opts.fail_on_error = true;
        } else if (std.mem.eql(u8, arg, "--workers")) {
             if (args_it.next()) |n| ctx.opts.workers = std.fmt.parseInt(usize, n, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
             if (args_it.next()) |n| ctx.opts.max_tokens = std.fmt.parseInt(usize, n, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--max-cost")) {
             if (args_it.next()) |n| ctx.opts.max_cost = std.fmt.parseFloat(f64, n) catch 0.0;
        } else if (std.mem.eql(u8, arg, "--summary")) {
             ctx.opts.show_summary = true;
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
    } else if (std.mem.eql(u8, ctx.subcommand, "pipe")) {
        try runPipe(ctx);
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
        \\  pipe      Enrich JSONL stream with tokens/cost (ndjson in -> ndjson out)
        \\  models    List available models
        \\  help      Show this help
        \\
        \\Global options:
        \\  --model <name>         Model identifier (e.g. openai/gpt-4o)
        \\  --format <fmt>         Output format: text (default), json, ndjson
        \\  --allow-special-tokens Treat special tokens as ordinary text
        \\
        \\Price options:
        \\  --tokens-in <N>        Manual input token count override
        \\  --tokens-out <N>       Manual output token count (for price)
        \\
        \\Pipe options:
        \\  --field <name>         JSON field containing text (default: "text")
        \\  --mode <tokens|price>  Pipe mode (add only tokens, or tokens+cost)
        \\  --workers <N>          Number of worker threads (default: 1)
        \\  --max-tokens <N>       Hard token quota (forces single-thread mode)
        \\  --max-cost <USD>       Hard cost quota (forces single-thread mode)
        \\  --fail-on-error        Treat per-line errors as fatal (single-thread only)
        \\  --summary              Print aggregate stats to stderr
        \\
        \\Examples:
        \\  echo "hello" | llm-cost tokens --model gpt-4o
        \\  llm-cost price --model gpt-4o --tokens-in 1000
        \\  cat data.jsonl | llm-cost pipe --model gpt-4o --field text --mode price --summary
        \\
    );
}

// Map model name to encoding spec, or null for generic
// Helper removed in favor of ModelRegistry.resolve


fn readAllInto(reader: anytype, buffer: *std.ArrayList(u8)) !void {
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = try reader.read(read_buf[0..]);
        if (n == 0) break;
        try buffer.appendSlice(read_buf[0..n]);
    }
}

fn runTokens(ctx: CliContext) !void {
    var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);
    defer text_input.deinit();

    // I/O Logic: File > Stdin
    if (ctx.payload) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        try readAllInto(io.getFileReader(&f), &text_input);
    } else {
        const stdin = io.getStdinReader();
        try readAllInto(stdin, &text_input);
    }

    if (text_input.items.len == 0) {
        // If no input, effectively 0 tokens.
    }

    // Config for engine
    const raw_model_name = ctx.opts.model orelse "generic";
    const spec = model_registry.ModelRegistry.resolve(raw_model_name);

    // Use canonical name for logic and display
    const model_name = spec.canonical_name;

    const tk_cfg = engine.TokenizerConfig{
        .spec = spec.encoding,
        .model_name = model_name,
    };

    const special_mode: engine.SpecialMode = if (ctx.opts.allow_special_tokens) .ordinary else .strict;
    const t_res = try engine.estimateTokens(ctx.alloc, tk_cfg, text_input.items, special_mode);

    // Optional: try to resolve cost if model is known
    var cost_usd: ?f64 = null;
     if (ctx.opts.model) |_| {
         // Use canonical name, not spec.id.name or raw input
         // We set reasoning=0 for now.
        if (engine.estimateCost(ctx.db, model_name, t_res.tokens, 0, 0)) |c| {
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
        .tokenizer = if (spec.encoding) |e| e.name else "whitespace",
        .accuracy = @tagName(spec.accuracy),
        .approximate = (cost_usd == null) or (spec.accuracy != .exact),
    };

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}

fn runPrice(ctx: CliContext) !void {
    const raw_model = ctx.opts.model orelse {
        const stderr = io.getStderrWriter();
        try stderr.print("Error: --model required for price command.\n", .{});
        return error.UsageError;
    };

    const spec = model_registry.ModelRegistry.resolve(raw_model);
    const model = spec.canonical_name;

    var input_tokens: usize = 0;

    if (ctx.tokens_in) |n| {
        input_tokens = n;
    } else {
        // Consume input like token counter
        var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);
        defer text_input.deinit();

        if (ctx.payload) |path| {
            const f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            try readAllInto(io.getFileReader(&f), &text_input);
        } else {
             const stdin = io.getStdinReader();
             try readAllInto(stdin, &text_input);
        }

        if (text_input.items.len > 0) {
             const tk_cfg = engine.TokenizerConfig{
                 .spec = spec.encoding,
                 .model_name = model,
             };
             const special_mode: engine.SpecialMode = if (ctx.opts.allow_special_tokens) .ordinary else .strict;
             const t_res = try engine.estimateTokens(ctx.alloc, tk_cfg, text_input.items, special_mode);
             input_tokens = t_res.tokens;
        }
    }

    const output_tokens = ctx.tokens_out orelse 0;

    const cost_res = engine.estimateCost(ctx.db, model, input_tokens, output_tokens, 0) catch |err| {
        if (err == error.ModelNotFound) {
             // We print explicit error
             const stderr = io.getStderrWriter();
             try stderr.print("Error: Model '{s}' not found in pricing database.\n", .{model});
             return error.ModelNotFound;
        }
        return err;
    };

    const record = format_lib.ResultRecord{
        .model = cost_res.model_name,
        .tokens_input = cost_res.input_tokens,
        .tokens_output = cost_res.output_tokens,
        .cost_usd = cost_res.cost_total,
        .tokenizer = if (spec.encoding) |e| e.name else "whitespace",
        .accuracy = @tagName(spec.accuracy),
        .approximate = (spec.accuracy != .exact),
    };

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}

fn runModels(ctx: CliContext) !void {
    const stdout = io.getStdoutWriter();
    // Only "human" format supported for models list currently
    if (ctx.opts.format != .text) {
        // Fallback
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

fn runPipe(ctx: CliContext) !void {
    const raw_model_name = ctx.opts.model orelse "generic";
    const spec = model_registry.ModelRegistry.resolve(raw_model_name);
    const model_name = spec.canonical_name; // Use canonical

    const tk_cfg = engine.TokenizerConfig{
        .spec = spec.encoding,
        .model_name = model_name,
    };

    const special_mode: engine.SpecialMode = if (ctx.opts.allow_special_tokens) .ordinary else .strict;

    const pipe_opts = pipe_cmd.PipeOptions{
        .allocator = ctx.alloc,
        .stdin = io.getStdinReader(),
        .stdout = io.getStdoutWriter(),
        .stderr = io.getStderrWriter(),

        .model = model_name,
        .field = ctx.opts.field,
        .quota = .{
            .max_tokens = ctx.opts.max_tokens,
            .max_cost_usd = ctx.opts.max_cost,
        },
        .show_summary = ctx.opts.show_summary,
        .mode = ctx.opts.pipe_mode,
        .fail_on_error = ctx.opts.fail_on_error,
        .special_mode = special_mode,
        .workers = ctx.opts.workers,

        .cfg = tk_cfg,
        .db = ctx.db,
        .accuracy = @tagName(spec.accuracy),
    };

    _ = pipe_cmd.run(pipe_opts) catch |err| {
        if (err == pipe_cmd.PipeError.QuotaExceeded) {
             const stderr = io.getStderrWriter();

             const has_tokens = ctx.opts.max_tokens > 0;
             const has_cost = ctx.opts.max_cost > 0.0;

             if (has_tokens and has_cost) {
                 try stderr.print(
                     "error: quota exceeded (max_tokens={d}, max_cost={d:.6}).\n",
                     .{ ctx.opts.max_tokens, ctx.opts.max_cost },
                 );
             } else if (has_tokens) {
                 try stderr.print(
                     "error: token quota exceeded (max_tokens={d}).\n",
                     .{ ctx.opts.max_tokens },
                 );
             } else if (has_cost) {
                 try stderr.print(
                     "error: cost quota exceeded (max_cost={d:.6}).\n",
                     .{ ctx.opts.max_cost },
                 );
             } else {
                 try stderr.print("error: quota exceeded.\n", .{});
             }

             // In main() we treat this as a non-zero exit eventually due to returning error.
             // We can return UsageError to signify "user error/limit hit" rather than system crash.
             return CliError.UsageError;
        }
        return err;
    };
}

