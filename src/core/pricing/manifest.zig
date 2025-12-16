const std = @import("std");

pub const ManifestBody = struct {
    schema_version: u32 = 1,
    version: u64,
    generated_at: i64,
    expires_at: i64,
    key_id: []const u8,
    db: PricingDBRef,

    pub const PricingDBRef = struct {
        url: []const u8,
        sha256: []const u8,
        size_bytes: u64,
        model_count: u32,
    };
};

pub const ManifestContainer = struct {
    body: ManifestBody,
    signature: []const u8,
};

pub const ValidationError = error{
    Expired,
    RollbackDetected,
    SignatureInvalid,
    SchemaVersionMismatch,
};

pub fn verify(
    allocator: std.mem.Allocator,
    container: ManifestContainer,
    public_key_hex: []const u8,
    current_time: i64,
    highest_seen_version: u64,
) !void {
    // 1. Check Schema Version
    if (container.body.schema_version != 1) return ValidationError.SchemaVersionMismatch;

    // 2. Anti-Freeze
    if (container.body.expires_at < current_time) return ValidationError.Expired;

    // 3. Anti-Rollback
    if (container.body.version < highest_seen_version) return ValidationError.RollbackDetected;

    // 3.1 Hardening: URL Policy (HTTPS only)
    if (!std.mem.startsWith(u8, container.body.db.url, "https://")) {
        // We reuse SignatureInvalid or add a new error, but user asked for strictness.
        // Let's print debug and fail.
        std.debug.print("DEBUG: URL not HTTPS: {s}\n", .{container.body.db.url});
        return ValidationError.SignatureInvalid;
    }

    // 3.2 Hardening: Limits
    if (container.body.db.sha256.len != 64) return ValidationError.SignatureInvalid;
    if (container.body.db.size_bytes > 1024 * 1024 * 1024) return ValidationError.SignatureInvalid; // Max 1GB
    if (container.body.db.model_count > 1_000_000) return ValidationError.SignatureInvalid; // Max 1M models

    // 4. Verify Signature
    // Reconstruct CANONICAL JSON using the helper to ensure minified/strict format.
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try writeCanonicalBody(list.writer(), container.body);
    const canonical_body = list.items;

    // Decode Signature (Strict Length)
    var sig_bytes: [std.crypto.sign.Ed25519.Signature.encoded_length]u8 = undefined;
    const sig_len = try std.base64.standard.Decoder.calcSizeForSlice(container.signature);
    if (sig_len != sig_bytes.len) {
        std.debug.print("DEBUG: Signature length mismatch: expected {d}, found {d}\n", .{ sig_bytes.len, sig_len });
        return ValidationError.SignatureInvalid;
    }
    std.base64.standard.Decoder.decode(&sig_bytes, container.signature) catch |err| {
        std.debug.print("DEBUG: Signature decode failed: {any}\n", .{err});
        return ValidationError.SignatureInvalid;
    };

    // Decode Public Key (Strict Length)
    if (public_key_hex.len != 64) return ValidationError.SignatureInvalid;
    var pub_key_bytes: [std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&pub_key_bytes, public_key_hex) catch return ValidationError.SignatureInvalid;

    const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_key_bytes) catch return ValidationError.SignatureInvalid;
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);

    signature.verify(canonical_body, pub_key) catch return ValidationError.SignatureInvalid;
}

pub fn writeCanonicalBody(writer: anytype, body: ManifestBody) !void {
    try std.json.stringify(body, .{ .whitespace = .minified }, writer);
}
