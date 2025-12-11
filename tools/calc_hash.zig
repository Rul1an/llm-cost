const std = @import("std");

pub fn main() !void {
    var buffer: [1024 * 10]u8 = undefined;
    const file = try std.fs.cwd().openFile("src/core/pricing/pricing_db.json", .{});
    defer file.close();
    const size = try file.readAll(&buffer);
    var hash: [64]u8 = undefined;
    std.crypto.hash.blake2.Blake2b512.hash(buffer[0..size], &hash, .{});
    var hex: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
    std.debug.print("{s}\n", .{hex});
}
