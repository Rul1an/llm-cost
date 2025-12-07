const std = @import("std");

/// Read entire content from a file descriptor into a managed slice.
/// Senior implementation: handles EINTR/EAGAIN (conceptually) via std.posix.read.
pub fn readAllFromFd(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    var buf: [4096]u8 = undefined;

    while (true) {
        // std.posix.read handles basic safe wrapping.
        // EINTR logic is usually platform specific, but std.posix tries to abstract.
        // We use catch to handle non-fatal vs fatal.
        const n = std.posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock, error.Blocked => continue, // Busy wait or just retry? Usually these won't happen on blocking FDs.
            error.SystemResources => return err,
            else => return err,
        };

        if (n == 0) break; // EOF
        try list.appendSlice(buf[0..n]);
    }

    return list.toOwnedSlice();
}

/// Helper to read all from STDIN.
pub fn readStdinAll(allocator: std.mem.Allocator) ![]u8 {
    return readAllFromFd(allocator, std.posix.STDIN_FILENO);
}

/// Helper to read all from a file path.
pub fn readFileAll(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    // Open for reading.
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    return readAllFromFd(allocator, file.handle);
}

/// Write bytes to STDOUT (blocking).
pub fn writeStdout(bytes: []const u8) !void {
    try std.posix.writeAll(std.posix.STDOUT_FILENO, bytes);
}

/// Write bytes to STDERR (blocking).
pub fn writeStderr(bytes: []const u8) !void {
    try std.posix.writeAll(std.posix.STDERR_FILENO, bytes);
}
