const std = @import("std");
const context = @import("../context.zig");
const Pricing = @import("../core/pricing/mod.zig");
const engine = @import("../core/engine.zig");
const manifest = @import("../core/manifest.zig");
const resource_id = @import("../core/resource_id.zig");

pub fn run(state: context.GlobalState, args: []const []const u8) !void {
    var model_name: []const u8 = "gpt-4o";
    var input_tokens_arg: ?u64 = null;
    var output_tokens_arg: ?u64 = null;
    var reasoning_tokens_arg: u64 = 0;
    var format_json = false;
    var input_files = std.ArrayList([]const u8).init(state.allocator);
    defer input_files.deinit();

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
        } else if (std.mem.eql(u8, arg, "--format=json") or std.mem.eql(u8, arg, "--json")) {
            format_json = true;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            // Allow pass-through for ci-action
            // We might implement manifest scanning here if needed, but for now just skip strict check since ci-action handles it
            // Actually, if we want `runEstimate` to support --manifest logic (scanning manifest for prompts), we need to implement it.
            // The User Request said: "Zorg dat runEstimate de combinatie --format=json --manifest <path> zonder files ondersteunt (manifest-scan)."
            // So I should implement that here.
            if (i + 1 >= args.len) return error.MissingArgument;
            // We store manifest path but we also need to know if we are scanning.
            // For now, let's just parse it.
            // If input_files is empty, and manifest provided, we scan?
            // The ci_action uses main_app logic which assumes prompt scanning.
            // But `main.zig` logic I copied DOES NOT have manifest scanning yet!
            // It only uses manifest for Resource ID resolution.
            // I need to ADD logic to iterate manifest prompts if no files provided.
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try input_files.append(arg);
        }
    }

    // Logic Upgrade: If --manifest is passed, we might want to run on all files in manifest.
    // Let's check if --manifest <path> was in args.
    // Re-parsing to find manifest arg
    var manifest_path: ?[]const u8 = null;
    {
        var k: usize = 0;
        while (k < args.len) : (k += 1) {
            if (std.mem.eql(u8, args[k], "--manifest") and k + 1 < args.len) {
                manifest_path = args[k + 1];
                break;
            }
        }
    }

    // Load Manifest (for ResourceID resolution AND potentially for file list)
    var policy = manifest.Policy{};
    const fs_manifest_path = manifest_path orelse "llm-cost.toml";

    const cwd = std.fs.cwd();
    if (cwd.readFileAlloc(state.allocator, fs_manifest_path, 1024 * 1024)) |content| {
        defer state.allocator.free(content);
        policy = try manifest.parse(state.allocator, content);
    } else |_| {}
    defer policy.deinit(state.allocator);

    const price_def = state.registry.get(model_name) orelse {
        try state.stderr.print("Error: Unknown model '{s}'. Run 'llm-cost models' to list available models.\n", .{model_name});
        // std.process.exit is not ideal in library code, but copying main.zig logic:
        return error.UnknownModel;
    };

    var total_cost: f64 = 0.0;

    // JSON Output Structures
    const PromptResult = struct {
        path: []const u8,
        resource_id: []const u8,
        resource_id_source: []const u8,
        model: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        cost_usd: f64,
    };
    var results = std.ArrayList(PromptResult).init(state.allocator);
    defer results.deinit();

    // Determine Input Sources
    // 1. Explicit Files
    // 2. STDIN (if no files, no manifest-scan, no manual tokens)
    // 3. Manifest Scan (if no files, but manifest exists and we want to scan?)
    // The requirement says: "Zorg dat runEstimate de combinatie --format=json --manifest <path> zonder files ondersteunt"

    // If input_files is empty AND input_tokens_arg is null AND manifest has prompts:
    // We treat it as "Run on all prompts in manifest".

    var final_files = std.ArrayList([]const u8).init(state.allocator);
    defer final_files.deinit();

    var use_stdin = false;
    var is_manifest_scan = false;

    if (input_files.items.len > 0) {
        try final_files.appendSlice(input_files.items);
    } else if (input_tokens_arg != null) {
        // Manual mode
    } else if (policy.prompts != null and policy.prompts.?.len > 0 and manifest_path != null) {
        // Implicit Manifest Scan if explicit manifest path provided
        is_manifest_scan = true;
        for (policy.prompts.?) |p| {
            try final_files.append(p.path);
        }
    } else {
        use_stdin = true;
    }

    if (use_stdin) {
        // Read from STDIN
        const input_text = try std.io.getStdIn().readToEndAlloc(state.allocator, 1024 * 1024 * 10);
        defer state.allocator.free(input_text);

        var token_count: u64 = 0;
        if (input_text.len > 0) {
            const tokenizer_config = try engine.resolveConfig(model_name);
            token_count = try engine.countTokens(state.allocator, input_text, tokenizer_config);
        }

        const cost = Pricing.Registry.calculate(price_def, token_count, output_tokens_arg orelse 0, reasoning_tokens_arg);
        total_cost += cost;

        // ResourceID for STDIN
        var rid = try resource_id.derive(state.allocator, null, null, input_text);
        defer rid.deinit(state.allocator);

        if (format_json) {
            try results.append(.{
                .path = "stdin",
                .resource_id = try state.allocator.dupe(u8, rid.value),
                .resource_id_source = @tagName(rid.source),
                .model = model_name,
                .input_tokens = token_count,
                .output_tokens = output_tokens_arg orelse 0,
                .cost_usd = cost,
            });
        } else {
            try state.stdout.print("Model:       {s}\n", .{model_name});
            try state.stdout.print("Tokens In:   {d}\n", .{token_count});
            if ((output_tokens_arg orelse 0) > 0) try state.stdout.print("Tokens Out:  {d}\n", .{output_tokens_arg orelse 0});
            try state.stdout.print("Cost (est):  ${d:.6}\n", .{cost});
            try state.stdout.print("Resource ID: {s} ({s})\n", .{ rid.value, @tagName(rid.source) });
        }
    } else if (input_tokens_arg != null) {
        // Manual mode
        const cost = Pricing.Registry.calculate(price_def, input_tokens_arg.?, output_tokens_arg orelse 0, reasoning_tokens_arg);
        total_cost += cost;
        if (!format_json) {
            try state.stdout.print("Cost (est):  ${d:.6}\n", .{cost});
        } else {
            try results.append(.{
                .path = "manual-tokens",
                .resource_id = "manual",
                .resource_id_source = "manual",
                .model = model_name,
                .input_tokens = input_tokens_arg.?,
                .output_tokens = output_tokens_arg orelse 0,
                .cost_usd = cost,
            });
        }
    } else {
        // Process Files (Explicit or Scanned)
        for (final_files.items) |path| {
            // Read file
            const content = cwd.readFileAlloc(state.allocator, path, 10 * 1024 * 1024) catch |err| {
                try state.stderr.print("Error reading {s}: {s}\n", .{ path, @errorName(err) });
                continue;
            };
            defer state.allocator.free(content);

            const tokenizer_config = try engine.resolveConfig(model_name);
            const token_count = try engine.countTokens(state.allocator, content, tokenizer_config);
            const cost = Pricing.Registry.calculate(price_def, token_count, output_tokens_arg orelse 0, reasoning_tokens_arg);
            total_cost += cost;

            // ResourceID Resolution
            var manifest_id: ?[]const u8 = null;
            if (policy.prompts) |prompts| {
                for (prompts) |p| {
                    if (std.mem.eql(u8, p.path, path)) {
                        manifest_id = p.prompt_id;
                        break;
                    }
                }
            }

            var rid = try resource_id.derive(state.allocator, manifest_id, path, content);

            if (format_json) {
                try results.append(.{
                    .path = path,
                    .resource_id = try state.allocator.dupe(u8, rid.value),
                    .resource_id_source = @tagName(rid.source),
                    .model = model_name,
                    .input_tokens = token_count,
                    .output_tokens = output_tokens_arg orelse 0,
                    .cost_usd = cost,
                });
            } else {
                if (is_manifest_scan) {
                    // Quieter output for scan? Or same?
                    try state.stdout.print("{s}: ${d:.6} ({s})\n", .{ path, cost, rid.value });
                } else {
                    try state.stdout.print("File:        {s}\n", .{path});
                    try state.stdout.print("Tokens In:   {d}\n", .{token_count});
                    try state.stdout.print("Cost (est):  ${d:.6}\n", .{cost});
                    try state.stdout.print("Resource ID: {s} ({s})\n\n", .{ rid.value, @tagName(rid.source) });
                }
            }
            rid.deinit(state.allocator);
        }
    }

    if (format_json) {
        // Spec 1.1: Sort prompts by resource_id ASC
        const SortCtx = struct {
            pub fn lessThan(_: void, a: PromptResult, b: PromptResult) bool {
                return std.mem.order(u8, a.resource_id, b.resource_id) == .lt;
            }
        };
        std.mem.sort(PromptResult, results.items, {}, SortCtx.lessThan);

        const CanonicalJsonWriter = @import("../core/json_canonical.zig").CanonicalJsonWriter;

        try state.stdout.writeAll("{\n  \"prompts\": [\n");
        for (results.items, 0..) |res, idx| {
            try state.stdout.writeAll("    ");

            var jw = CanonicalJsonWriter.init(state.allocator);
            defer jw.deinit();

            try jw.putString("path", res.path);
            try jw.putString("resource_id", res.resource_id);
            try jw.putString("resource_id_source", res.resource_id_source);
            try jw.putString("model", res.model);
            try jw.putInt("input_tokens", res.input_tokens);
            try jw.putInt("output_tokens", res.output_tokens);

            // Fixed precision for cost (ensure it is a JSON Number, not string)
            // Buffer for "123.456789"
            var cost_buf: [32]u8 = undefined;
            const cost_s = try std.fmt.bufPrint(&cost_buf, "{d:.6}", .{res.cost_usd});
            try jw.put("cost_usd", cost_s);

            try jw.write(state.stdout);

            if (idx < results.items.len - 1) try state.stdout.writeAll(",\n") else try state.stdout.writeAll("\n");

            if (!std.mem.eql(u8, res.resource_id, "manual")) state.allocator.free(res.resource_id);
        }
        try state.stdout.writeAll("  ],\n");

        // Summary
        try state.stdout.writeAll("  \"summary\": ");
        {
            var jw = CanonicalJsonWriter.init(state.allocator);
            defer jw.deinit();

            var cost_buf: [32]u8 = undefined;
            const cost_s = try std.fmt.bufPrint(&cost_buf, "{d:.6}", .{total_cost});
            try jw.put("total_cost_usd", cost_s);

            try jw.write(state.stdout);
        }
        try state.stdout.writeAll("\n}\n");
    } else if (input_files.items.len > 1 or is_manifest_scan) {
        try state.stdout.print("Total Cost:  ${d:.6}\n", .{total_cost});
    }
}
