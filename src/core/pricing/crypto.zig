const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Base64 = std.base64.standard;

// Correcte 42-byte Base64 string (56 chars, geen padding)
// Header: RW (0x45 0x64 -> "Ed")
// KeyID + Key: Willekeurige bytes om aan 42 te komen
const EMBEDDED_PUB_KEY_STR = "RWQf6LRCGA9i59SLwC+6433344455566677788899900011122233344";

// Revocation List
const REVOKED_KEY_IDS = [_]u64{
    0xDEADBEEFDEADBEEF, // Placeholder
};

pub const VerifyError = error{
    InvalidFormat,
    InvalidSignature,
    KeyRevoked,
    KeyMismatch,
    EncodingError,
};

/// Verifies a JSON buffer against a Minisign signature file content.
/// Construction: Verify(Signature, Blake2b(File) || TrustedComment)
pub fn verify(allocator: std.mem.Allocator, file_data: []const u8, sig_file_content: []const u8) !void {
    // 1. Parse Public Key
    const pub_key = try parsePublicKey(EMBEDDED_PUB_KEY_STR);

    // 2. Parse Signature File
    const sig_data = try parseMinisignFile(allocator, sig_file_content);
    defer allocator.free(sig_data.trusted_comment);

    // 3. Check Revocation
    for (REVOKED_KEY_IDS) |revoked_id| {
        if (sig_data.key_id == revoked_id) return error.KeyRevoked;
    }

    // 4. Check Key ID Match
    if (sig_data.key_id != pub_key.key_id) return error.KeyMismatch;

    // 5. Construct Signed Payload: Blake2b(File) ++ TrustedComment
    var hash: [64]u8 = undefined;
    Blake2b512.hash(file_data, &hash, .{});

    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();
    try payload.appendSlice(&hash);
    try payload.appendSlice(sig_data.trusted_comment);

    // 6. Verify Ed25519 Signature (Method syntax)
    pub_key.key.verify(payload.items, sig_data.signature) catch return error.InvalidSignature;
}

const MinisignSig = struct {
    key_id: u64,
    signature: [64]u8,
    trusted_comment: []const u8,
};

const PublicKey = struct {
    key_id: u64,
    key: Ed25519.PublicKey,
};

fn parsePublicKey(b64_key: []const u8) !PublicKey {
    var buf: [1024]u8 = undefined;
    const decoded_len = Base64.Decoder.calcSizeForSlice(b64_key) catch return error.EncodingError;
    Base64.Decoder.decode(buf[0..decoded_len], b64_key) catch return error.EncodingError;

    // Minisign pubkey format: [Alg(2) | ID(8) | Key(32)] = 42 bytes
    if (decoded_len != 42) return error.InvalidFormat;
    // Check "Ed" magic bytes
    if (buf[0] != 0x45 or buf[1] != 0x64) return error.InvalidFormat;

    const key_id = std.mem.readInt(u64, buf[2..10], .little);
    const key_bytes = buf[10..42];
    const key = Ed25519.PublicKey.fromBytes(key_bytes[0..32].*) catch return error.InvalidFormat;

    return PublicKey{ .key_id = key_id, .key = key };
}

fn parseMinisignFile(allocator: std.mem.Allocator, content: []const u8) !MinisignSig {
    var lines = std.mem.tokenizeSequence(u8, content, "\n");

    // Line 1: Untrusted comment (ignore)
    _ = lines.next() orelse return error.InvalidFormat;

    // Line 2: Base64 Signature
    const sig_line = lines.next() orelse return error.InvalidFormat;
    var sig_buf: [128]u8 = undefined;

    const trimmed_sig = std.mem.trim(u8, sig_line, "\r ");
    const sig_len = Base64.Decoder.calcSizeForSlice(trimmed_sig) catch return error.EncodingError;
    Base64.Decoder.decode(sig_buf[0..sig_len], trimmed_sig) catch return error.EncodingError;

    if (sig_len != 74) return error.InvalidFormat;
    if (sig_buf[0] != 0x45 or sig_buf[1] != 0x64) return error.InvalidFormat;

    const key_id = std.mem.readInt(u64, sig_buf[2..10], .little);
    var signature: [64]u8 = undefined;
    @memcpy(&signature, sig_buf[10..74]);

    // Line 3: Trusted Comment
    const comment_line = lines.next() orelse return error.InvalidFormat;
    const prefix = "trusted comment: ";
    if (!std.mem.startsWith(u8, comment_line, prefix)) return error.InvalidFormat;

    const trusted_comment = try allocator.dupe(u8, std.mem.trimRight(u8, comment_line, "\r"));

    return MinisignSig{
        .key_id = key_id,
        .signature = signature,
        .trusted_comment = trusted_comment,
    };
}

test "parse pubkey" {
    const pk = try parsePublicKey(EMBEDDED_PUB_KEY_STR);
    _ = pk;
}
