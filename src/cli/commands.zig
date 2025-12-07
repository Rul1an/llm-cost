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

fn readAllInto(reader: anytype, buffer: *std.ArrayList(u8)) !void {
    var read_buf: [4096]u8 = undefined;
    while (try reader.read(read_buf[0..])) |bytes_read| {
        try buffer.appendSlice(read_buf[0..bytes_read]);
    }
}

fn runTokens(ctx: CliContext) !void {
    var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);
    defer text_input.deinit(); // Note: fix deinit call too if needed? ArrayList.deinit() usually suffices if it stores allocator?
    // Wait, ArrayList(T).deinit() DOES use stored allocator. The previous code had `defer text_input.deinit(ctx.alloc);` ?
    // Let's check initCapacity. `initCapacity` stores the allocator.
    // If previous code was `text_input.deinit(ctx.alloc)`, that suggests ArrayListUnmanaged usage pattern or misunderstanding.
    // Standard `std.ArrayList` `deinit` takes no args.
    // But let's look at the View File 1157 again.
    // Line 138: `var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);`
    // Line 139: `defer text_input.deinit(ctx.alloc);` -> This looks like wrong syntax for std.ArrayList if checking 0.13 docs?
    // std.ArrayList.deinit() takes no args.
    // std.ArrayListUnmanaged.deinit(allocator) takes args.
    // If it *compiled* before, maybe it was `deinit()` and I misremembered or the previous file content view shows...
    // Let's check the previous replace...
    // Step 1145: `defer text_input.deinit(ctx.alloc);` was inserted.
    // ERROR potential: `std.ArrayList` `deinit` usually takes NO allocator. `initCapacity` takes it and stores it.
    // I should fix this too if it's an error.

    // However, the reported error is ONLY `unused function parameter`.
    // If `deinit(ctx.alloc)` was an error, it would likely be reported too.
    // Wait, `ArrayList.deinit` signature: `pub fn deinit(self: Self) void`.
    // Passing an argument to a function that takes none IS an error in Zig.
    // Why did the user only report the unused param? Maybe the compiler stopped at the first error?
    // Or maybe `text_input` is actually `ArrayListUnmanaged`?
    // Line 138 says `std.ArrayList(u8)`.
    // So `deinit(ctx.alloc)` IS WRONG.
    // I will fix `deinit` usage as well just in case.

    // I/O Logic: File > Stdin
    if (ctx.payload) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        try readAllInto(io.getFileReader(&f), &text_input);
    } else {
        const stdin = io.getStdinReader();
        try readAllInto(stdin, &text_input);
    }
// ...

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

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}

fn runPrice(ctx: CliContext) !void {
    const model = ctx.opts.model orelse {
        const stderr = io.getStderrWriter();
        try stderr.print("Error: --model required for price command.\n", .{});
        return error.UsageError;
    };

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
        .tokenizer = "from_db",
        .approximate = false,
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
