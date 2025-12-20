const std = @import("std");
const manifest = @import("core/manifest.zig");
const engine = @import("core/engine.zig");
const Pricing = @import("core/pricing/mod.zig");
const agentic = @import("governance/agentic.zig");
const focus = @import("calibration/focus_import.zig");
const tag_resolver = @import("calibration/tag_resolver.zig");

const Verbosity = @import("cli/verbosity.zig").Verbosity;

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
    verbosity: Verbosity,
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
    var cli_actuals: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--actuals")) {
            if (i + 1 < args.len) {
                cli_actuals = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("Usage: llm-cost check [OPTIONS] [FILES...]\n", .{});
            try stdout.print("Options:\n", .{});
            try stdout.print("  --model, -m <MODEL>   Override model\n", .{});
            try stdout.print("  --actuals <FILE>      Check agentic rules against FOCUS CSV\n", .{});
            return @intFromEnum(ExitCode.Ok);
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
    var total_cost: i128 = 0;
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
                    try stderr.print("POLICY VIOLATION: Model '{s}' for prompt '{s}' is not permitted.\n", .{ effective_model, p.path });
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
                try stderr.print("POLICY VIOLATION: Model '{s}' for file '{s}' is not permitted.\n", .{ effective_model, path });
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
            const cost = Pricing.Registry.calculate(def, tokens, 0, 0);
            total_cost = std.math.add(i128, total_cost, cost) catch return error.Overflow;
        }
        prompts_checked += 1;
    }

    // 5. Evaluate Budget
    if (verbosity != .quiet) {
        if (prompts_checked == 1) {
            try stdout.print("✓ {} prompt validated\n", .{prompts_checked});
        } else {
            try stdout.print("✓ {} prompts validated\n", .{prompts_checked});
        }
    }

    const total_usd = Pricing.PriceDef.toUsd(total_cost);

    if (policy.max_cost_usd) |limit| {
        const percent = (total_usd / limit) * 100.0;
        if (verbosity != .quiet) {
            try stdout.print("Budget Usage: ${d:.4} / ${d:.4} ({d:.1}%)\n", .{ total_usd, limit, percent });
        }

        if (total_usd > limit) {
            try stderr.print("BUDGET EXCEEDED: Cost ${d:.4} exceeds limit ${d:.4}\n", .{ total_usd, limit });
            return @intFromEnum(ExitCode.BudgetExceeded);
        }
    } else {
        if (verbosity != .quiet) {
            try stdout.print("Total Est. Cost: ${d:.4} (No budget limit set)\n", .{total_usd});
        }
    }

    // 6. Agentic Governance Checks
    if (cli_actuals) |actuals_path| {
        const f = cwd.openFile(actuals_path, .{}) catch |e| {
            try stderr.print("Error opening actuals: {s} ({s})\n", .{ actuals_path, @errorName(e) });
            return @intFromEnum(ExitCode.Error);
        };
        defer f.close();

        var parser = try focus.FocusParser.initFromReader(allocator, f.reader(), 10 * 1024 * 1024);
        defer parser.deinit();

        var records = std.ArrayList(focus.FocusRecord).init(allocator);
        defer {
            for (records.items) |*r| {
                allocator.free(r.UsageUnit);
                allocator.free(r.ChargeCategory);
                allocator.free(r.ResourceId);
                if (r.InvoiceIssuerName) |s| allocator.free(s);
                if (r.@"x-llm-model") |s| allocator.free(s);
                var it = r.tags.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                r.tags.deinit();
            }
            records.deinit();
        }

        while (try parser.next()) |rec| {
            var copy = rec;
            copy.UsageUnit = try allocator.dupe(u8, rec.UsageUnit);
            copy.ChargeCategory = try allocator.dupe(u8, rec.ChargeCategory);
            copy.ResourceId = try allocator.dupe(u8, rec.ResourceId);
            if (rec.InvoiceIssuerName) |s| copy.InvoiceIssuerName = try allocator.dupe(u8, s);
            if (rec.@"x-llm-model") |s| copy.@"x-llm-model" = try allocator.dupe(u8, s);

            copy.tags = std.StringHashMap([]const u8).init(allocator);
            var it = rec.tags.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                const v = try allocator.dupe(u8, entry.value_ptr.*);
                try copy.tags.put(k, v);
            }
            try records.append(copy);
        }

        var resolver = try tag_resolver.Resolver.init(allocator, policy.tags);
        defer resolver.deinit();

        const violations = try agentic.checkRules(allocator, policy.agentic, &resolver, registry, records.items, actuals_path);
        defer {
            for (violations) |v| {
                allocator.free(v.message);
                if (v.run_id) |s| allocator.free(s);
                if (v.tool) |s| allocator.free(s);
                if (v.model) |s| allocator.free(s);
            }
            allocator.free(violations);
        }

        if (violations.len > 0) {
            var errors: u32 = 0;
            for (violations) |v| {
                const label = if (v.severity == .@"error") "ERROR" else "WARN";
                try stderr.print("[{s}] {s}: {s}\n", .{ label, @tagName(v.rule), v.message });
                if (v.severity == .@"error") errors += 1;
            }

            if (errors > 0) {
                return @intFromEnum(ExitCode.Error);
            }
        } else {
            if (verbosity != .quiet) {
                try stdout.print("✓ Agentic governance passed ({} records)\n", .{records.items.len});
            }
        }
    }

    // 6. Agentic Governance Checks
    if (cli_actuals) |actuals_path| {
        const f = cwd.openFile(actuals_path, .{}) catch |e| {
            try stderr.print("Error opening actuals: {s} ({s})\n", .{ actuals_path, @errorName(e) });
            return @intFromEnum(ExitCode.Error);
        };
        defer f.close();

        var parser = try focus.FocusParser.initFromReader(allocator, f.reader(), 10 * 1024 * 1024);
        defer parser.deinit();

        var records = std.ArrayList(focus.FocusRecord).init(allocator);
        defer {
            for (records.items) |*r| {
                allocator.free(r.UsageUnit);
                allocator.free(r.ChargeCategory);
                allocator.free(r.ResourceId);
                if (r.InvoiceIssuerName) |s| allocator.free(s);
                if (r.@"x-llm-model") |s| allocator.free(s);
                var it = r.tags.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                r.tags.deinit();
            }
            records.deinit();
        }

        while (try parser.next()) |rec| {
            var copy = rec;
            copy.UsageUnit = try allocator.dupe(u8, rec.UsageUnit);
            copy.ChargeCategory = try allocator.dupe(u8, rec.ChargeCategory);
            copy.ResourceId = try allocator.dupe(u8, rec.ResourceId);
            if (rec.InvoiceIssuerName) |s| copy.InvoiceIssuerName = try allocator.dupe(u8, s);
            if (rec.@"x-llm-model") |s| copy.@"x-llm-model" = try allocator.dupe(u8, s);

            copy.tags = std.StringHashMap([]const u8).init(allocator);
            var it = rec.tags.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                const v = try allocator.dupe(u8, entry.value_ptr.*);
                try copy.tags.put(k, v);
            }
            try records.append(copy);
        }

        var resolver = try tag_resolver.Resolver.init(allocator, policy.tags);
        defer resolver.deinit();

        const violations = try agentic.checkRules(allocator, policy.agentic, &resolver, registry, records.items, actuals_path);
        defer {
            for (violations) |v| {
                allocator.free(v.message);
                if (v.run_id) |s| allocator.free(s);
                if (v.tool) |s| allocator.free(s);
                if (v.model) |s| allocator.free(s);
            }
            allocator.free(violations);
        }

        if (violations.len > 0) {
            var errors: u32 = 0;
            for (violations) |v| {
                const label = if (v.severity == .@"error") "ERROR" else "WARN";
                try stderr.print("[{s}] {s}: {s}\n", .{ label, @tagName(v.rule), v.message });
                if (v.severity == .@"error") errors += 1;
            }

            if (errors > 0) {
                return @intFromEnum(ExitCode.Error);
            }
        } else {
            if (verbosity != .quiet) {
                try stdout.print("✓ Agentic governance passed ({} records)\n", .{records.items.len});
            }
        }
    }

    return @intFromEnum(ExitCode.Ok);
}
