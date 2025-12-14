const std = @import("std");
const Manifest = @import("core/manifest.zig");
const Pricing = @import("core/pricing/mod.zig");
const Engine = @import("core/engine.zig");
const ResourceId = @import("core/resource_id.zig");
const Schema = @import("core/focus/schema.zig");
const Csv = @import("core/focus/csv.zig");
const Mapper = @import("core/focus/mapper.zig");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    registry: *Pricing.Registry,
    stdout: std.io.AnyWriter,
) !void {
    var output_path: ?[]const u8 = null;
    var manifest_path: []const u8 = "llm-cost.toml";
    var cache_hit_ratio: ?f64 = null;

    var test_date: ?[]const u8 = null;
    var format_json: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            output_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            manifest_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cache-hit-ratio")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            cache_hit_ratio = std.fmt.parseFloat(f64, args[i + 1]) catch return error.InvalidArgument;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--test-date")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            test_date = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format=json") or std.mem.eql(u8, arg, "--json")) {
            format_json = true;
        }
    }

    // 1. Load Manifest
    const cwd = std.fs.cwd();
    const manifest_content = cwd.readFileAlloc(allocator, manifest_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("Error: Manifest '{s}' not found. Run 'llm-cost init' first or specify --manifest.\n", .{manifest_path});
            return error.ManifestNotFound;
        }
        return err;
    };
    defer allocator.free(manifest_content);

    var policy = try Manifest.parse(allocator, manifest_content);
    defer policy.deinit(allocator);

    const prompts = policy.prompts orelse {
        try stdout.print("Warning: No prompts found in manifest.\n", .{});
        return;
    };

    // 2. Setup Output
    var file: ?std.fs.File = null;
    defer if (file) |f| f.close();

    var stream = stdout; // Default to stdout
    if (output_path) |path| {
        file = try cwd.createFile(path, .{});
        stream = file.?.writer().any();
    }

    var csv = Csv.CsvWriter.init(allocator, stream);
    try csv.writeHeader();

    // Buffer rows for sorting (Determinism)
    var rows = std.ArrayList(Schema.FocusRow).init(allocator);
    defer {
        for (rows.items) |*row| {
            row.deinit();
        }
        rows.deinit();
    }

    // 3. Process Prompts
    for (prompts) |prompt| {
        // Read prompt content relative to CWD (or manifest dir? Assuming CWD per spec)
        const content = cwd.readFileAlloc(allocator, prompt.path, 100 * 1024 * 1024) catch |err| {
            std.log.warn("Skipping '{s}': {s}", .{ prompt.path, @errorName(err) });
            continue;
        };
        defer allocator.free(content);

        // Resolve Model
        // Priority: prompt.model > default_model > "gpt-4o"
        var model = prompt.model;
        if (model == null) model = policy.default_model;
        if (model == null) model = "gpt-4o";

        // Validate Model exists
        const price_def = registry.get(model.?) orelse {
            // 3. Negative Values (Refunds)
            // Est: -100, Act: -90. (Received less refund than expected -> Cost "Drift" relative to baseline?)
            // Math: (-90 - (-100)) / -100 = 10 / -100 = -10%.
            std.log.warn("Skipping '{s}': Unknown model '{s}'", .{ prompt.path, model.? });
            continue;
        };

        // Token Count
        const tokenizer_config = try Engine.resolveConfig(model.?);
        const input_tokens = try Engine.countTokens(allocator, content, tokenizer_config);
        const output_tokens = 0; // Static analysis focuses on input. Output is unknown.

        // Calculate Cost
        const cost = Pricing.Registry.calculate(price_def, input_tokens, output_tokens, 0);

        // Derive Resource ID
        var rid = try ResourceId.derive(allocator, prompt.prompt_id, prompt.path, content);
        defer rid.deinit(allocator);

        // Map to FOCUS Row
        const row = try Mapper.mapContext(allocator, prompt, price_def, rid.value, model.?, cost, input_tokens, output_tokens, cache_hit_ratio, test_date);
        // Ownership transferred to 'rows' list
        try rows.append(row);
    }

    // 4. Sort Rows (Deterministic Output)
    // Sort by: ChargePeriodStart, ResourceId, ServiceName
    std.mem.sort(Schema.FocusRow, rows.items, {}, sortRows);

    // 5. Write Sorted Rows
    // If format is CSV
    if (!format_json) {
        for (rows.items) |row| {
            try csv.writeRow(row);
        }
    } else {
        // Write JSON Map: { "ResourceId": { "cost": X, "model": "Y", "scenario": "Z" } }
        // We iterate sorted rows to maintain determinism in map order (though JSON maps are unordered logically,
        // byte-for-byte output matters).
        try stream.print("{{\n", .{});
        for (rows.items, 0..) |row, idx| {
            // Extract model/scenario from tags
            // Tags is a JSON string. We don't want to double-parse if possible,
            // but FocusRow.tags.model is available in the struct if we kept the `Tags` struct?
            // FocusRow struct has `tags: Tags` struct, not string!
            // Wait, look at schema.zig: `tags: Tags` struct.
            // But MapContext creates it.
            // Let's verify if `row.tags` is accessible.

            // row is `Schema.FocusRow`.
            // field `tags` is `Tags` struct.
            // `Tags` has `model`, `user_tags` (scenario?).

            var scenario: []const u8 = "chat"; // Default for now if not found?
            if (row.tags.user_tags.get("scenario")) |s| {
                scenario = s;
            }

            // Cost is formatted string in `billed_cost`.
            // We need raw micro-usd integer for calibration accuracy?
            // `row.billed_cost` is string "0.001500".
            // `calibrate` can parse floats.

            // We need to parse billed_cost string back to number OR use the original calculation if we had it.
            // We don't have original cost here easily.
            // Let's output cost as number (from string parse).
            // Cost is formatted string in `billed_cost`.
            // We parse as float then convert to micro-USD.
            // TODO: Use fixed-point parsing to avoid potential float precision loss for large numbers.
            const cost_f = std.fmt.parseFloat(f64, row.billed_cost) catch 0;
            const cost_micro = @as(i64, @intFromFloat(cost_f * 1_000_000));

            try stream.print("  \"{s}\": {{\n", .{row.resource_id});
            try stream.print("    \"cost\": {d},\n", .{cost_micro});
            try stream.print("    \"model\": \"{s}\",\n", .{row.tags.model});
            try stream.print("    \"scenario\": \"{s}\"\n", .{scenario});

            if (idx < rows.items.len - 1) {
                try stream.print("  }},\n", .{});
            } else {
                try stream.print("  }}\n", .{});
            }
        }
        try stream.print("}}\n", .{});
    }
}

fn sortRows(_: void, lhs: Schema.FocusRow, rhs: Schema.FocusRow) bool {
    const period_order = std.mem.order(u8, lhs.charge_period_start, rhs.charge_period_start);
    if (period_order != .eq) return period_order == .lt;

    const rid_order = std.mem.order(u8, lhs.resource_id, rhs.resource_id);
    if (rid_order != .eq) return rid_order == .lt;

    const service_order = std.mem.order(u8, lhs.service_name, rhs.service_name);
    return service_order == .lt;
}
