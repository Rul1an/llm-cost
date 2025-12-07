const std = @import("std");
const engine = @import("../core/engine.zig");
const format_lib = @import("format.zig");
const io = @import("io.zig");
const pricing = @import("../pricing.zig");

const OutputFormat = format_lib.OutputFormat;
const GlobalOptions = engine.GlobalOptions;

pub fn readAllInto(alloc: std.mem.Allocator, reader: anytype, out: *std.ArrayList(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

pub fn main(alloc: std.mem.Allocator) !void {
    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();

    // skip argv[0]
    _ = args_it.next();

    // Default to help if no subcmd
    const subcmd_str = args_it.next() orelse {
        try printHelp();
        return;
    };
    const subcmd = parseSubcommand(subcmd_str);

    var opts = GlobalOptions{};
    var arg_payload: ?[]const u8 = null; // For file path or other payload
    var tokens_in_opt: ?usize = null;
    var tokens_out_opt: ?usize = null;

    // Parse loop
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--model")) {
            opts.model = args_it.next() orelse return usageError("missing value for --model");
        } else if (std.mem.eql(u8, arg, "--vendor")) {
            opts.vendor = args_it.next() orelse return usageError("missing value for --vendor");
        } else if (std.mem.eql(u8, arg, "--format")) {
            const f_str = args_it.next() orelse return usageError("missing value for --format");
            opts.format = try parseFormat(f_str);
        } else if (std.mem.eql(u8, arg, "--config")) {
             opts.config_path = args_it.next() orelse return usageError("missing value for --config");
        } else if (std.mem.eql(u8, arg, "--tokens-in")) {
             const val = args_it.next() orelse return usageError("missing value for --tokens-in");
             tokens_in_opt = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--tokens-out")) {
             const val = args_it.next() orelse return usageError("missing value for --tokens-out");
             tokens_out_opt = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
             std.debug.print("Unknown option: {s}\n", .{arg});
             return error.UsageError;
        } else {
             // Positional arg (e.g. file path)
             arg_payload = arg;
        }
    }

    // Init Pricing DB once (if needed)
    // For now we just load default, later override with config_path
    var db = try pricing.PricingDB.init(alloc);
    defer db.deinit();

    const ctx = CliContext{
        .alloc = alloc,
        .opts = opts,
        .db = &db,
        .payload = arg_payload,
        .tokens_in = tokens_in_opt,
        .tokens_out = tokens_out_opt,
    };

    switch (subcmd) {
        .tokens => try runTokens(ctx),
        .price => try runPrice(ctx),
        .models => try runModels(ctx),
        .pricing => try runPricing(ctx),
        .help => try printHelp(),
    }
}

const CliContext = struct {
    alloc: std.mem.Allocator,
    opts: GlobalOptions,
    db: *pricing.PricingDB,
    payload: ?[]const u8, // Subcommand specific payload (e.g. file path)
    tokens_in: ?usize,
    tokens_out: ?usize,
};

const Subcommand = enum {
    tokens,
    price,
    models,
    pricing,
    help,
};

fn parseSubcommand(name: []const u8) Subcommand {
    if (std.mem.eql(u8, name, "tokens")) return .tokens;
    if (std.mem.eql(u8, name, "price")) return .price;
    if (std.mem.eql(u8, name, "models")) return .models;
    if (std.mem.eql(u8, name, "pricing")) return .pricing;
    if (std.mem.eql(u8, name, "help")) return .help;
    return .help;
}

fn parseFormat(s: []const u8) !OutputFormat {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "ndjson")) return .ndjson;
    return error.UnknownFormat;
}

fn usageError(msg: []const u8) !void {
    std.debug.print("llm-cost: {s}\n\n", .{msg});
    try printHelp();
    return error.UsageError;
}

fn printHelp() !void {
    std.debug.print(
        \\llm-cost - token counting and cost estimation
        \\
        \\Usage:
        \\  llm-cost tokens [--model <name>] [--format text|json|ndjson] [file]
        \\  llm-cost price  [--model <name>] [--tokens-in <N>] [--tokens-out <M>]
        \\  llm-cost models
        \\  llm-cost pricing
        \\
        \\Global Options:
        \\  --model <name>      Target Model (e.g. gpt-4o)
        \\  --format <fmt>      Output format (text, json, ndjson)
        \\  --config <path>     Custom pricing JSON
        \\
        , .{});
}

// --- Subcommands ---

fn runTokens(ctx: CliContext) !void {
    var text_input = try std.ArrayList(u8).initCapacity(ctx.alloc, 4096);
    defer text_input.deinit(ctx.alloc);

    // If payload is present, assume file path. Else stdin.
    if (ctx.payload) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
            try readAllInto(ctx.alloc, io.getFileReader(&f), &text_input);
    } else {
        const stdin = io.getStdinReader();
        try readAllInto(ctx.alloc, stdin, &text_input);
    }

    if (text_input.items.len == 0) {
        // Fallback or empty
    }

    const t_res = try engine.estimateTokens(ctx.alloc, ctx.opts, text_input.items);

    // Check if we can also show price?
    var cost_usd: ?f64 = null;
    if (ctx.opts.model) |m| {
        if (engine.estimateCost(ctx.db, m, t_res.tokens, 0)) |c| {
            cost_usd = c.cost_total;
        } else |_| {}
    }

    const record = format_lib.ResultRecord{
        .model = ctx.opts.model orelse "unknown",
        .tokens_input = t_res.tokens,
        .tokens_output = 0,
        .cost_usd = cost_usd,
    };

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}

fn runPrice(ctx: CliContext) !void {
    const model = ctx.opts.model orelse return usageError("price command requires --model");

    // We need input tokens.
    // 1. Explicit via --tokens-in
    // 2. Or counted from stdin/file (like runTokens)

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
             // If manual tokens not provided, maybe stdin?
             const stdin = io.getStdinReader();
             try readAllInto(ctx.alloc, stdin, &text_input);
        }

        if (text_input.items.len > 0) {
             const t_res = try engine.estimateTokens(ctx.alloc, ctx.opts, text_input.items);
             input_tokens = t_res.tokens;
        }
    }

    const output_tokens = ctx.tokens_out orelse 0;

    const cost_res = engine.estimateCost(ctx.db, model, input_tokens, output_tokens) catch |err| {
        if (err == error.ModelNotFound) {
             std.debug.print("Error: Model '{s}' not found in pricing database.\n", .{model});
             return; // exit 1 ideally
        }
        return err;
    };

    const record = format_lib.ResultRecord{
        .model = cost_res.model_name,
        .tokens_input = cost_res.input_tokens,
        .tokens_output = cost_res.output_tokens,
        .cost_usd = cost_res.cost_total,
    };

    const stdout = io.getStdoutWriter();
    try format_lib.formatOutput(ctx.alloc, stdout, ctx.opts.format, record);
}


fn runModels(ctx: CliContext) !void {
    // List models from db
    // Since PricingDB uses std.json.Parsed, we need to inspect the value tree manually
    const root = ctx.db.parsed.value;
    std.debug.print("Models in database:\n", .{});

    if (root.object.get("models")) |models| {
        var it = models.object.iterator();
        while (it.next()) |entry| {
            std.debug.print("- {s}\n", .{entry.key_ptr.*});
        }
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
