const std = @import("std");

/// Helper struct to manage a temporary test environment with files.
pub const TestEnv = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,

    pub fn init(allocator: std.mem.Allocator) TestEnv {
        return .{
            .allocator = allocator,
            .tmp = std.testing.tmpDir(.{}),
        };
    }

    pub fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
    }

    /// Write data to a file inside the temp directory.
    pub fn write(self: *TestEnv, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }

    /// Get absolute path to a file inside the temp directory.
    /// Caller owns the returned memory.
    pub fn realpathAlloc(self: *TestEnv, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.realpathAlloc(self.allocator, sub_path);
    }
};
