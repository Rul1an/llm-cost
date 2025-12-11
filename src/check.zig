const std = @import("std");
const manifest = @import("core/manifest.zig");
const engine = @import("core/engine.zig");
const Pricing = @import("core/pricing/mod.zig");

pub const ExitCode = enum(u8) {
    Ok = 0,
    Error = 1,
    BudgetExceeded = 2,
    PolicyViolation = 3,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    registry: *const Pricing.Registry,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    // 1. Load Policy (llm-cost.toml)
    var policy = manifest.Policy{};
    const cwd = std.fs.cwd();

    // Probeer config te laden, faal niet als hij mist (tenzij we strict mode willen later)
    if (cwd.readFileAlloc(allocator, "llm-cost.toml", 1024 * 1024)) |content| {
        defer allocator.free(content);
        policy = try manifest.parse(allocator, content);
    } else |_| {
        // Geen config? Geen regels. Ga door.
    }
    defer policy.deinit(allocator);

    // 2. Scan Inputs
    var total_cost: f64 = 0.0;

    // Simplificatie v0.9: We gebruiken gpt-4o als basis voor budget checks
    // tenzij we --model flag parsen uit args.
    var model_name: []const u8 = "gpt-4o";
    var input_files = std.ArrayList([]const u8).init(allocator);
    defer input_files.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                model_name = args[i + 1];
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try input_files.append(arg);
        }
    }

    // 3. Check Policy: Allowed Models
    if (policy.allowed_models) |allowed| {
        var allowed_found = false;
        for (allowed) |m| {
            if (std.mem.eql(u8, m, model_name)) {
                allowed_found = true;
                break;
            }
        }
        if (!allowed_found) {
            try stderr.print("POLICY VIOLATION: Model '{s}' is not permitted by llm-cost.toml.\n", .{model_name});
            try stderr.print("Allowed: ", .{});
            for (allowed) |m| try stderr.print("'{s}' ", .{m});
            try stderr.print("\n", .{});
            return @intFromEnum(ExitCode.PolicyViolation);
        }
    }

    // 4. Calculate Total Cost
    const tokenizer_config = try engine.resolveConfig(model_name);
    const price_def = registry.get(model_name);

    if (price_def == null) {
        try stderr.print("Warning: Model '{s}' not found in registry. Cost is $0.00.\n", .{model_name});
    }

    for (input_files.items) |file_path| {
        const content = cwd.readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error reading {s}: {s}\n", .{ file_path, @errorName(err) });
            return @intFromEnum(ExitCode.Error);
        };
        defer allocator.free(content);

        const tokens = try engine.countTokens(allocator, content, tokenizer_config);

        if (price_def) |def| {
            // Check only assumes INPUT cost for budget guarding
            total_cost += Pricing.Registry.calculate(def, tokens, 0, 0);
        }
    }

    // 5. Evaluate Budget
    if (policy.max_cost_usd) |limit| {
        const percent = (total_cost / limit) * 100.0;
        try stdout.print("Budget Usage: ${d:.4} / ${d:.4} ({d:.1}%)\n", .{ total_cost, limit, percent });

        if (total_cost > limit) {
            try stderr.print("BUDGET EXCEEDED: Cost ${d:.4} exceeds limit ${d:.4}\n", .{ total_cost, limit });
            return @intFromEnum(ExitCode.BudgetExceeded);
        }
    } else {
        try stdout.print("Total Est. Cost: ${d:.4} (No budget limit set)\n", .{total_cost});
    }

    return @intFromEnum(ExitCode.Ok);
}
