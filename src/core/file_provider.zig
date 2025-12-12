const std = @import("std");
const GitShow = @import("git_show.zig");

pub const ProviderType = enum {
    filesystem,
    git_show,
};

pub const FsContext = struct {
    repo_dir: []const u8 = ".",
};

pub const Provider = union(ProviderType) {
    filesystem: FsContext,
    git_show: GitShow.Context,

    pub fn read(self: Provider, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        switch (self) {
            .filesystem => |ctx| {
                var dir = std.fs.cwd().openDir(ctx.repo_dir, .{}) catch |err| {
                    if (err == error.FileNotFound) return error.NotFound;
                    return err;
                };
                defer dir.close();

                const f = dir.openFile(path, .{}) catch |err| {
                    if (err == error.FileNotFound) return error.NotFound;
                    return err;
                };
                defer f.close();
                // Max size check could be added here or by caller, but for prompt files 10MB is generous.
                return f.readToEndAlloc(allocator, 10 * 1024 * 1024);
            },
            .git_show => |ctx| {
                return ctx.read(allocator, path);
            },
        }
    }
};

test "FileProvider filesystem read" {
    const allocator = std.testing.allocator;
    const provider = Provider{ .filesystem = .{ .repo_dir = "." } };

    // Read README.md
    const content = try provider.read(allocator, "README.md");
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "# llm-cost") != null);
}

test "FileProvider git_show delegation" {
    // Just ensure it compiles and dispatches
    // Note: this test requires git installed
    const allocator = std.testing.allocator;
    const ctx = GitShow.Context{ .repo_dir = ".", .revision = "HEAD" };
    const provider = Provider{ .git_show = ctx };

    const content = try provider.read(allocator, "README.md");
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "# llm-cost") != null);
}
