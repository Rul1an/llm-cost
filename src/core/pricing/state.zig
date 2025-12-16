const std = @import("std");
const json = std.json;
const paths = @import("paths.zig");

pub const UpdateState = struct {
    highest_version_seen: u64 = 0,
    last_successful_update: ?i64 = null,
    last_checked: i64 = 0,
    etag: ?[]const u8 = null,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.etag) |e| allocator.free(e);
    }

    /// Loads state from state.json in the cache directory.
    /// If file or directory doesn't exist, returns default state.
    pub fn load(allocator: std.mem.Allocator) !Self {
        const cache_path = try paths.getCacheDir(allocator);
        defer allocator.free(cache_path);

        var dir = std.fs.openDirAbsolute(cache_path, .{}) catch |err| {
            if (err == error.FileNotFound) return Self{};
            return err;
        };
        defer dir.close();

        const file = dir.openFile("state.json", .{}) catch |err| {
            if (err == error.FileNotFound) return Self{};
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Parse with duplicate strings to own memory if needed (etag)
        // But json.parseFromSlice usually references slice.
        // We need to adhere to Self definition. 'etag' is []const u8.
        // If we want it to own, verify allocator usage.
        var parsed = try json.parseFromSlice(Self, allocator, content, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        // Deep copy strings since 'content' will be freed
        // The parser allocated strings with 'allocator' because of .alloc_always?
        // Yes, likely. But we need to verify.
        // Actually, let's keep it simple: manual deep copy if needed.
        // Or better: use a struct that copies manually.

        var state = parsed.value;
        if (state.etag) |e| {
            state.etag = try allocator.dupe(u8, e);
        }
        return state;
    }

    /// Saves state to state.json using atomic temp file renaming.
    pub fn save(self: *const Self, allocator: std.mem.Allocator) !void {
        const cache_path = try paths.getCacheDir(allocator);
        defer allocator.free(cache_path);

        // 1. Ensure cache dir exists
        std.fs.makeDirAbsolute(cache_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var dir = try std.fs.openDirAbsolute(cache_path, .{});
        defer dir.close();

        // 2. Write to temp file
        const tmp_name = "state.json.tmp";
        const file = try dir.createFile(tmp_name, .{});
        defer file.close();

        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        try json.stringify(self, .{ .whitespace = .minified }, list.writer());
        try file.writeAll(list.items);

        // 3. Rename atomic
        try dir.rename(tmp_name, "state.json");
    }

    pub fn recordSuccess(self: *Self, version: u64, now: i64) void {
        if (version > self.highest_version_seen) {
            self.highest_version_seen = version;
        }
        self.last_successful_update = now;
        self.last_checked = now;
    }
};
