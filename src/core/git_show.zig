const std = @import("std");

pub const Context = struct {
    repo_dir: []const u8,
    revision: []const u8,

    pub const ReadError = error{
        NotFound,
        InvalidPath,
        GitError,
        GitCrashed,
        TooLarge,
        BadRef,
        GitNotFound,
        PathTooLong,
    } || std.mem.Allocator.Error || std.process.Child.RunError;

    fn validatePath(path: []const u8) ReadError!void {
        if (path.len == 0) return error.InvalidPath;
        if (path.len > 4096) return error.PathTooLong;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, path, ':') != null) return error.InvalidPath;

        // reject absolute paths + traversal
        if (std.fs.path.isAbsolute(path)) return error.InvalidPath;
        if (std.mem.startsWith(u8, path, "~")) return error.InvalidPath; // Home dir expansion check
        if (std.mem.indexOf(u8, path, "..") != null) return error.InvalidPath;
    }

    pub fn read(self: Context, allocator: std.mem.Allocator, path: []const u8) ReadError![]u8 {
        try validatePath(path);

        const object_spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.revision, path });
        defer allocator.free(object_spec);

        const argv = [_][]const u8{
            "git",
            "-C",
            self.repo_dir,
            "--no-pager",
            "show",
            object_spec,
        };

        // Detailed env for stability
        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        try env_map.put("LC_ALL", "C");
        try env_map.put("LANG", "C");
        try env_map.put("GIT_PAGER", "cat");
        // We probably want to keep PATH so git is found, but Child.run logic with env_map replaces it entirely by default on some platforms or implementations?
        // Zig's std.process.Child uses the provided env_map as the *entire* environment if provided.
        // We must copy PATH from current env if we want to find 'git' via PATH, OR we assume 'git' is absolute (which it isn't here).
        // A safer "SOTA" approach without reimplementing full env copy is strict inheritance or explicitly copying PATH.
        // Let's copy PATH if present.
        if (std.process.getEnvVarOwned(allocator, "PATH")) |path_val| {
            defer allocator.free(path_val);
            try env_map.put("PATH", path_val);
        } else |_| {} // PATH missing? weird but proceed.

        if (std.process.getEnvVarOwned(allocator, "HOME")) |home_val| {
            defer allocator.free(home_val);
            try env_map.put("HOME", home_val);
        } else |_| {}

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
            .env_map = &env_map,
            .max_output_bytes = 10 * 1024 * 1024, // 10MB limit
        });
        defer allocator.free(result.stderr);
        // Note: result.stdout is owned by us, caller must free (or we errdefer free it)
        errdefer allocator.free(result.stdout);

        // Safe exit code extraction (Union Check)
        const exit_code: u8 = switch (result.term) {
            .Exited => |code| @intCast(code),
            else => return error.GitCrashed,
        };

        // Check exit code
        if (exit_code != 0) {
            allocator.free(result.stdout); // Free unused output

            const err_msg = result.stderr;
            if (std.mem.indexOf(u8, err_msg, "does not exist") != null) return error.NotFound;
            if (std.mem.indexOf(u8, err_msg, "exists on disk, but not in") != null) return error.NotFound;
            if (std.mem.indexOf(u8, err_msg, "unknown revision") != null) return error.BadRef;
            if (std.mem.indexOf(u8, err_msg, "invalid object name") != null) return error.BadRef;
            if (std.mem.indexOf(u8, err_msg, "bad object") != null) return error.BadRef;
            if (std.mem.indexOf(u8, err_msg, "not a git repository") != null) return error.GitNotFound;

            return error.GitError;
        }

        return result.stdout;
    }
};

test "GitShow hermetic integration" {
    const allocator = std.testing.allocator;

    // Create temp directory for hermetic test
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo_path_buf = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(repo_path_buf);

    // Initialize git repo
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "init" }, // modern git handles init in cwd
            .cwd = repo_path_buf,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Config user (needed for commit)
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "config", "user.email", "test@example.com" },
            .cwd = repo_path_buf,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "config", "user.name", "Test User" },
            .cwd = repo_path_buf,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Write file
    try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = "Found Me!" });

    // Add and commit
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{ "git", "add", "test.txt" }, .cwd = repo_path_buf });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{ "git", "commit", "-m", "init" }, .cwd = repo_path_buf });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Test GitShow
    const ctx = Context{
        .repo_dir = repo_path_buf,
        .revision = "HEAD",
    };

    // 1. Valid Read
    const content = try ctx.read(allocator, "test.txt");
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Found Me!", content);

    // 2. Not Found
    try std.testing.expectError(error.NotFound, ctx.read(allocator, "missing.txt"));

    // 3. Validation
    try std.testing.expectError(error.InvalidPath, ctx.read(allocator, "foo:bar"));
    try std.testing.expectError(error.InvalidPath, ctx.read(allocator, "../secret"));
}
