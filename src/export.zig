const std = @import("std");
const focus = @import("core/focus/mod.zig");
const manifest = @import("core/manifest.zig");
const pricing = @import("core/pricing/mod.zig");

pub const ExportOptions = struct {
    format: Format = .focus,
    output: []const u8 = "-",
    manifest_path: []const u8 = "llm-cost.toml",
    scenario: focus.MapOptions.Scenario = .default,
    cache_hit_ratio: ?f64 = null,

    pub const Format = enum { focus };
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // 1. Parse arguments
    const options = try parseArgs(args);

    // 2. Load manifest (try default path or specified)
    // manifest.parseManifestFile is not exposed directly? We might need to handle file reading manually if not.
    // Checking manifest.zig... it usually exposes `parse` on content.
    // Let's implement robust loading here.
    const manifest_content = std.fs.cwd().readFileAlloc(allocator, options.manifest_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("Manifest file '{s}' not found. Run 'llm-cost init' first.", .{options.manifest_path});
            return error.ManifestNotFound;
        }
        return err;
    };
    defer allocator.free(manifest_content);

    var policy = try manifest.parse(allocator, manifest_content);
    defer policy.deinit(allocator);

    const prompts = policy.prompts orelse {
        std.log.err("No prompts defined in manifest '{s}'.", .{options.manifest_path});
        return error.NoPrompts;
    };
    if (prompts.len == 0) {
        std.log.err("No prompts defined in manifest '{s}'.", .{options.manifest_path});
        return error.NoPrompts;
    }

    // 3. Initialize pricing registry
    // We need a Registry instance.
    var registry_ptr = try allocator.create(pricing.Registry);
    registry_ptr.* = try pricing.Registry.init(allocator, .{});
    // In real app, we should load DB?
    // Pricing.Registry.init loads embedded. `update-db` updates cache.
    // Ideally we load from cache if available.
    // Check `main.zig` initialization logic?
    // For now, simple init.
    defer {
        registry_ptr.deinit();
        allocator.destroy(registry_ptr);
    }

    // 4. Open output (file or stdout)
    const is_stdout = std.mem.eql(u8, options.output, "-");
    const output_file = if (is_stdout)
        std.io.getStdOut()
    else
        try std.fs.cwd().createFile(options.output, .{});
    defer if (!is_stdout) output_file.close();

    // 5. Initialize CSV writer
    var csv = focus.CsvWriter.init(allocator, output_file);

    // 6. Write header
    try csv.writeHeader();

    // 7. Process each prompt
    const map_options = focus.MapOptions{
        .default_model = policy.default_model,
        .cache_hit_ratio = options.cache_hit_ratio,
        .scenario = options.scenario,
    };

    var count: usize = 0;
    for (prompts) |prompt| {
        // Read prompt content
        // Handle failure gracefully?
        const content = std.fs.cwd().readFileAlloc(allocator, prompt.path, 10 * 1024 * 1024) catch |err| {
            std.log.warn("Skipping '{s}': {}\n", .{ prompt.path, err });
            continue;
        };
        defer allocator.free(content);

        // Map to FOCUS row
        var row = try focus.mapPrompt(allocator, prompt, registry_ptr, content, map_options);
        defer row.deinit();

        // Write row
        try csv.writeRow(row);
        count += 1;
    }

    // 8. Success message (stderr only)
    if (!is_stdout) {
        std.debug.print("✓ Exported {d} prompts to {s}\n", .{ count, options.output });
    }
}

fn parseArgs(args: []const []const u8) !ExportOptions {
    var options = ExportOptions{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            if (!std.mem.eql(u8, args[i], "focus")) {
                std.log.err("Unknown format: {s}. Only 'focus' is supported.", .{args[i]});
                return error.InvalidFormat;
            }
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.output = args[i];
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.manifest_path = args[i];
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            if (std.mem.eql(u8, args[i], "cached")) {
                options.scenario = .cached;
            } else if (std.mem.eql(u8, args[i], "default")) {
                options.scenario = .default;
            } else {
                return error.InvalidScenario;
            }
        } else if (std.mem.eql(u8, arg, "--cache-hit-ratio")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.cache_hit_ratio = std.fmt.parseFloat(f64, args[i]) catch {
                std.log.err("Invalid cache-hit-ratio: {s}. Must be 0.0-1.0", .{args[i]});
                return error.InvalidCacheRatio;
            };
            if (options.cache_hit_ratio.? < 0.0 or options.cache_hit_ratio.? > 1.0) {
                std.log.err("cache-hit-ratio must be between 0.0 and 1.0", .{});
                return error.InvalidCacheRatio;
            }
        }
    }

    // Validate
    if (options.scenario == .cached and options.cache_hit_ratio == null) {
        std.log.err("--scenario cached requires --cache-hit-ratio", .{});
        return error.MissingCacheRatio;
    }

    return options;
}
