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
            std.log.warn("Skipping '{s}': Unknown model '{s}'", .{ prompt.path, model.? });
            continue;
        };

        // Token Count
        const tokenizer_config = try Engine.resolveConfig(model.?);
        const input_tokens = try Engine.countTokens(allocator, content, tokenizer_config);
        const output_tokens = 0; // Static analysis focuses on input. Output is unknown.
        // TODO: Support --output-tokens global arg or prompt tag override?
        // User spec doesn't specify how to guess output tokens for static export.
        // We assume 0 for static cost, or maybe estimation based on input?
        // Let's stick to strict input-only cost for now unless 'usage' data is available (which is not in manifest).

        // Calculate Cost
        const cost = Pricing.Registry.calculate(price_def, input_tokens, output_tokens, 0);

        // Derive Resource ID
        var rid = try ResourceId.derive(allocator, prompt.prompt_id, prompt.path, content);
        defer rid.deinit(allocator);

        // Map to FOCUS Row
        var row = try Mapper.mapContext(allocator, prompt, price_def, rid.value, model.?, cost, input_tokens, output_tokens, cache_hit_ratio, test_date);
        defer row.deinit();

        try csv.writeRow(row);
    }
}
