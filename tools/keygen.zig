const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Zig 0.14 seems to want 64-byte SecretKeys (likely extended secret key).
    // Let's generate 64 random bytes to treat as the secret key.
    var secret_bytes: [64]u8 = undefined;
    std.crypto.random.bytes(&secret_bytes);

    const secret_key = try std.crypto.sign.Ed25519.SecretKey.fromBytes(secret_bytes);
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(secret_key);

    var priv_hex: [128]u8 = undefined;
    _ = try std.fmt.bufPrint(&priv_hex, "{s}", .{std.fmt.fmtSliceHexLower(&secret_bytes)});

    var pub_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&pub_hex, "{s}", .{std.fmt.fmtSliceHexLower(&key_pair.public_key.bytes)});

    try stdout.print("PRIVATE_KEY_HEX={s}\n", .{priv_hex});
    try stdout.print("PUBLIC_KEY_HEX={s}\n", .{pub_hex});
}
