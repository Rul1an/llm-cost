const std = @import("std");

// TODO: User to replace with their actual Test Mode Payment Link
const STRIPE_PAYMENT_LINK = "https://buy.stripe.com/test_REPLACE_WITH_YOUR_LINK";

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    _ = args;
    const stdout = std.io.getStdOut().writer();
    // const stderr = std.io.getStdErr().writer();

    // 1. Generate License Key (client_reference_id)
    // Format: lc_<24_chars_random_hex>
    var rnd_buf: [12]u8 = undefined;
    std.crypto.random.bytes(&rnd_buf);

    // Hex encode
    var hex_buf: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&rnd_buf)}) catch unreachable;

    const license_key = try std.fmt.allocPrint(allocator, "lc_{s}", .{hex_buf});
    defer allocator.free(license_key);

    // 2. Construct URL
    const url = try std.fmt.allocPrint(allocator, "{s}?client_reference_id={s}", .{ STRIPE_PAYMENT_LINK, license_key });
    defer allocator.free(url);

    // 3. Output
    try stdout.print("\n=== Upgrade to llm-cost Pro ===\n\n", .{});
    try stdout.print("To activate your Pro license (Test Mode), please visit:\n", .{});
    try stdout.print("{s}\n\n", .{url});
    try stdout.print("YOUR LICENSE KEY: {s}\n", .{license_key});
    try stdout.print("Please SAVE this key! You will need it to verify your license.\n\n", .{});
    return 0;
}
