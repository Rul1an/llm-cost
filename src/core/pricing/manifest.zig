const std = @import("std");

// Hex representation of the official public key (Ed25519 Root of Trust)
// Derived from seed: 323e...
pub const EMBEDDED_PUB_KEY_STR_HEX = "840ba0f1c8b4dbb614029a91db0040b788fb1368742f518dbb04ddc6f42308b3";

comptime {
    if (EMBEDDED_PUB_KEY_STR_HEX.len != 64) @compileError("EMBEDDED_PUB_KEY_STR_HEX must be exactly 64 hex chars");
}

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
        // v1.5.0 Hardening
        db_schema_version: u32 = 1,
        compression: []const u8 = "zstd", // or "none"
    };
};

pub const ManifestContainer = struct {
    body: ManifestBody,
    signature: []const u8,
};

pub const ValidationError = error{
    Expired,
    RollbackDetected,
    InsecureUrl,
    SignatureInvalid,
    SchemaVersionMismatch,
    InvalidFormat,
};

pub fn verify(
    allocator: std.mem.Allocator,
    container: ManifestContainer,
    public_key_hex: []const u8,
    current_time: i64,
    highest_seen_version: u64,
) !void {
    // 1. Check Schema Version (Strict)
    if (container.body.schema_version != 1) return ValidationError.SchemaVersionMismatch;
    if (container.body.db.db_schema_version != 1) return ValidationError.SchemaVersionMismatch;

    // Strict Compression Check
    const comp = container.body.db.compression;
    if (!std.mem.eql(u8, comp, "zstd") and !std.mem.eql(u8, comp, "none")) {
        return ValidationError.InvalidFormat;
    }

    // 2. Anti-Freeze
    if (container.body.expires_at < current_time) return ValidationError.Expired;

    // 3. Anti-Rollback
    if (container.body.version < highest_seen_version) return ValidationError.RollbackDetected;

    // 3.1 Hardening: URL Policy (HTTPS only)
    if (!std.mem.startsWith(u8, container.body.db.url, "https://")) {
        return ValidationError.InsecureUrl;
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

    // Decode Signature (Base64, Strict Length)
    var sig_buf: [std.crypto.sign.Ed25519.Signature.encoded_length]u8 = undefined;
    const sig_len = std.base64.standard.Decoder.calcSizeForSlice(container.signature) catch return ValidationError.InvalidFormat;
    if (sig_len != sig_buf.len) return ValidationError.SignatureInvalid;

    std.base64.standard.Decoder.decode(&sig_buf, container.signature) catch return ValidationError.SignatureInvalid;

    // Decode Public Key (Strict Length)
    if (public_key_hex.len != 64) return ValidationError.SignatureInvalid;
    var pub_key_bytes: [std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&pub_key_bytes, public_key_hex) catch return ValidationError.SignatureInvalid;

    const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_key_bytes) catch return ValidationError.SignatureInvalid;
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig_buf);

    signature.verify(canonical_body, pub_key) catch return ValidationError.SignatureInvalid;
}

pub fn verifyEmbedded(allocator: std.mem.Allocator, container: ManifestContainer) !void {
    // 1. Strict Schema & Logic
    // Embedded DB is ALWAYS uncompressed ("none")
    if (!std.mem.eql(u8, container.body.db.compression, "none")) {
        return ValidationError.InvalidFormat;
    }

    try verify(allocator, container, EMBEDDED_PUB_KEY_STR_HEX, 0, 0); // Ignore expiry, ignore rollback
}

pub fn writeCanonicalBody(writer: anytype, body: ManifestBody) !void {
    try std.json.stringify(body, .{ .whitespace = .minified }, writer);
}
