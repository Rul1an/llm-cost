const std = @import("std");

/// Executes a function within a temporary current working directory.
/// Restores the original CWD afterwards (though thread-safety is limited by OS).
/// Note: In Zig tests run via `zig build test`, this modifies the process CWD.
/// Use with caution in multi-threaded tests if they rely on CWD.
///
/// `func` is expected to return a result that needs specific handling or void.
/// This implementation genericizes the return type.
pub fn withTempCwd(
    allocator: std.mem.Allocator,
    target_dir: std.fs.Dir,
    comptime func: anytype,
    args: anytype,
) !@typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.payload {
    const original_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd);

    // Use an absolute path here to avoid relying on fd-based chdir semantics.
    const target_path = try target_dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_path);

    try std.posix.chdir(target_path);
    defer {
        std.posix.chdir(original_cwd) catch |e| {
            std.debug.print("Failed to restore CWD: {}\n", .{e});
        };
    }

    return @call(.auto, func, args);
}
