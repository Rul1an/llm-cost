const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Base64 = std.base64.standard;

// Production Public Key from mod.zig
const EMBEDDED_PUB_KEY_STR = "RWQlMFKYcN36NSyucoSch4tDfC/U/giAHdYklLaCOKZ+9PtYNdjO2Urw";
const MAX_LINE_LENGTH = 8192;

const REVOKED_KEY_IDS = [_]u64{
    0xDEADBEEFDEADBEEF,
};

pub const VerifyError = error{
    InvalidFormat,
    InvalidSignature,
    KeyRevoked,
    KeyMismatch,
    EncodingError,
};

const Algorithm = enum { ed, ed_hashed };

const SigRecord = struct {
    alg: Algorithm,
    key_id: u64,
    sig: [64]u8,
};

const MinisignSig = struct {
    key_id: u64,
    alg: Algorithm,
    signature: [64]u8,
    trusted_comment: []const u8, // comment text only (no "trusted comment: " prefix)
    comment_signature: ?[64]u8 = null, // optional; if missing => warn
};

const PublicKey = struct {
    key_id: u64,
    key: Ed25519.PublicKey,
};

pub fn verify(allocator: std.mem.Allocator, file_data: []const u8, sig_file_content: []const u8) !void {
    const pub_key = try parsePublicKey(EMBEDDED_PUB_KEY_STR);

    const sig_data = try parseMinisignFile(allocator, sig_file_content);
    defer allocator.free(sig_data.trusted_comment);

    for (REVOKED_KEY_IDS) |revoked_id| {
        if (sig_data.key_id == revoked_id) return error.KeyRevoked;
    }
    if (sig_data.key_id != pub_key.key_id) return error.KeyMismatch;

    // 1) Verify data signature
    var hash: [64]u8 = undefined;
    Blake2b512.hash(file_data, &hash, .{});
    const msg = hash[0..];

    // Note: We ignore sig_data.alg distinction because our existing signatures use 'Ed' but sign the hash.

    const sig = Ed25519.Signature.fromBytes(sig_data.signature);
    sig.verify(msg, pub_key.key) catch return error.InvalidSignature;

    // 2) Verify trusted comment signature (warning-only on failure)
    if (sig_data.comment_signature) |csig| {
        const payload_len = 64 + sig_data.trusted_comment.len;
        const payload = try allocator.alloc(u8, payload_len);
        defer allocator.free(payload);

        @memcpy(payload[0..64], sig_data.signature[0..]);
        @memcpy(payload[64..], sig_data.trusted_comment);

        const comment_sig = Ed25519.Signature.fromBytes(csig);
        comment_sig.verify(payload, pub_key.key) catch {
            std.log.warn(
                "Minisign: Trusted comment verification failed. Data is valid but metadata may be forged.",
                .{},
            );
        };
    } else {
        std.log.warn(
            "Minisign: Missing trusted comment signature. Data is valid but metadata may be forged.",
            .{},
        );
    }
}

fn parseAlg(b0: u8, b1: u8) !Algorithm {
    if (b0 == 'E' and b1 == 'd') return .ed;
    if (b0 == 'E' and b1 == 'D') return .ed_hashed;
    return error.InvalidFormat;
}

// Strict 74-byte Minisign Record Parser
fn parseSigRecord74(line: []const u8) !SigRecord {
    var rec_buf: [74]u8 = undefined;
    const trimmed = std.mem.trim(u8, line, "\r ");

    const rec_len = Base64.Decoder.calcSizeForSlice(trimmed) catch return error.EncodingError;
    if (rec_len > rec_buf.len or (rec_len != 64 and rec_len != 74)) return error.InvalidFormat;

    Base64.Decoder.decode(rec_buf[0..rec_len], trimmed) catch return error.EncodingError;

    const alg = try parseAlg(rec_buf[0], rec_buf[1]);
    const key_id = std.mem.readInt(u64, rec_buf[2..10], .little);

    var sig: [64]u8 = undefined;
    @memcpy(&sig, rec_buf[10..74]);

    return .{ .alg = alg, .key_id = key_id, .sig = sig };
}

// Strict 64-byte Bare Signature Parser
fn parseBareSig64(line: []const u8) !Ed25519.Signature {
    var buf: [64]u8 = undefined;
    const trimmed = std.mem.trim(u8, line, "\r ");

    const n = Base64.Decoder.calcSizeForSlice(trimmed) catch return error.EncodingError;
    if (n != buf.len) return error.InvalidFormat;

    Base64.Decoder.decode(&buf, trimmed) catch return error.EncodingError;

    return Ed25519.Signature.fromBytes(buf);
}

fn parsePublicKey(b64_key: []const u8) !PublicKey {
    var buf: [42]u8 = undefined; // Exactly 42 bytes for Minisign pubkey (KeyID + Key)
    const decoded_len = Base64.Decoder.calcSizeForSlice(b64_key) catch return error.EncodingError;

    // Strict length check BEFORE decode to prevent out-of-bounds
    if (decoded_len != buf.len) return error.InvalidFormat;

    Base64.Decoder.decode(&buf, b64_key) catch return error.EncodingError;

    const alg = try parseAlg(buf[0], buf[1]);
    if (alg != .ed) return error.InvalidFormat; // Only support standard Ed keys for now

    const key_id = std.mem.readInt(u64, buf[2..10], .little);
    const key_bytes = buf[10..42];

    const key = try Ed25519.PublicKey.fromBytes(key_bytes[0..32].*);
    return .{ .key_id = key_id, .key = key };
}

fn parseMinisignFile(allocator: std.mem.Allocator, content: []const u8) !MinisignSig {
    var lines = std.mem.tokenizeAny(u8, content, "\n");

    const untrusted_comment = lines.next() orelse return error.InvalidFormat;
    if (untrusted_comment.len > MAX_LINE_LENGTH) return error.InvalidFormat;
    _ = untrusted_comment;

    const sig_line = lines.next() orelse return error.InvalidFormat;
    if (sig_line.len > MAX_LINE_LENGTH) return error.InvalidFormat;
    const sig_rec = try parseSigRecord74(sig_line);

    var trusted_comment: []const u8 = "";
    var comment_signature: ?[64]u8 = null;

    // Try to find trusted comment
    if (lines.next()) |l| {
        if (l.len > MAX_LINE_LENGTH) return error.InvalidFormat;
        if (std.mem.startsWith(u8, l, "trusted comment: ")) {
            trusted_comment = try allocator.dupe(u8, l["trusted comment: ".len..]);
        } else {
            // Unexpected line format for trusted comment
            return error.InvalidFormat;
        }
    }

    const csig_line = lines.next();
    if (csig_line) |l| {
        if (l.len > MAX_LINE_LENGTH) return error.InvalidFormat;
        // Try parsing as standard record first
        if (parseSigRecord74(l)) |csig_rec| {
            if (csig_rec.key_id != sig_rec.key_id) {
                std.log.warn("Minisign: comment signature key_id mismatch.", .{});
            } else {
                comment_signature = csig_rec.sig;
            }
        } else |_| {
            // Fallback: Try parsing as bare signature
            if (parseBareSig64(l)) |bare_sig| {
                comment_signature = bare_sig.toBytes();
            } else |_| {
                // Both failed -> InvalidFormat
                return error.InvalidFormat;
            }
        }
    }

    return MinisignSig{
        .key_id = sig_rec.key_id,
        .alg = sig_rec.alg,
        .signature = sig_rec.sig,
        .trusted_comment = trusted_comment,
        .comment_signature = comment_signature,
    };
}
