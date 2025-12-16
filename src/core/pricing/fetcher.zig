const std = @import("std");

pub const FetchError = error{
    NetworkUnreachable,
    Timeout,
    ServerError,
    RateLimited,
    InvalidResponse,
    TooLarge,
    OutOfMemory,
    UriParseError,
    // Header errors
    HeaderTooLarge,
};

pub const FetchResult = struct {
    data: []const u8,
    status: std.http.Status,
    etag: ?[]const u8,

    pub fn deinit(self: *FetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        if (self.etag) |e| allocator.free(e);
    }
};

pub const FetchOptions = struct {
    max_size: usize = 10 * 1024 * 1024, // 10 MB default
    auth_token: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
};

/// Fetch URL content using std.http.Client.
/// Primary strategy: Use Zig's native HTTP client (no external deps).
pub fn fetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchOptions,
) FetchError!FetchResult {
    const uri = std.Uri.parse(url) catch return error.UriParseError;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Fix: In Zig 0.14, headers buffer might be needed
    // Fix: In Zig 0.14, headers buffer might be needed
    var buf: [4096]u8 = undefined;

    // Prepare extra headers (If-None-Match)
    var extra_headers_buf: [1]std.http.Header = undefined;
    var extra_headers: []const std.http.Header = &[0]std.http.Header{};
    if (options.if_none_match) |etag| {
        extra_headers_buf[0] = .{ .name = "If-None-Match", .value = etag };
        extra_headers = &extra_headers_buf;
    }

    var req = client.open(.GET, uri, .{
        .server_header_buffer = &buf,
        .extra_headers = extra_headers,
        // TODO: Timeouts?
    }) catch return error.NetworkUnreachable;
    defer req.deinit();

    if (options.auth_token) |token| {
        // "Authorization: Bearer <token>"
        var auth_buf: [256]u8 = undefined;
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.OutOfMemory;
        req.headers.authorization = .{ .override = auth_val };
    }

    req.send() catch return error.NetworkUnreachable;
    req.wait() catch return error.NetworkUnreachable;

    const status = req.response.status;

    // Check status
    switch (status) {
        .ok, .not_modified => {},
        .too_many_requests => return error.RateLimited,
        .internal_server_error, .bad_gateway, .service_unavailable => return error.ServerError,
        else => if (@intFromEnum(status) >= 400) return error.ServerError,
    }

    // Capture ETag
    var etag: ?[]const u8 = null;
    var it = req.response.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "ETag")) {
            etag = try allocator.dupe(u8, header.value);
            break;
        }
    }
    errdefer if (etag) |e| allocator.free(e);

    // Read Body
    const body = req.reader().readAllAlloc(allocator, options.max_size) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        else => return error.NetworkUnreachable,
    };
    errdefer allocator.free(body);

    return FetchResult{
        .data = body,
        .status = status,
        .etag = etag,
    };
}

/// Fetch URL content and stream to file.
pub fn fetchToFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    writer: anytype,
    options: FetchOptions,
) FetchError!struct { status: std.http.Status, etag: ?[]const u8 } {
    const uri = std.Uri.parse(url) catch return error.UriParseError;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    // Prepare extra headers (If-None-Match)
    var extra_headers_buf: [1]std.http.Header = undefined;
    var extra_headers: []const std.http.Header = &[0]std.http.Header{};
    if (options.if_none_match) |etag| {
        extra_headers_buf[0] = .{ .name = "If-None-Match", .value = etag };
        extra_headers = &extra_headers_buf;
    }

    var req = client.open(.GET, uri, .{
        .server_header_buffer = &buf,
        .extra_headers = extra_headers,
    }) catch return error.NetworkUnreachable;
    defer req.deinit();

    if (options.auth_token) |token| {
        var auth_buf: [256]u8 = undefined;
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.OutOfMemory;
        req.headers.authorization = .{ .override = auth_val };
    }

    req.send() catch return error.NetworkUnreachable;
    req.wait() catch return error.NetworkUnreachable;

    const status = req.response.status;

    // Check status
    switch (status) {
        .ok, .not_modified => {},
        .too_many_requests => return error.RateLimited,
        .internal_server_error, .bad_gateway, .service_unavailable => return error.ServerError,
        else => if (@intFromEnum(status) >= 400) return error.ServerError,
    }

    var etag: ?[]const u8 = null;
    var it = req.response.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "ETag")) {
            etag = try allocator.dupe(u8, header.value);
            break;
        }
    }
    errdefer if (etag) |e| allocator.free(e);

    if (status == .not_modified) {
        return .{ .status = status, .etag = etag };
    }

    // Stream Body
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    var reader = req.reader();
    var total_read: usize = 0;

    while (true) {
        const n = reader.read(fifo.writableSlice(0)) catch |err| switch (err) {
            else => return error.NetworkUnreachable,
        };
        if (n == 0) break;
        fifo.update(n);

        total_read += n;
        if (total_read > options.max_size) return error.TooLarge;

        try fifo.pump(writer);
    }

    return .{ .status = status, .etag = etag };
}
