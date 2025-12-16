const std = @import("std");

const API_ENDPOINT = "https://api.llm-cost.dev/v1/license/status";

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.len < 1) {
        try stderr.print("Usage: llm-cost verify-license <LICENSE_KEY>\n", .{});
        return 1;
    }

    const license_key = args[0];

    // 1. Setup HTTP Client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 2. Prepare Request
    var buf: [4096]u8 = undefined;
    const uri = try std.Uri.parse(API_ENDPOINT);

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &buf,
        .headers = .{
            .authorization = .{ .bearer = license_key },
        },
    });
    defer req.deinit();

    // 3. Send
    try req.send();
    try req.finish();
    try req.wait();

    // 4. Handle Response
    if (req.response.status != .ok) {
        try stderr.print("Error: Server returned {d}\n", .{req.response.status});
        if (req.response.status == .unauthorized) {
            try stderr.print("Invalid License Key.\n", .{});
        }
        return 1;
    }

    // 5. Read Body
    const body = try req.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(body);

    // 6. Output
    try stdout.print("License Status:\n{s}\n", .{body});

    return 0;
}
