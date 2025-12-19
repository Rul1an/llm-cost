const std = @import("std");
const Verbosity = @import("verbosity.zig").Verbosity;

pub const Logger = struct {
    verbosity: Verbosity,
    stderr: std.fs.File.Writer,

    const Self = @This();

    pub fn init(verbosity: Verbosity) Self {
        return .{
            .verbosity = verbosity,
            .stderr = std.io.getStdErr().writer(),
        };
    }

    /// Debug output (--verbose only)
    pub fn debug(self: Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.verbosity.shouldShowDebug()) return;
        self.stderr.print("[DEBUG] " ++ fmt ++ "\n", args) catch {};
    }

    /// Info output (normal + verbose)
    pub fn info(self: Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.verbosity.shouldShowSummary()) return;
        self.stderr.print(fmt ++ "\n", args) catch {};
    }

    /// Warning output (always, except quiet)
    pub fn warn(self: Self, comptime fmt: []const u8, args: anytype) void {
        if (self.verbosity == .quiet) return;
        self.stderr.print("⚠️  " ++ fmt ++ "\n", args) catch {};
    }

    /// Error output (always)
    pub fn err(self: Self, comptime fmt: []const u8, args: anytype) void {
        self.stderr.print("❌ " ++ fmt ++ "\n", args) catch {};
    }
};
