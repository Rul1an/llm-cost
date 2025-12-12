const std = @import("std");
const resource_id = @import("core/resource_id.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, stdin: anytype, stdout: anytype) !void {
    // 1. Parse Args
    var non_interactive = false;
    var root_dir_path: []const u8 = ".";

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--non-interactive")) {
            non_interactive = true;
        } else if (std.mem.startsWith(u8, arg, "--dir=")) {
            root_dir_path = arg[6..];
        }
    }

    // 2. Discover Prompts
    try stdout.print("Discovering prompts in '{s}'...\n", .{root_dir_path});

    var found_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (found_paths.items) |p| allocator.free(p);
        found_paths.deinit();
    }

    // Recursive Walk
    var dir = std.fs.cwd().openDir(root_dir_path, .{ .iterate = true }) catch |err| {
        try stdout.print("Error opening directory: {}\n", .{err});
        return;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Filter by extension (simple policy for now)
        if (std.mem.endsWith(u8, entry.path, ".txt") or
            std.mem.endsWith(u8, entry.path, ".md") or
            std.mem.endsWith(u8, entry.path, ".prompt"))
        {
            // Ignore hidden files / git
            if (std.mem.startsWith(u8, entry.path, ".") or std.mem.indexOf(u8, entry.path, ".git") != null) continue;

            const full_path = if (std.mem.eql(u8, root_dir_path, "."))
                try allocator.dupe(u8, entry.path)
            else
                try std.fs.path.join(allocator, &[_][]const u8{ root_dir_path, entry.path });

            try found_paths.append(full_path);
        }
    }

    if (found_paths.items.len == 0) {
        try stdout.print("No prompt files found (.txt, .md, .prompt).\n", .{});
        return;
    }

    try stdout.print("Found {} potential prompt files.\n\n", .{found_paths.items.len});

    // 3. Propose Configuration
    // Build a list of proposed items (path, id)
    const Proposal = struct {
        path: []const u8,
        id: []const u8,
    };
    var proposals = std.ArrayList(Proposal).init(allocator);
    defer {
        for (proposals.items) |p| allocator.free(p.id); // path is owned by found_paths, don't free here
        proposals.deinit();
    }

    // Deduplication set for IDs
    var used_ids = std.StringHashMap(void).init(allocator);
    defer used_ids.deinit();

    for (found_paths.items) |path| {
        // Simple slugify
        const initial_slug = try resource_id.slugify(allocator, path);
        // Check collision (very basic logic: append -1, -2 etc. or just warn)
        // resource_id.zig doesn't expose dedup logic yet (I put it in spec but implementation might be minimal)
        // Let's implement basic suffixing here if conflict

        var candidate = initial_slug;
        var suffix: usize = 1;
        while (used_ids.contains(candidate)) {
            // Collision
            // Create new candidate with suffix
            const old_candidate = candidate;
            candidate = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ initial_slug, suffix });
            if (suffix > 1) allocator.free(old_candidate); // free intermediate loops, initial_slug handled by defer below if needed? NO wait.
            // if suffix==1, candidate was initial_slug. We shouldn't free initial_slug yet.
            // Let's handle memory clearer.
            suffix += 1;
        }

        // If we looped, initial_slug is still alloc'd but not used in map. We should free it if distinct from candidate.
        if (candidate.ptr != initial_slug.ptr) {
            allocator.free(initial_slug);
        }

        try used_ids.put(candidate, {});
        try proposals.append(Proposal{ .path = path, .id = candidate });
    }

    // 4. Interactive Confirm
    if (!non_interactive) {
        try stdout.print("Proposed Configuration:\n", .{});
        for (proposals.items) |p| {
            try stdout.print("  [path] {s:<30} [id] {s}\n", .{ p.path, p.id });
        }

        try stdout.print("\nGenerate llm-cost.toml with these IDs? [Y/n] ", .{});
        var buf: [10]u8 = undefined;
        if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
            const trimmed = std.mem.trim(u8, input, " \r\t");
            if (!std.mem.eql(u8, trimmed, "") and !std.mem.eql(u8, trimmed, "y") and !std.mem.eql(u8, trimmed, "Y")) {
                try stdout.print("Aborted.\n", .{});
                return;
            }
        }
    }

    // 5. Generate TOML
    const file_file = std.fs.cwd().createFile("llm-cost.toml", .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            try stdout.print("Error: llm-cost.toml already exists. Use --force to overwrite (not impl yet) or delete it.\n", .{});
            return;
        }
        return err;
    };
    defer file_file.close();
    var writer = file_file.writer();

    try writer.writeAll(
        \\# llm-cost.toml
        \\# Generated by llm-cost init
        \\
        \\[defaults]
        \\model = "gpt-4o"
        \\
        \\[budget]
        \\max_cost_usd = 10.00
        \\warn_threshold = 0.80
        \\
        \\[policy]
        \\allowed_models = ["gpt-4o", "gpt-4o-mini", "claude-3-5-sonnet"]
        \\
        \\
    );

    for (proposals.items) |p| {
        try writer.print(
            \\[[prompts]]
            \\path = "{s}"
            \\prompt_id = "{s}"
            \\
            \\
        , .{ p.path, p.id });
    }

    try stdout.print("✓ Created llm-cost.toml with {} prompts.\n", .{proposals.items.len});
}
