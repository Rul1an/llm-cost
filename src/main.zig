const std = @import("std");
const builtin = @import("builtin");
const tokenizer = @import("tokenizer/mod.zig");
const Pricing = @import("core/pricing/mod.zig");
const engine = @import("core/engine.zig");
const pipe = @import("pipe.zig");
const report = @import("report.zig");
const analytics = @import("analytics/mod.zig");
const check = @import("check.zig");
const init = @import("init.zig");
const manifest = @import("core/manifest.zig");
const resource_id = @import("core/resource_id.zig");
const export_cmd = @import("export.zig");
const diff_cmd = @import("diff.zig");
const context = @import("context.zig");
const estimate_cmd = @import("commands/estimate.zig");
const ci_action_cmd = @import("ci_action.zig");
const verify_cmd = @import("verify.zig");
const calibrate_cmd = @import("commands/calibrate.zig");
const update_db_cmd = @import("cli/update_db.zig");
const upgrade_cmd = @import("cli/upgrade.zig");
const verify_license_cmd = @import("cli/verify_license.zig");
const version_cmd = @import("commands/version.zig");
const args_mod = @import("cli/args.zig");
const Verbosity = @import("cli/verbosity.zig").Verbosity;

pub const version_str = "1.9.0";
pub const GlobalState = context.GlobalState;

const naked_help =
    \\llm-cost - Static cost analysis for LLM workloads
    \\
    \\Usage: llm-cost <command> [options]
    \\
    \\Commands:
    \\  estimate   Estimate cost for prompt files
    \\  check      Enforce budget/policy gates
    \\  diff       Compare costs between git refs
    \\  calibrate  Compare estimates vs actuals
    \\  export     Export FOCUS CSV for FinOps tools
    \\  update-db  Fetch latest pricing database
    \\
    \\Global flags:
    \\  -q, --quiet     Suppress progress, errors only
    \\  -v, --verbose   Full debug output
    \\  -h, --help      Show help
    \\      --version   Show version
    \\
    \\Run 'llm-cost <command> --help' for command details.
    \\
;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = std.process.argsAlloc(allocator) catch {
        std.io.getStdErr().writer().writeAll("Failed to read arguments\n") catch {};
        return 1;
    };
    defer std.process.argsFree(allocator, raw_args);

    const args = if (raw_args.len > 1) raw_args[1..] else raw_args[0..0];

    if (args.len == 0) {
        std.io.getStdOut().writer().writeAll(naked_help) catch {};
        return 0;
    }

    const parsed = args_mod.parse(allocator, args) catch |err| {
        const stderr = std.io.getStdErr().writer();
        switch (err) {
            args_mod.ParseError.UnknownCommand => stderr.writeAll("Unknown command. Run 'llm-cost --help'\n") catch {},
            args_mod.ParseError.UnknownFlag => stderr.writeAll("Unknown flag. Run 'llm-cost <command> --help'\n") catch {},
            args_mod.ParseError.MissingValue => stderr.writeAll("Missing value for flag\n") catch {},
            args_mod.ParseError.InvalidValue => stderr.writeAll("Invalid value for flag\n") catch {},
            args_mod.ParseError.ConflictingFlags => stderr.writeAll("Conflicting flags: --apply and --rollback\n") catch {},
        }
        return 2;
    };

    const verbosity = parsed.global.verbosity;
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Init minimal state for legacy commands
    // We only init registry if needed by the command?
    // main.zig previously inited registry GLOBALLY.
    // We should probably keep that behavior for legacy commands that expect GlobalState.
    // Check if command is calibrate (which handles its own registry).

    // Commands that need GlobalState: estimate, models, count, pipe, report, analyze-fairness, update-db, check, init, export, diff, ci-action, verify, upgrade, verify-license.
    // Calibrate handles its own.

    const needs_registry = switch (parsed.command) {
        .calibrate, .version, .help, .none => false,
        else => true,
    };

    var registry: ?Pricing.Registry = null;
    if (needs_registry) {
        registry = Pricing.Registry.init(allocator, .{}) catch |err| {
            // For legacy compatibility, we might just warn?
            // But existing main panicked on try? No, it used `try`.
            // So if init fails, we error out.
            stderr.print("Failed to initialize pricing registry: {s}\n", .{@errorName(err)}) catch {};
            return 1;
        };
    }
    defer if (registry) |*r| r.deinit();

    // Prepare GlobalState if needed
    const global_state = if (registry) |*r| GlobalState{
        .allocator = allocator,
        .registry = r,
        .stdout = stdout.any(),
        .stderr = stderr.any(),
    } else GlobalState{ // Dummy for commands that don't need it or use it differently
        .allocator = allocator,
        .registry = undefined, // usage would crash?
        .stdout = stdout.any(),
        .stderr = stderr.any(),
    };

    switch (parsed.command) {
        .calibrate => |cmd_args| return calibrate_cmd.run(allocator, cmd_args, verbosity, stdout) catch |err| {
            switch (err) {
                calibrate_cmd.CalibrateError.UsageError => {
                    stderr.writeAll("Error: --estimates and --actuals are required (or usage error)\n") catch {};
                    return 64;
                },
                calibrate_cmd.CalibrateError.IoError => {
                    return 74; // IO Error
                },
                else => {
                    stderr.print("Calibration failed: {s}\n", .{@errorName(err)}) catch {};
                    return 1;
                },
            }
        },
        .version => {
            stdout.print("llm-cost {s}\n", .{version_str}) catch {};
            return 0;
        },
        .help => {
            stdout.writeAll(naked_help) catch {};
            return 0;
        },
        .estimate => |cmd| {
            estimate_cmd.run(global_state, cmd.args) catch return 1;
            return 0;
        },
        .check => |cmd| {
            const code = check.run(allocator, cmd.args, global_state.registry, global_state.stdout, global_state.stderr) catch return 1;
            return @intCast(code);
        },
        .diff => |cmd| {
            diff_cmd.run(allocator, cmd.args, global_state.registry, global_state.stdout) catch return 1;
            return 0;
        },
        .update_db => |cmd| {
            const code = update_db_cmd.run(allocator, cmd.args) catch return 1;
            return @intCast(code);
        },
        .ci_action => |cmd| {
            const code = ci_action_cmd.run(global_state, cmd.args) catch return 1;
            return @intCast(code);
        },
        .@"export" => |cmd| {
            export_cmd.run(allocator, cmd.args, global_state.registry, global_state.stdout) catch return 1;
            return 0;
        },
        .init => |cmd| {
            init.run(allocator, cmd.args, std.io.getStdIn().reader(), global_state.stdout) catch return 1;
            return 0;
        },
        .pipe => |cmd| {
            pipe.run(allocator, cmd.args, global_state.registry, global_state.stdout, global_state.stderr) catch return 1;
            return 0;
        },
        .report => |cmd| {
            report.run(allocator, cmd.args, global_state.registry, global_state.stdout) catch return 1;
            return 0;
        },
        .analytics => |cmd| {
            // runFairnessAnalysis equivalent
            // Extract optional logic from old main?
            // runFairnessAnalysis(state, args)
            // args was just slice.
            runFairnessAnalysis(global_state, cmd.args) catch return 1;
            return 0;
        },
        .upgrade => |cmd| {
            const code = upgrade_cmd.run(allocator, cmd.args) catch return 1;
            return @intCast(code);
        },
        .verify => |cmd| {
            verify_cmd.run(allocator, cmd.args, global_state.stdout, global_state.stderr) catch return 1;
            return 0;
        },
        .verify_license => |cmd| {
            const code = verify_license_cmd.run(allocator, cmd.args) catch return 1;
            return @intCast(code);
        },
        .models => |cmd| {
            runModels(global_state, cmd.args) catch return 1;
            return 0;
        },
        .count => |cmd| {
            runCount(global_state, cmd.args) catch return 1;
            return 0;
        },
        .run_models => |cmd| {
            runModels(global_state, cmd.args) catch return 1;
            return 0;
        },
        .none => {
            stdout.writeAll(naked_help) catch {};
            return 0;
        },
    }
}

// Legacy helpers from main.zig retained
pub fn runModels(state: GlobalState, args: []const []const u8) !void {
    var format_json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--format=json") or std.mem.eql(u8, arg, "--json")) {
            format_json = true;
        }
    }
    var keys = std.ArrayList([]const u8).init(state.allocator);
    defer keys.deinit();
    var it = state.registry.iterator();
    while (it.next()) |entry| {
        try keys.append(entry.key);
    }
    if (keys.items.len > 1) {
        std.mem.sort([]const u8, keys.items, {}, stringLessThan);
    }
    if (format_json) {
        try state.stdout.print("[\n", .{});
        for (keys.items, 0..) |key, i| {
            const def = state.registry.get(key).?;
            const in_p = Pricing.PriceDef.toUsd(def.input_price_per_mtok);
            const out_p = Pricing.PriceDef.toUsd(def.output_price_per_mtok);
            try state.stdout.print("  {{\n", .{});
            try state.stdout.print("    \"id\": \"{s}\",\n", .{key});
            try state.stdout.print("    \"cost_in\": {d},\n", .{in_p});
            try state.stdout.print("    \"cost_out\": {d}", .{out_p});
            if (def.output_reasoning_price_per_mtok) |reas_val| {
                if (reas_val > 0) {
                    const reas_p = Pricing.PriceDef.toUsd(reas_val);
                    try state.stdout.print(",\n    \"cost_reasoning\": {d}", .{reas_p});
                }
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
            const def = state.registry.get(key).?;
            const in_p = Pricing.PriceDef.toUsd(def.input_price_per_mtok);
            const out_p = Pricing.PriceDef.toUsd(def.output_price_per_mtok);
            const reas_str = if (def.output_reasoning_price_per_mtok) |r| blk: {
                if (r > 0) {
                    break :blk try std.fmt.allocPrint(state.allocator, "${d:.2}", .{Pricing.PriceDef.toUsd(r)});
                } else {
                    break :blk "-";
                }
            } else "-";
            defer if ((def.output_reasoning_price_per_mtok orelse 0) > 0) state.allocator.free(reas_str);
            try state.stdout.print("{s:<20} ${d:<14.2} ${d:<14.2} {s:<14}\n", .{ key, in_p, out_p, reas_str });
        }
        try state.stdout.print("\nTotal models: {d}\n", .{keys.items.len});
    }
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

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
