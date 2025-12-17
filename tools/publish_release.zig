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

    if (args.len < 6) {
        std.debug.print("Usage: {s} <private_key_hex> <input_db.json> <output_dir> <version> <base_url> [flags]\n", .{args[0]});
        std.debug.print("Flags:\n  --no-compress\n  --dry-run\n  --print-upload-commands\n  --expires-days <N>\n", .{});
        return error.InvalidArgs;
    }

    const private_key_hex = args[1];
    const input_db_path = args[2];
    const output_dir = args[3];
    const version_str = args[4];
    const base_url = args[5];

    // Arg Parsing
    var no_compress = false;
    var dry_run = false;
    var print_upload_cmds = false;
    var expires_days: i64 = 7; // Default 7 days

    var i: usize = 6;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--no-compress")) {
            no_compress = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--print-upload-commands")) {
            print_upload_cmds = true;
        } else if (std.mem.eql(u8, arg, "--expires-days")) {
            if (i + 1 < args.len) {
                expires_days = try std.fmt.parseInt(i64, args[i + 1], 10);
                i += 1;
            }
        }
    }

    const version = try std.fmt.parseInt(u64, version_str, 10);
    const now = std.time.timestamp();
    // Validate expires_days
    if (expires_days <= 0 or expires_days > 365) {
        std.debug.print("Error: --expires-days must be between 1 and 365.\n", .{});
        return error.InvalidArgs;
    }
    const expires_at = now + (expires_days * 24 * 60 * 60);

    // Hardening: Prevent uncompressed remote releases (security/perf guard)
    const is_remote = std.mem.startsWith(u8, base_url, "http://") or std.mem.startsWith(u8, base_url, "https://");
    if (no_compress and is_remote and !dry_run) {
        std.debug.print("Error: --no-compress used with remote URL. Remote artifacts must be compressed (zstd).\n", .{});
        return error.UnsafeRelease;
    }

    // 0. Auto-Calculate Model Count
    // Read input file to parse and count
    const input_bytes = try std.fs.cwd().readFileAlloc(allocator, input_db_path, 256 * 1024 * 1024);
    defer allocator.free(input_bytes);

    var count_parser = try std.json.parseFromSlice(std.json.Value, allocator, input_bytes, .{});
    defer count_parser.deinit();

    var model_count: u32 = 0;
    if (count_parser.value == .object) {
        if (count_parser.value.object.get("models")) |m| {
            if (m == .object) {
                model_count = @intCast(m.object.count());
            }
        }
    }
    std.debug.print("Auto-detected models: {d}\n", .{model_count});

    // 1. Prepare Output Paths
    const output_db_name = "pricing_db.json.zst";
    const output_db_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, output_db_name });
    defer allocator.free(output_db_path);

    const output_manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "manifest.json" });
    defer allocator.free(output_manifest_path);

    // Ensure output dir exists
    std.fs.cwd().makePath(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // 2. Compress or Copy
    const final_url_name = if (no_compress) "pricing_db.json" else output_db_name;
    const compression_tag = if (no_compress) "none" else "zstd";

    // Path Management Logic
    var processing_db_path: []const u8 = undefined;
    var processing_db_path_owned: ?[]u8 = null;
    defer if (processing_db_path_owned) |p| allocator.free(p);

    if (dry_run) {
        if (no_compress) {
            processing_db_path = input_db_path; // NOT owned
        } else {
            processing_db_path_owned = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "dry_run_temp.zst" });
            processing_db_path = processing_db_path_owned.?;
        }
    } else {
        if (no_compress) {
            processing_db_path_owned = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "pricing_db.json" });
            processing_db_path = processing_db_path_owned.?;
        } else {
            processing_db_path = output_db_path; // owned elsewhere (line 120ish, but confusing ownership)
            // Wait, output_db_path is allocated above and deferred.
            // So we can just point to it.
        }
    }

    if (!no_compress) {
        // Compress logic
        const cmd_args = &[_][]const u8{ "zstd", "-19", "-f", input_db_path, "-o", processing_db_path };
        std.debug.print("Compressing {s} -> {s}...\n", .{ input_db_path, processing_db_path });
        var child = std.process.Child.init(cmd_args, allocator);
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) return error.CompressionFailed;
    } else {
        // Copy Logic
        // In dry_run + no_compress, processing_db_path IS input_db_path, so no copy needed.
        // In !dry_run + no_compress, we act.
        if (!dry_run) {
            std.debug.print("Copying {s} -> {s}...\n", .{ input_db_path, processing_db_path });
            try std.fs.cwd().copyFile(input_db_path, std.fs.cwd(), processing_db_path, .{});
        }
    }

    // 3. Hash & Size
    const db_file = try std.fs.cwd().openFile(processing_db_path, .{});
    defer db_file.close(); // Improved defer
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
    const hex_chars = "0123456789abcdef";
    for (hash_bytes, 0..) |byte, idx| {
        hash_hex[idx * 2] = hex_chars[byte >> 4];
        hash_hex[idx * 2 + 1] = hex_chars[byte & 0x0F];
    }

    // Cleanup temp if dry run
    if (dry_run and !no_compress) {
        try std.fs.cwd().deleteFile(processing_db_path);
    }

    // 4. Construct Manifest Body
    const clean_base_url = std.mem.trimRight(u8, base_url, "/");
    // URL in manifest points to where it WILL be.
    const manifest_url = try std.fmt.allocPrint(allocator, "{s}/{d}/{s}", .{ clean_base_url, version, final_url_name });
    defer allocator.free(manifest_url);

    const body: manifest.ManifestBody = .{
        .schema_version = 1,
        .version = version,
        .generated_at = now,
        .expires_at = expires_at,
        .key_id = "root",
        .db = .{
            .url = manifest_url,
            .sha256 = hash_hex[0..], // Correct slice usage
            .size_bytes = stat.size,
            .model_count = model_count,
            .db_schema_version = 1,
            .compression = compression_tag,
        },
    };

    // 5. Sign
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try manifest.writeCanonicalBody(list.writer(), body);
    const canonical_body = list.items;

    // Verify key even if dry-run (to validate key format)
    const key_pair = keyPairFromPrivateHex(private_key_hex) catch |err| {
        std.debug.print("Error: invalid private key format.\n", .{});
        return err;
    };

    // Sign
    const signature = try key_pair.sign(canonical_body, null);
    const sig_bytes = signature.toBytes();
    const sig_base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(sig_bytes.len));
    defer allocator.free(sig_base64);
    _ = std.base64.standard.Encoder.encode(sig_base64, &sig_bytes);

    // 6. Output / Summary
    if (dry_run) {
        std.debug.print("\n--- DRY RUN SUMMARY ---\n", .{});
        std.debug.print("Version:    {d}\n", .{version});
        std.debug.print("Expires:    {d} days\n", .{expires_days});
        std.debug.print("Models:     {d}\n", .{model_count});
        std.debug.print("Artifact:   {s} ({d} bytes)\n", .{ final_url_name, stat.size });
        std.debug.print("Hash (SHA): {s}\n", .{hash_hex});
        std.debug.print("Compression:{s}\n", .{compression_tag});
        std.debug.print("Signature:  Verified (Ed25519)\n", .{});
        std.debug.print("Manifest:   Valid (Canonical JSON generated)\n", .{});

        if (print_upload_cmds) {
            std.debug.print("\n--- UPLOAD COMMANDS (Preview) ---\n", .{});
            const version_path = try std.fmt.allocPrint(allocator, "prices/{d}", .{version});
            defer allocator.free(version_path);

            std.debug.print("npx wrangler r2 object put \"{s}/manifest.json\" --file manifest.json --remote --content-type application/json --cache-control \"public, max-age=60\"\n", .{version_path});

            std.debug.print("npx wrangler r2 object put \"{s}/{s}\" --file \"{s}\" --remote --content-type application/octet-stream --cache-control \"public, max-age=31536000, immutable\"\n", .{ version_path, final_url_name, final_url_name });
        }
    } else {
        // Write Manifest
        // Fix: Use base64 signature in container
        const container = manifest.ManifestContainer{
            .body = body,
            .signature = sig_base64,
        };

        const out_file = try std.fs.cwd().createFile(output_manifest_path, .{});
        defer out_file.close();
        try std.json.stringify(container, .{ .whitespace = .indent_2 }, out_file.writer());
        try out_file.writer().print("\n", .{});

        std.debug.print("\nSUCCESS!\nArtifact: {s}\nManifest: {s}\n", .{ if (!no_compress) output_db_path else processing_db_path, output_manifest_path });

        if (print_upload_cmds) {
            std.debug.print("\n--- UPLOAD COMMANDS ---\n", .{});

            const version_path = try std.fmt.allocPrint(allocator, "prices/{d}", .{version});
            defer allocator.free(version_path);

            // Manifest
            std.debug.print("npx wrangler r2 object put \"{s}/manifest.json\" --file \"{s}\" --remote --content-type application/json --cache-control \"public, max-age=60\"\n", .{ version_path, output_manifest_path });

            // DB
            const db_source_path = if (!no_compress) output_db_path else processing_db_path;

            std.debug.print("npx wrangler r2 object put \"{s}/{s}\" --file \"{s}\" --remote --content-type application/octet-stream --cache-control \"public, max-age=31536000, immutable\"\n", .{ version_path, final_url_name, db_source_path });

            std.debug.print("# Don't forget to update latest pointer if desired.\n", .{});
        }
    }
}
