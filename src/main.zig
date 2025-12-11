const std = @import("std");
const builtin = @import("builtin");
const tokenizer = @import("tokenizer/mod.zig");
const Pricing = @import("core/pricing/mod.zig");
const engine = @import("core/engine.zig");
const pipe = @import("pipe.zig");
const report = @import("report.zig");
const analytics = @import("analytics/mod.zig");
const update = @import("update.zig");
const check = @import("check.zig");

pub const version_str = "0.9.0";

// --- CLI State (Now Public) ---
pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    registry: *Pricing.Registry,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
};

pub fn main() !void {
    // 1. Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. Setup I/O
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // 3. Initialize Pricing Registry
    // Verified Mode (Minisign)
    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    // 4. Parse Args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
        return;
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try stdout.print("llm-cost v{s} ({s})\n", .{ version_str, @tagName(builtin.mode) });
        return;
    }

    // Initialize Global State
    const state = GlobalState{
        .allocator = allocator,
        .registry = &registry,
        .stdout = stdout.any(),
        .stderr = stderr.any(),
    };

    if (std.mem.eql(u8, command, "models")) {
        try runModels(state, args[2..]);
    } else if (std.mem.eql(u8, command, "tokens") or std.mem.eql(u8, command, "count")) {
        try runCount(state, args[2..]);
    } else if (std.mem.eql(u8, command, "price") or std.mem.eql(u8, command, "estimate")) {
        try runEstimate(state, args[2..]);
    } else if (std.mem.eql(u8, command, "pipe")) {
        try runPipe(state, args[2..]);
    } else if (std.mem.eql(u8, command, "report") or std.mem.eql(u8, command, "tokenizer-report")) {
        try runReport(state, args[2..]);
    } else if (std.mem.eql(u8, command, "analyze-fairness")) {
        try runFairnessAnalysis(state, args[2..]);
    } else if (std.mem.eql(u8, command, "update-db")) {
        try update.run(state.allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        const exit_code = try check.run(state.allocator, args[2..], state.registry, state.stdout, state.stderr);
        if (exit_code != 0) std.process.exit(exit_code);
    } else {
        try stderr.print("Error: Unknown command '{s}'\n\n", .{command});
        try printUsage(stderr);
        std.process.exit(1);
    }
}

// --- Commands (Now Public) ---

pub fn runModels(state: GlobalState, args: []const []const u8) !void {
    var format_json = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--format=json") or std.mem.eql(u8, arg, "--json")) {
            format_json = true;
        }
    }

    // Collect keys for sorting (Determinism for Golden Tests)
    var keys = std.ArrayList([]const u8).init(state.allocator);
    defer keys.deinit();

    var it = state.registry.models.iterator();
    while (it.next()) |entry| {
        try keys.append(entry.key_ptr.*);
    }

    // Sort keys alphabetically
    if (keys.items.len > 1) {
        std.mem.sort([]const u8, keys.items, {}, stringLessThan);
    }

    if (format_json) {
        try state.stdout.print("[\n", .{});
        for (keys.items, 0..) |key, i| {
            const def = state.registry.models.get(key).?;
            // Handling potential alias fields if PriceDef uses input_cost vs input_price
            // The User's PriceDef in mod.zig has input_price_per_mtok
            const in_p = if (def.input_price_per_mtok > 0) def.input_price_per_mtok else def.input_cost_per_mtok;
            const out_p = if (def.output_price_per_mtok > 0) def.output_price_per_mtok else def.output_cost_per_mtok;

            try state.stdout.print("  {{\n", .{});
            try state.stdout.print("    \"id\": \"{s}\",\n", .{key});
            try state.stdout.print("    \"cost_in\": {d},\n", .{in_p});
            try state.stdout.print("    \"cost_out\": {d}", .{out_p});
            if (def.output_reasoning_price_per_mtok > 0) {
                try state.stdout.print(",\n    \"cost_reasoning\": {d}", .{def.output_reasoning_price_per_mtok});
            }
            try state.stdout.print("\n", .{});
            if (i < keys.items.len - 1) {
                try state.stdout.print("  }},\n", .{});
            } else {
                try state.stdout.print("  }}\n", .{});
            }
        }
        try state.stdout.print("]\n", .{});
    } else {
        try state.stdout.print("{s:<20} {s:<15} {s:<15} {s:<15}\n", .{ "MODEL", "INPUT ($/1M)", "OUTPUT ($/1M)", "REAS ($/1M)" });
        try state.stdout.print("{s:-<20} {s:-<15} {s:-<15} {s:-<15}\n", .{ "", "", "", "" });

        for (keys.items) |key| {
            const def = state.registry.models.get(key).?;
            const in_p = if (def.input_price_per_mtok > 0) def.input_price_per_mtok else def.input_cost_per_mtok;
            const out_p = if (def.output_price_per_mtok > 0) def.output_price_per_mtok else def.output_cost_per_mtok;

            const reas_str = if (def.output_reasoning_price_per_mtok > 0)
                try std.fmt.allocPrint(state.allocator, "${d:.2}", .{def.output_reasoning_price_per_mtok})
            else
                "-";
            // Note: In runModels we allocPrint, we should free it.
            // But for simple CLI output, arena or defer is fine.
            // But we are using GPA in main... so we must free.
            defer if (def.output_reasoning_price_per_mtok > 0) state.allocator.free(reas_str);

            try state.stdout.print("{s:<20} ${d:<14.2} ${d:<14.2} {s:<14}\n", .{ key, in_p, out_p, reas_str });
        }
        try state.stdout.print("\nTotal models: {d}\n", .{keys.items.len});
    }
}

pub fn runEstimate(state: GlobalState, args: []const []const u8) !void {
    var model_name: []const u8 = "gpt-4o";
    var file_path: ?[]const u8 = null;
    var input_tokens_arg: ?u64 = null;
    var output_tokens_arg: ?u64 = null;
    var reasoning_tokens_arg: u64 = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            model_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--input-tokens")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            input_tokens_arg = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--output-tokens")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            output_tokens_arg = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--reasoning-tokens")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            reasoning_tokens_arg = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    const price_def = state.registry.get(model_name) orelse {
        try state.stderr.print("Error: Unknown model '{s}'. Run 'llm-cost models' to list available models.\n", .{model_name});
        std.process.exit(1);
    };

    var token_count: u64 = 0;
    if (input_tokens_arg != null) {
        token_count = input_tokens_arg.?;
    } else {
        const input_text = if (file_path) |path| blk: {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(state.allocator, 1024 * 1024 * 10);
        } else blk: {
            // Testing note: this reads stdin. runEstimate test should mock this or use --input-tokens
            break :blk try std.io.getStdIn().readToEndAlloc(state.allocator, 1024 * 1024 * 10);
        };
        defer state.allocator.free(input_text);

        if (input_text.len > 0) {
            const tokenizer_config = try engine.resolveConfig(model_name);
            token_count = try engine.countTokens(state.allocator, input_text, tokenizer_config);
        }
    }

    const out_tok = output_tokens_arg orelse 0;
    const cost = Pricing.Registry.calculate(price_def, token_count, out_tok, reasoning_tokens_arg);

    try state.stdout.print("Model:       {s}\n", .{model_name});
    try state.stdout.print("Tokens In:   {d}\n", .{token_count});
    if (out_tok > 0) try state.stdout.print("Tokens Out:  {d}\n", .{out_tok});
    if (reasoning_tokens_arg > 0) try state.stdout.print("Tokens Reas: {d}\n", .{reasoning_tokens_arg});
    try state.stdout.print("Cost (est):  ${d:.6}\n", .{cost});
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn runCount(state: GlobalState, args: []const []const u8) !void {
    var model_name: []const u8 = "gpt-4o";
    var file_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            model_name = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    const tokenizer_config = try engine.resolveConfig(model_name);

    const input_text = if (file_path) |path| blk: {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(state.allocator, 1024 * 1024 * 100);
    } else blk: {
        break :blk try std.io.getStdIn().readToEndAlloc(state.allocator, 1024 * 1024 * 100);
    };
    defer state.allocator.free(input_text);

    const count = try engine.countTokens(state.allocator, input_text, tokenizer_config);
    try state.stdout.print("{d}\n", .{count});
}

pub fn runPipe(state: GlobalState, args: []const []const u8) !void {
    try pipe.run(state.allocator, args, state.registry, state.stdout, state.stderr);
}

pub fn runReport(state: GlobalState, args: []const []const u8) !void {
    try report.run(state.allocator, args, state.registry, state.stdout);
}

pub fn runFairnessAnalysis(state: GlobalState, args: []const []const u8) !void {
    var corpus_path: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var format: []const u8 = "text";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--corpus") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            corpus_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            model = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            format = args[i + 1];
            i += 1;
        }
    }

    if (corpus_path == null or model == null) {
        try state.stderr.print("Error: --corpus and --model are required for fairness analysis.\n", .{});
        return error.MissingArgument;
    }

    try analytics.runFairnessAnalysis(state.allocator, corpus_path.?, model.?, format);
}

fn printUsage(w: anytype) !void {
    try w.print(
        \\llm-cost v{s}
        \\
        \\Usage:
        \\  llm-cost tokens --model [ID] [FILE]    Count tokens in a file or stdin
        \\  llm-cost price  --model [ID] [FILE]    Estimate cost for a file or stdin
        \\  llm-cost models [--json]               List supported models and prices
        \\  llm-cost check  [FILES...]             Check budget/policy (llm-cost.toml)
        \\  llm-cost pipe   [OPTIONS]              Batch process JSONL from stdin
        \\  llm-cost report [OPTIONS]              Analyze usage logs
        \\  llm-cost update-db                     Update pricing database
        \\  llm-cost version                       Show version
        \\
        \\Examples:
        \\  cat prompt.txt | llm-cost tokens --model gpt-4o
        \\  llm-cost price --model gpt-4o-mini big_prompt.txt
        \\
    , .{version_str});
}

test "imports" {
    _ = tokenizer;
    _ = Pricing;
    _ = engine;
}
