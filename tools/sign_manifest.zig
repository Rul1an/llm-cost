const std = @import("std");
const manifest = @import("manifest");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print("Usage: {s} <private_key_hex> <input_body.json>\n", .{args[0]});
        return;
    }

    const private_key_hex = args[1];
    const input_path = args[2];

    // 1. Load Input JSON
    const file = try std.fs.cwd().openFile(input_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    _ = try file.readAll(buffer);

    // 2. Parse into ManifestBody
    const parsed = try std.json.parseFromSlice(manifest.ManifestBody, allocator, buffer, .{});
    defer parsed.deinit();
    const body = parsed.value;

    // 3. Canonicalize (Re-serialize)
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try manifest.writeCanonicalBody(list.writer(), body);
    const canonical_body = list.items;

    // 4. Sign
    var secret_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&secret_bytes, private_key_hex) catch {
        std.debug.print("Error: Invalid private key hex (must be 64 bytes / 128 hex chars)\n", .{});
        return;
    };

    const key_pair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(try std.crypto.sign.Ed25519.SecretKey.fromBytes(secret_bytes));
    const signature = try key_pair.sign(canonical_body, null);

    // 5. Encode Signature (Base64)
    const sig_bytes = signature.toBytes();
    const sig_base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(sig_bytes.len));
    defer allocator.free(sig_base64);
    _ = std.base64.standard.Encoder.encode(sig_base64, &sig_bytes);

    // 6. Output Final Container
    const container = manifest.ManifestContainer{
        .body = body,
        .signature = sig_base64,
    };

    const stdout = std.io.getStdOut().writer();
    try std.json.stringify(container, .{ .whitespace = .indent_2 }, stdout);
    try stdout.print("\n", .{});
}
