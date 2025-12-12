const std = @import("std");
const builtin = @import("builtin");
const Pricing = @import("core/pricing/mod.zig"); // For verify()

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args; // No args for now

    // 1. Determine Cache Path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try getCachePath(&path_buf, allocator) orelse {
        std.log.err("Could not determine cache directory (XDG_CACHE_HOME/HOME/LOCALAPPDATA missing).", .{});
        return error.NoCacheDir;
    };

    // Ensure directory exists
    try std.fs.cwd().makePath(cache_path);
    var dir = try std.fs.cwd().openDir(cache_path, .{});
    defer dir.close();

    std.debug.print("Updating pricing database in: {s}\n", .{cache_path});

    // 2. Setup HTTP Client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 3. Download Files
    const db_url = "https://prices.llm-cost.dev/pricing_db.json";
    const sig_url = "https://prices.llm-cost.dev/pricing_db.json.sig";

    // Use a strict timeout/limit for security
    const db_body = fetch(allocator, &client, db_url) catch |err| {
        std.log.err("Failed to download database: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(db_body);

    const sig_body = fetch(allocator, &client, sig_url) catch |err| {
        std.log.err("Failed to download signature: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(sig_body);

    std.debug.print("Downloaded database ({d} bytes) and signature ({d} bytes).\n", .{ db_body.len, sig_body.len });

    // 4. Verify Integrity (Security First)
    std.debug.print("Verifying signature... ", .{});
    Pricing.Crypto.verify(allocator, db_body, sig_body) catch |err| {
        std.debug.print("FAILED!\n", .{});
        std.log.err("Security Integrity Check Failed: {s}", .{@errorName(err)});
        std.log.err("The downloaded update is invalid or tampered with. Aborting update.", .{});
        return err;
    };
    std.debug.print("OK.\n", .{});

    // 5. Atomic Write (Write tmp -> Rename)
    try atomicWrite(dir, "pricing_db.json", db_body);
    try atomicWrite(dir, "pricing_db.json.sig", sig_body);

    std.debug.print("Successfully updated pricing database.\n", .{});
}

fn fetch(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);
    var buf: [4096]u8 = undefined;

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &buf,
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpFailed;
    }

    // specific max size (e.g., 10MB) to prevent DoS
    const max_size = 10 * 1024 * 1024;
    return try req.reader().readAllAlloc(allocator, max_size);
}

fn atomicWrite(dir: std.fs.Dir, filename: []const u8, content: []const u8) !void {
    // 1. Write to .tmp file
    const tmp_filename = "update.tmp";

    const file = try dir.createFile(tmp_filename, .{});
    defer file.close();

    try file.writeAll(content);

    // 2. Rename .tmp to final filename (Atomic)
    try dir.rename(tmp_filename, filename);
}

// Duplicate of getCachePath logic for now
fn getCachePath(buf: []u8, allocator: std.mem.Allocator) !?[]const u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("XDG_CACHE_HOME")) |xdg| {
        return try std.fmt.bufPrint(buf, "{s}/llm-cost", .{xdg});
    }
    if (env_map.get("HOME")) |home| {
        return try std.fmt.bufPrint(buf, "{s}/.cache/llm-cost", .{home});
    }
    if (builtin.os.tag == .windows) {
        if (env_map.get("LOCALAPPDATA")) |appdata| {
            return try std.fmt.bufPrint(buf, "{s}\\llm-cost", .{appdata});
        }
    }
    return null;
}
