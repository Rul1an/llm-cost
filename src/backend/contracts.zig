const std = @import("std");

/// Response for GET /v1/license/status
pub const LicenseStatus = struct {
    tier: Tier,
    expires_at: ?i64, // Unix timestamp, null = never
    issued_at: i64,
    features: []const []const u8 = &[_][]const u8{},

    pub const Tier = enum {
        free,
        pro,
        enterprise,
    };
};

/// Standard API Error Response
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
    request_id: ?[]const u8 = null,
};
