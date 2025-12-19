const std = @import("std");
const Verbosity = @import("verbosity.zig").Verbosity;

pub const Progress = struct {
    total: usize,
    current: usize,
    label: []const u8,
    writer: std.fs.File.Writer,
    enabled: bool,
    last_pct: u8,
    start_time: i64,

    const Self = @This();

    pub fn init(
        label: []const u8,
        total: usize,
        verbosity: Verbosity,
    ) Self {
        const stderr = std.io.getStdErr();
        const is_tty = stderr.isTty();
        const enabled = is_tty and verbosity.shouldShowProgress();

        return .{
            .total = total,
            .current = 0,
            .label = label,
            .writer = stderr.writer(),
            .enabled = enabled,
            .last_pct = 0,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn update(self: *Self, current: usize) void {
        if (!self.enabled) return;

        self.current = current;

        // Calculate percentage
        const pct: u8 = if (self.total == 0)
            100
        else
            @intCast(@min(100, @divTrunc(@as(u128, current) * 100, self.total)));

        // Only redraw on percentage change (reduce flicker)
        if (pct == self.last_pct and pct != 100) return;
        self.last_pct = pct;

        // Format: "Parsing actuals... 42% (847K/2M)"
        const current_k = @divTrunc(current, 1000);
        const total_k = @divTrunc(self.total, 1000);

        self.writer.print("\r\x1b[K{s}... {d}% ({d}K/{d}K)", .{
            self.label,
            pct,
            current_k,
            total_k,
        }) catch {};
    }

    pub fn finish(self: *Self) void {
        if (!self.enabled) return;

        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        // Clear line and print final status
        self.writer.print("\r\x1b[K{s}... done ({d:.1}s)\n", .{
            self.label,
            elapsed_s,
        }) catch {};
    }

    pub fn fail(self: *Self, reason: []const u8) void {
        if (!self.enabled) return;

        self.writer.print("\r\x1b[K{s}... failed: {s}\n", .{
            self.label,
            reason,
        }) catch {};
    }
};

/// Simple spinner for indeterminate progress
pub const Spinner = struct {
    label: []const u8,
    writer: std.fs.File.Writer,
    enabled: bool,
    frame: u8,
    start_time: i64,

    const Self = @This();
    const frames = [_]u8{ '|', '/', '-', '\\' };

    pub fn init(label: []const u8, verbosity: Verbosity) Self {
        const stderr = std.io.getStdErr();
        const is_tty = stderr.isTty();
        const enabled = is_tty and verbosity.shouldShowProgress();

        var self = Self{
            .label = label,
            .writer = stderr.writer(),
            .enabled = enabled,
            .frame = 0,
            .start_time = std.time.milliTimestamp(),
        };

        // Show initial state
        if (enabled) {
            self.writer.print("{s}... {c}", .{ label, frames[0] }) catch {};
        }

        return self;
    }

    pub fn tick(self: *Self) void {
        if (!self.enabled) return;

        self.frame = (self.frame + 1) % frames.len;
        self.writer.print("\r{s}... {c}", .{ self.label, frames[self.frame] }) catch {};
    }

    pub fn finish(self: *Self) void {
        if (!self.enabled) return;

        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        self.writer.print("\r\x1b[K{s}... done ({d:.1}s)\n", .{
            self.label,
            elapsed_s,
        }) catch {};
    }
};
