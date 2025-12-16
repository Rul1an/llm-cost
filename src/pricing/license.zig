const std = @import("std");

/// Offline License Certificate (ADR-010)
pub const License = struct {
    schema_version: u32,
    tier: Tier,
    org_id: []const u8,
    seats: u32,
    features: u32, // Bitmask
    expires_at: i64, // Timestamp
    sig: []const u8, // Base64 Ed25519 signature of the struct fields (canonicalized)

    pub const Tier = enum {
        free,
        pro,
        enterprise,

        // Helper to parse from string in JSON
        pub fn fromString(s: []const u8) Tier {
            if (std.mem.eql(u8, s, "pro")) return .pro;
            if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
            return .free;
        }
    };
};

pub const FeatureFlags = struct {
    pub const UNLIMITED_UPDATES: u32 = 1 << 0;
    pub const NOTIFICATIONS: u32 = 1 << 1;
    pub const HISTORY: u32 = 1 << 2;
    pub const CUSTOM_MODELS: u32 = 1 << 3;
};

/// Verify a license file against embedded public key
pub fn verify(
    allocator: std.mem.Allocator,
    license_json: []const u8,
) !License {
    _ = allocator;
    // TODO: Parse JSON
    // TODO: Verify Signature using crypto.zig
    // TODO: Check expires_at vs current time (return error.Expired if fail)

    return error.InvalidLicense; // Placeholder
}
