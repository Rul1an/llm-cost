const std = @import("std");
const FileProvider = @import("core/file_provider.zig");
const Manifest = @import("core/manifest.zig");
const Pricing = @import("core/pricing/mod.zig");
const DeltaModel = @import("core/delta.zig");
const Engine = @import("core/engine.zig");

pub fn computeDeltas(
    allocator: std.mem.Allocator,
    base_provider: FileProvider.Provider,
    head_provider: FileProvider.Provider,
    manifest_path: []const u8,
    registry: *const Pricing.Registry,
) ![]DeltaModel.CostDelta {
    const base_content = base_provider.read(allocator, manifest_path) catch |err| {
        if (err == error.NotFound) return &[_]DeltaModel.CostDelta{};
        return &[_]DeltaModel.CostDelta{};
    };
    defer allocator.free(base_content);

    var base_policy = try Manifest.parse(allocator, base_content);
    defer base_policy.deinit(allocator);

    const head_content = try head_provider.read(allocator, manifest_path);
    defer allocator.free(head_content);

    var head_policy = try Manifest.parse(allocator, head_content);
    defer head_policy.deinit(allocator);

    var deltas = std.ArrayList(DeltaModel.CostDelta).init(allocator);
    errdefer {
        for (deltas.items) |*d| {
            allocator.free(d.resource_id);
            allocator.free(d.file_path);
        }
        deltas.deinit();
    }

    var base_prompts = std.StringHashMap(Manifest.PromptDef).init(allocator);
    defer base_prompts.deinit();
    if (base_policy.prompts) |prompts| {
        for (prompts) |p| try base_prompts.put(p.path, p);
    }

    var head_prompts = std.StringHashMap(Manifest.PromptDef).init(allocator);
    defer head_prompts.deinit();
    if (head_policy.prompts) |prompts| {
        for (prompts) |p| try head_prompts.put(p.path, p);
    }

    var it = head_prompts.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const head_p = entry.value_ptr.*;

        const head_cost = try calculateCost(allocator, head_provider, head_p, registry);

        var base_cost: ?i128 = null;
        if (base_prompts.get(path)) |base_p| {
            base_cost = try calculateCost(allocator, base_provider, base_p, registry);
            _ = base_prompts.remove(path); // Mark as processed
        }

        // OWNERSHIP FIX: Duplicate path and prompt_id because head_policy will be destroyed
        const owned_path = try allocator.dupe(u8, path);
        const owned_rid = try allocator.dupe(u8, head_p.prompt_id orelse path);

        // head_cost is present (not null), base_cost is optional
        const delta = DeltaModel.CostDelta.init(base_cost, head_cost, owned_path, owned_rid);
        try deltas.append(delta);
    }

    var base_it = base_prompts.iterator();
    while (base_it.next()) |entry| {
        const path = entry.key_ptr.*;
        const base_p = entry.value_ptr.*;

        const base_cost = try calculateCost(allocator, base_provider, base_p, registry);
        // Head cost is null (Removed)

        const owned_path = try allocator.dupe(u8, path);
        const owned_rid = try allocator.dupe(u8, base_p.prompt_id orelse path);

        const delta = DeltaModel.CostDelta.init(base_cost, null, owned_path, owned_rid);
        try deltas.append(delta);
    }

    std.mem.sort(DeltaModel.CostDelta, deltas.items, {}, DeltaModel.CostDelta.lessThan);

    return deltas.toOwnedSlice();
}

fn calculateCost(
    allocator: std.mem.Allocator,
    provider: FileProvider.Provider,
    prompt: Manifest.PromptDef,
    registry: *const Pricing.Registry,
) !i128 {
    // Read content
    const content = provider.read(allocator, prompt.path) catch |err| {
        if (err == error.NotFound) return 0;
        return err;
    };
    defer allocator.free(content);

    // Determine model
    // TODO: Respect [defaults] from Policy.
    // Right now manifest parser extracts [defaults], but we need to pass it down.
    // For now, prompt.model is used or fallback.
    const model_id = prompt.model orelse "gpt-4o";

    // Count tokens
    const cfg = try Engine.resolveConfig(model_id);
    const tokens = try Engine.countTokens(allocator, content, cfg);

    // Calculate Price
    const price_def = registry.get(model_id) orelse return 0;

    // We only know input tokens from static analysis
    const cost_usd = Pricing.Registry.calculate(price_def, tokens, 0, 0);

    // Convert to pico-USD (i128)
    const scale: f64 = 1_000_000_000_000.0;
    return @intFromFloat(@round(cost_usd * scale));
}

// --- Formatter ---

pub fn formatTable(allocator: std.mem.Allocator, deltas: []const DeltaModel.CostDelta, writer: anytype) !void {
    _ = allocator;
    try writer.writeAll("Status    | Resource ID | Delta ($) | Base ($) | Head ($)\n");
    try writer.writeAll("----------|-------------|-----------|----------|---------\n");

    for (deltas) |d| {
        const status_sym = switch (d.status) {
            .increased => "INCREASED",
            .added => "ADDED    ",
            .decreased => "DECREASED",
            .removed => "REMOVED  ",
            .unchanged => "UNCHANGED",
        };

        // Convert to USD strings (naive div 1e12)
        const delta_f = @as(f64, @floatFromInt(d.delta)) / 1e12;

        // Handle Optionals: if null, print "-"
        const base_f = if (d.base_cost) |c| @as(f64, @floatFromInt(c)) / 1e12 else 0.0;
        const head_f = if (d.head_cost) |c| @as(f64, @floatFromInt(c)) / 1e12 else 0.0;

        // Use a small buffer to format optional strings if we wanted strict alignment,
        // but for now printing 0.000000 is okay for numeric columns,
        // or we can print distinct placeholder.
        // Requested: differentiate 0 vs null.
        // Let's print "-" if null.

        try writer.print("{s} | {s} | {d:.6} | ", .{ status_sym, d.resource_id, delta_f });

        if (d.base_cost) |_| {
            try writer.print("{d:.6} | ", .{base_f});
        } else {
            try writer.print("{s:>8} | ", .{"-"});
        }

        if (d.head_cost) |_| {
            try writer.print("{d:.6}\n", .{head_f});
        } else {
            try writer.print("{s:>8}\n", .{"-"});
        }
    }
}

pub fn formatJson(allocator: std.mem.Allocator, deltas: []const DeltaModel.CostDelta, writer: anytype) !void {
    const CanonicalJsonWriter = @import("core/json_canonical.zig").CanonicalJsonWriter;

    try writer.writeAll("{\n  \"deltas\": [\n");
    for (deltas, 0..) |d, i| {
        // Indent for array items
        try writer.writeAll("    ");

        var jw = CanonicalJsonWriter.init(allocator);
        defer jw.deinit();

        try jw.putString("resource_id", d.resource_id);
        try jw.putString("path", d.file_path);
        try jw.putString("status", @tagName(d.status));
        try jw.putInt("delta", d.delta);

        // Optional costs
        if (d.base_cost) |c| try jw.putInt("base_cost", c) else try jw.put("base_cost", "null");

        if (d.head_cost) |c| try jw.putInt("head_cost", c) else try jw.put("head_cost", "null");

        try jw.write(writer);

        if (i < deltas.len - 1) try writer.writeAll(",\n") else try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n}\n");
}

pub fn formatMarkdown(allocator: std.mem.Allocator, deltas: []const DeltaModel.CostDelta, writer: anytype) !void {
    _ = allocator;
    // Markdown Table similar to text but with styling hooks if needed
    try writer.writeAll("| Status | Resource ID | Delta ($) | Base ($) | Head ($) |\n");
    try writer.writeAll("| :--- | :--- | :---: | :---: | :---: |\n");

    for (deltas) |d| {
        const icon = switch (d.status) {
            .increased => "🔴 INCREASED",
            .added => "🟡 ADDED",
            .decreased => "🟢 DECREASED",
            .removed => "⚪️ REMOVED",
            .unchanged => "UNCHANGED",
        };

        const delta_f = @as(f64, @floatFromInt(d.delta)) / 1e12;
        const base_f = if (d.base_cost) |c| @as(f64, @floatFromInt(c)) / 1e12 else 0.0;
        const head_f = if (d.head_cost) |c| @as(f64, @floatFromInt(c)) / 1e12 else 0.0;

        try writer.print("| {s} | `{s}` | `{d:.6}` | ", .{ icon, d.resource_id, delta_f });

        if (d.base_cost) |_| try writer.print("`{d:.6}` | ", .{base_f}) else try writer.writeAll("- | ");
        if (d.head_cost) |_| try writer.print("`{d:.6}` |", .{head_f}) else try writer.writeAll("- |");
        try writer.writeAll("\n");
    }
}

// Minimal CLI logic
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    registry: *const Pricing.Registry,
    stdout: std.io.AnyWriter,
) !void {
    var base_ref: ?[]const u8 = null;
    var head_ref: ?[]const u8 = null;
    var manifest_path: []const u8 = "llm-cost.toml";
    var format: []const u8 = "table";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--base")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            base_ref = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--head")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            head_ref = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            manifest_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            format = args[i + 1];
            i += 1;
        }
    }

    if (base_ref == null) {
        try stdout.writeAll("Error: --base <ref> is required.\n");
        return error.MissingArgument;
    }

    const base_provider = FileProvider.Provider{
        .git_show = .{ .repo_dir = ".", .revision = base_ref.? },
    };

    const head_provider = if (head_ref) |ref|
        FileProvider.Provider{ .git_show = .{ .repo_dir = ".", .revision = ref } }
    else
        FileProvider.Provider{ .filesystem = .{} };

    const deltas = try computeDeltas(allocator, base_provider, head_provider, manifest_path, registry);

    // Free deltas and their owned strings
    defer {
        for (deltas) |*d| {
            allocator.free(d.resource_id);
            allocator.free(d.file_path);
        }
        allocator.free(deltas);
    }

    // Dispatch
    if (std.mem.eql(u8, format, "json")) {
        try formatJson(allocator, deltas, stdout);
    } else if (std.mem.eql(u8, format, "markdown")) {
        try formatMarkdown(allocator, deltas, stdout);
    } else {
        try formatTable(allocator, deltas, stdout);
    }
}

test "diff command table format" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const deltas = &[_]DeltaModel.CostDelta{
        DeltaModel.CostDelta.init(null, 5000000000000, "added.txt", "added"), // Added (+5)
        DeltaModel.CostDelta.init(1000000000000, 2000000000000, "mod.txt", "mod"), // Mod (+1)
        DeltaModel.CostDelta.init(1000000000000, null, "removed.txt", "removed"), // Removed
    };

    try formatTable(allocator, deltas, buf.writer());

    const output = buf.items;

    // Verify output format
    // Added: Base should be "-"
    try std.testing.expect(std.mem.indexOf(u8, output, "ADDED     | added | 5.000000 |        - | 5.000000") != null);

    // Mod: Base 1.0, Head 2.0
    try std.testing.expect(std.mem.indexOf(u8, output, "INCREASED | mod | 1.000000 | 1.000000 | 2.000000") != null);

    // Removed: Head should be "-"
    try std.testing.expect(std.mem.indexOf(u8, output, "REMOVED   | removed | -1.000000 | 1.000000 |        -") != null);
}
