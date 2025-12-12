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
    var manifest_found = false;
    const cwd = std.fs.cwd();

    if (cwd.readFileAlloc(allocator, "llm-cost.toml", 1024 * 1024)) |content| {
        defer allocator.free(content);
        policy = try manifest.parse(allocator, content);
        manifest_found = true;
    } else |_| {}
    defer policy.deinit(allocator);

    // 2. Parse CLI Args for Overrides/Inputs
    var cli_model: ?[]const u8 = null;
    var cli_inputs = std.ArrayList([]const u8).init(allocator);
    defer cli_inputs.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                cli_model = args[i + 1];
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try cli_inputs.append(arg);
        }
    }

    // 3. Check Policy: Allowed Models (Global Check on CLI overrides)
    if (cli_model) |cm| {
        if (policy.allowed_models) |allowed| {
            var allowed_found = false;
            for (allowed) |m| {
                if (std.mem.eql(u8, m, cm)) {
                    allowed_found = true;
                    break;
                }
            }
            if (!allowed_found) {
                try stderr.print("POLICY VIOLATION: Model '{s}' (CLI arg) is not permitted.\n", .{cm});
                return @intFromEnum(ExitCode.PolicyViolation);
            }
        }
    }

    // 4. Calculate Total Cost
    var total_cost: f64 = 0.0;
    var prompts_checked: usize = 0;

    // Helper to process a single file
    const ProcessFileContext = struct {
        path: []const u8,
        model: []const u8, // Effective model
        is_manifest: bool,
        prompt_id: ?[]const u8,
    };

    var work_list = std.ArrayList(ProcessFileContext).init(allocator);
    defer work_list.deinit();

    // A. Add Manifest Prompts
    if (policy.prompts) |manifest_prompts| {
        for (manifest_prompts) |p| {
            const effective_model = p.model orelse policy.default_model orelse cli_model orelse "gpt-4o";

            // Check Allowed Models (Per Prompt)
            if (policy.allowed_models) |allowed| {
                var allowed_found = false;
                for (allowed) |m| {
                    if (std.mem.eql(u8, m, effective_model)) {
                        allowed_found = true;
                        break;
                    }
                }
                if (!allowed_found) {
                   try stderr.print("POLICY VIOLATION: Model '{s}' for prompt '{s}' is not permitted.\n", .{effective_model, p.path});
                   return @intFromEnum(ExitCode.PolicyViolation);
                }
            }

            // Validation: Prompt ID
            if (p.prompt_id == null) {
                 try stderr.print("⚠️  {s} has no prompt_id (will use path slug for FOCUS)\n", .{p.path});
            }

            try work_list.append(.{
                .path = p.path,
                .model = effective_model,
                .is_manifest = true,
                .prompt_id = p.prompt_id,
            });
        }
    }

    // B. Add CLI Inputs
    for (cli_inputs.items) |path| {
        const effective_model = cli_model orelse policy.default_model orelse "gpt-4o";
        // Check Allowed Models for CLI inputs
         if (policy.allowed_models) |allowed| {
            var allowed_found = false;
            for (allowed) |m| {
                if (std.mem.eql(u8, m, effective_model)) {
                    allowed_found = true;
                    break;
                }
            }
            if (!allowed_found) {
               try stderr.print("POLICY VIOLATION: Model '{s}' for file '{s}' is not permitted.\n", .{effective_model, path});
               return @intFromEnum(ExitCode.PolicyViolation);
            }
        }

        try work_list.append(.{
            .path = path,
            .model = effective_model,
            .is_manifest = false,
            .prompt_id = null,
        });
    }

    // Warn if no manifest and using CLI args (Soft Check)
    if (!manifest_found and cli_inputs.items.len > 0) {
        // Just a hint, not strict
        // try stderr.print("Hint: Run 'llm-cost init' to create a manifest for better governance.\n", .{});
    }

    if (work_list.items.len == 0) {
       try stderr.print("No prompts to check. Specify files or configure llm-cost.toml.\n", .{});
       return @intFromEnum(ExitCode.Error);
    }

    // Execution Loop
    for (work_list.items) |item| {
        const tokenizer_config = try engine.resolveConfig(item.model);
        const price_def = registry.get(item.model);

        if (price_def == null) {
            try stderr.print("Warning: Model '{s}' not found. Cost is $0.00.\n", .{item.model});
        }

        const content = cwd.readFileAlloc(allocator, item.path, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error reading {s}: {s}\n", .{ item.path, @errorName(err) });
            return @intFromEnum(ExitCode.Error);
        };
        defer allocator.free(content);

        const tokens = try engine.countTokens(allocator, content, tokenizer_config);

        if (price_def) |def| {
            total_cost += Pricing.Registry.calculate(def, tokens, 0, 0);
        }
        prompts_checked += 1;
    }

    // 5. Evaluate Budget
    try stdout.print("✓ {} prompts validated\n", .{prompts_checked});

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
