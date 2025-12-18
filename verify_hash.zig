const std = @import("std");

pub fn main() !void {
    const left: u32 = 220;
    const right: u32 = 14957;
    const key: u64 = (@as(u64, left) << 32) | right;
    const key_bytes = std.mem.asBytes(&key);
    const hash = std.hash.Wyhash.hash(0, key_bytes);

    std.debug.print("Left: {d}, Right: {d}\n", .{left, right});
    std.debug.print("Key: 0x{x}\n", .{key});
    std.debug.print("Key Bytes: {any}\n", .{key_bytes});
    std.debug.print("Hash: 0x{x}\n", .{hash});
}
