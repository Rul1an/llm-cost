const std = @import("std");
const manifest = @import("manifest");

const Ed25519 = std.crypto.sign.Ed25519;
const Edwards25519 = std.crypto.ecc.Edwards25519;
const Sha512 = std.crypto.hash.sha2.Sha512;

const KeyError = error{
    InvalidKeyLength,
    InvalidKeyHex,
    InvalidKeyFormat,
};

fn secretKeyBytesFromSeed(seed: [32]u8) ![64]u8 {
    // RFC8032: digest = SHA512(seed)
    var digest: [64]u8 = undefined;
    Sha512.hash(&seed, &digest, .{});

    // scalar = clamp(digest[0..32])
    var scalar_bytes: [32]u8 = digest[0..32].*;
    scalar_bytes[0] &= 248;
    scalar_bytes[31] &= 127;
    scalar_bytes[31] |= 64;

    // basepoint mul (Zig 0.14 has no Edwards25519.Scalar type for public API)
    // Check for decl just in case, though we verified "basePoint" previously.
    const base = if (@hasDecl(Edwards25519, "base_point")) Edwards25519.base_point else Edwards25519.basePoint;

    // mul expects scalar bytes [32]u8 in 0.14 nightly
    const A = try base.mul(scalar_bytes);
    const pk_bytes = A.toBytes(); // [32]u8

    var out: [64]u8 = undefined;
    @memcpy(out[0..32], &seed);
    @memcpy(out[32..64], &pk_bytes);
    return out;
}

/// Accepts:
/// - 64 hex chars  => 32-byte seed
/// - 128 hex chars => 64-byte secret key bytes (seed||pubkey)
fn keyPairFromPrivateHex(priv_hex: []const u8) !Ed25519.KeyPair {
    if (priv_hex.len == 64) {
        var seed: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&seed, priv_hex) catch return KeyError.InvalidKeyHex;

        const sk_bytes = try secretKeyBytesFromSeed(seed);
        const sk = Ed25519.SecretKey.fromBytes(sk_bytes) catch return KeyError.InvalidKeyFormat;
        return Ed25519.KeyPair.fromSecretKey(sk) catch return KeyError.InvalidKeyFormat;

    } else if (priv_hex.len == 128) {
        var sk_bytes: [64]u8 = undefined;
        _ = std.fmt.hexToBytes(&sk_bytes, priv_hex) catch return KeyError.InvalidKeyHex;

        // This must be the Zig/libsodium format: seed||pubkey
        const sk = Ed25519.SecretKey.fromBytes(sk_bytes) catch return KeyError.InvalidKeyFormat;
        return Ed25519.KeyPair.fromSecretKey(sk) catch return KeyError.InvalidKeyFormat;

    } else {
        return KeyError.InvalidKeyLength;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 6) {
        std.debug.print("Usage: {s} <private_key_hex> <input_db.json> <output_dir> <version> <base_url>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const private_key_hex = args[1];
    const input_db_path = args[2];
    const output_dir = args[3];
    const version_str = args[4];
    const base_url = args[5];

    const version = try std.fmt.parseInt(u64, version_str, 10);

    // 1. Prepare Output Paths
    const output_db_name = "pricing_db.json.zst";
    const output_db_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, output_db_name });
    defer allocator.free(output_db_path);

    const output_manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "manifest.json" });
    defer allocator.free(output_manifest_path);

    // 2. Compress DB (using system zstd)
    std.debug.print("Compressing {s} -> {s}...\n", .{ input_db_path, output_db_path });
    const zstd_args = &[_][]const u8{ "zstd", "-19", "-f", input_db_path, "-o", output_db_path };
    var child = std.process.Child.init(zstd_args, allocator);
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Error: zstd failed (exit code {any}). Ensure 'zstd' is installed.\n", .{term});
        return error.CompressionFailed;
    }

    // 3. Hash & Size of Artifact
    const db_file = try std.fs.cwd().openFile(output_db_path, .{});
    defer db_file.close();
    const stat = try db_file.stat();
    if (stat.size > 1024 * 1024 * 1024) return error.ArtifactTooLarge;

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try db_file.read(&buf);
        if (n == 0) break;
        sha256.update(buf[0..n]);
    }
    var hash_bytes: [32]u8 = undefined;
    sha256.final(&hash_bytes);
    var hash_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)}) catch return error.HexError;

    // 4. Construct Manifest Body
    const now = std.time.timestamp();
    // Anti-freeze: 7 days TTL (strict)
    const expires_at = now + (7 * 24 * 60 * 60);

    // Construct URL: <base_url>/<version>/pricing_db.json.zst
    const clean_base_url = std.mem.trimRight(u8, base_url, "/");
    const artifact_url = try std.fmt.allocPrint(allocator, "{s}/{d}/{s}", .{ clean_base_url, version, output_db_name });
    defer allocator.free(artifact_url);

    // Hardening: Model count parsing was memory heavy.
    // Using 0 for now as strict stability pref.
    const model_count: u32 = 0;

    const body: manifest.ManifestBody = .{
        .schema_version = 1,
        .version = version,
        .generated_at = now,
        .expires_at = expires_at,
        .key_id = "root",
        .db = .{
            .url = artifact_url,
            .sha256 = &hash_hex,
            .size_bytes = stat.size,
            .model_count = model_count,
        },
    };

    // 5. Sign (Canonical)
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try manifest.writeCanonicalBody(list.writer(), body);
    const canonical_body = list.items;

    // Robust Key Handling
    const key_pair = keyPairFromPrivateHex(private_key_hex) catch |err| {
        std.debug.print(
            "Error: invalid private key ({any}).\n" ++
            "Expected:\n" ++
            "  - 64 hex chars  (32-byte seed)\n" ++
            "  - 128 hex chars (64-byte secret key bytes: seed||pubkey)\n",
            .{err},
        );
        return err;
    };

    const signature = try key_pair.sign(canonical_body, null);

    const sig_bytes = signature.toBytes();
    const sig_base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(sig_bytes.len));
    defer allocator.free(sig_base64);
    _ = std.base64.standard.Encoder.encode(sig_base64, &sig_bytes);

    // 6. Output Manifest
    const container = manifest.ManifestContainer{
        .body = body,
        .signature = sig_base64,
    };

    const out_file = try std.fs.cwd().createFile(output_manifest_path, .{});
    defer out_file.close();
    try std.json.stringify(container, .{ .whitespace = .indent_2 }, out_file.writer());
    try out_file.writer().print("\n", .{});

    std.debug.print("Success!\nArtifact: {s}\nManifest: {s}\n", .{output_db_path, output_manifest_path});
}
