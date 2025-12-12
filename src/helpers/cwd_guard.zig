const std = @import("std");

pub var g_cwd_mutex: std.Thread.Mutex = .{};

pub fn withTempCwd(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    comptime F: anytype,
    args: anytype,
) !void {
    g_cwd_mutex.lock();
    defer g_cwd_mutex.unlock();

    const old = try std.process.getCwdAlloc(allocator);
    defer allocator.free(old);
    defer std.process.changeCurDir(old) catch {};

    // Use changeCurDir with realpath of handle because we can't easily setAsCwd from dir handle portably in all zig versions
    // But we can get the path from the dir handle
    const path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    try std.process.changeCurDir(path);

    return @call(.auto, F, args);
}
