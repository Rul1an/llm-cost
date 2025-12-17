const std = @import("std");

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const input = try stdin.readToEndAlloc(std.heap.page_allocator, 1024);
    defer std.heap.page_allocator.free(input);

    const trimmed = std.mem.trim(u8, input, " \n\r");

    var valid_key_pair: ?std.crypto.sign.Ed25519.KeyPair = null;

    if (trimmed.len == 64) {
        // 32-byte seed
        var seed: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&seed, trimmed);
        valid_key_pair = try std.crypto.sign.Ed25519.KeyPair.create(seed);
    } else if (trimmed.len == 128) {
        // 64-byte secret
        var secret_bytes: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&secret_bytes, trimmed);
        const sk = try std.crypto.sign.Ed25519.SecretKey.fromBytes(secret_bytes);
        valid_key_pair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(sk);
    } else {
        std.debug.print("Error: Input must be 64 chars (seed) or 128 chars (expanded key)\n", .{});
        return;
    }

    const kp = valid_key_pair.?;
    std.debug.print("{s}", .{std.fmt.fmtSliceHexLower(&kp.public_key.bytes)});
}
