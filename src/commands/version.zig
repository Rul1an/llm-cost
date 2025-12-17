const std = @import("std");
const builtin = @import("builtin");

pub fn run(allocator: std.mem.Allocator, current_version: []const u8, stdout: anytype) !void {
    const build_mode = if (builtin.mode == .Debug) " (Debug)" else "";
    try stdout.print("llm-cost {s}{s}\n", .{ current_version, build_mode });

    // Fire-and-forget update check
    // We intentionally ignore errors here to not block the user
    checkUpdate(allocator, current_version, stdout) catch {};
}

fn checkUpdate(allocator: std.mem.Allocator, current_version: []const u8, stdout: anytype) !void {
    const latest = try fetchLatestVersion(allocator);
    defer allocator.free(latest);

    // If versions differ (simple string compare for now, acceptable for v-prefixed tags)
    // Ideally we should use SemVer parsing but this is a "hint"
    if (!std.mem.eql(u8, latest, current_version)) {
        try stdout.print(
            \\
            \\💡 Update available: {s} → {s}
            \\   Run: curl -sSfL https://get.llm-cost.dev | sh
            \\
        , .{ current_version, latest });
    }
}

fn fetchLatestVersion(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Check Cache
    const cache_path = try getCachePath(allocator);
    defer allocator.free(cache_path);

    if (readCache(allocator, cache_path)) |cached| {
        defer allocator.free(cached.version);
        // 24h cache
        const now = std.time.timestamp();
        if (now - cached.timestamp < 24 * 3600) {
            return try allocator.dupe(u8, cached.version);
        }
    } else |_| {}

    // 2. Fetch from GitHub (Timeout 2s)
    // We use a simple child process to curl/wget if available to avoid full HTTP stack dependency here
    // Or we use std.http.Client if available in Zig 0.14
    // Given we are already using std.http elsewhere, let's try that, but minimal.
    // Actually, spawning `curl` with a timeout is safer/easier for a "hint" feature in a CLI tool without async.

    const version = try fetchCurl(allocator);

    // 3. Write Cache
    writeCache(cache_path, version) catch {};

    return version;
}

fn fetchCurl(allocator: std.mem.Allocator) ![]u8 {
    // curl -s -m 2 https://api.github.com/repos/Rul1an/llm-cost/releases/latest | grep tag_name
    // A bit hacky but extremely robust and doesn't bloat the binary

    const argv = [_][]const u8{ "curl", "-s", "-m", "2", "https://api.github.com/repos/Rul1an/llm-cost/releases/latest" };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) return error.NetworkError;

    // Parse JSON manually to find "tag_name": "v1.2.3"
    // We scan for "tag_name"
    const haystack = result.stdout;
    if (std.mem.indexOf(u8, haystack, "\"tag_name\"")) |start| {
        const after = haystack[start..];
        if (std.mem.indexOf(u8, after, ":")) |colon| {
            var val_start = colon + 1;
            while (val_start < after.len and (after[val_start] == ' ' or after[val_start] == '"')) : (val_start += 1) {}

            var val_end = val_start;
            while (val_end < after.len and after[val_end] != '"' and after[val_end] != ',') : (val_end += 1) {}

            if (val_end > val_start) {
                const raw_ver = after[val_start..val_end];
                // Strip input v if present, user compares against 1.2.2 usually
                if (std.mem.startsWith(u8, raw_ver, "v")) {
                    return try allocator.dupe(u8, raw_ver[1..]);
                }
                return try allocator.dupe(u8, raw_ver);
            }
        }
    }

    return error.NotFound;
}

fn getCachePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
    defer allocator.free(home);

    const path = try std.fs.path.join(allocator, &.{ home, ".cache", "llm-cost", "update_check" });
    return path;
}

const CacheEntry = struct {
    timestamp: i64,
    version: []const u8,
};

fn readCache(allocator: std.mem.Allocator, path: []const u8) !CacheEntry {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    var timestamp: i64 = 0;
    var version: []const u8 = "";

    var it = std.mem.tokenizeScalar(u8, content, '\n');
    if (it.next()) |ts_str| {
        timestamp = std.fmt.parseInt(i64, ts_str, 10) catch 0;
    }
    if (it.next()) |ver| {
        version = try allocator.dupe(u8, ver);
    } else {
        return error.InvalidCache;
    }

    return CacheEntry{ .timestamp = timestamp, .version = version };
}

fn writeCache(path: []const u8, version: []const u8) !void {
    const dirname = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dirname);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const w = file.writer();
    try w.print("{d}\n{s}", .{ std.time.timestamp(), version });
}
