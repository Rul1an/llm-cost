const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main() !void {
    const key_pair = Ed25519.KeyPair.generate();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Private Key (Hex): {s}\n", .{std.fmt.fmtSliceHexLower(&key_pair.secret_key.bytes)});
    try stdout.print("Public Key (Hex):  {s}\n", .{std.fmt.fmtSliceHexLower(&key_pair.public_key.bytes)});
}
