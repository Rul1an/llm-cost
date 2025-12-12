const std = @import("std");

pub const TestEnv = struct {
    tmp: std.testing.TmpDir,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestEnv {
        return .{ .tmp = std.testing.tmpDir(.{}), .allocator = allocator };
    }

    pub fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
    }

    /// Create file inside tmp dir; returns relative path (safe if you chdir into tmp)
    pub fn write(self: *TestEnv, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(.{ .sub_path = rel, .data = data });
    }
};
