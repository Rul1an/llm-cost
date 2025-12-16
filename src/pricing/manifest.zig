const std = @import("std");

/// Signed Manifest JSON Schema (ADR-010)
pub const Manifest = struct {
    schema_version: u32,
    version: u64, // Monotonic (e.g., YYYYMMDDNN)
    generated_at: []const u8, // ISO8601 string
    db: DbArtifact,
    sig: []const u8, // Base64 signature of the canonical JSON (excluding sig field usually, or enveloping)

    pub const DbArtifact = struct {
        url: []const u8,
        sha256: []const u8,
        size_bytes: u64,
    };
};

pub const ValidationResult = enum {
    Valid,
    SignatureInvalid,
    RollbackDetected,
    Frozen, // Too old (freeze attack)
    SchemaMismatch,
};

/// Verify a manifest against embedded public keys and local state
pub fn verify(
    allocator: std.mem.Allocator,
    manifest_source: []const u8,
    highest_seen_version: u64,
) !ValidationResult {
    _ = allocator;
    _ = manifest_source;
    _ = highest_seen_version;

    // TODO: Implement Ed25519 verification using src/core/pricing/crypto.zig
    // TODO: Parse JSON
    // TODO: Check version >= highest_seen_version
    // TODO: Check generated_at vs std.time.timestamp() (7 days limit)

    return .Valid;
}
