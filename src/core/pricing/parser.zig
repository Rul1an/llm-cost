pub const Limits = struct {
    pub const MAX_JSON_SIZE: usize = 10 * 1024 * 1024; // 10 MB
    pub const MAX_MODELS: usize = 1000;
};

pub fn parsePricingDB(allocator: std.mem.Allocator, json_content: []const u8) !schema.PricingDB {
    if (json_content.len > Limits.MAX_JSON_SIZE) {
        return error.PricingDBTooLarge;
    }

    const parsed = try std.json.parseFromSlice(schema.PricingDB, allocator, json_content, .{
        .ignore_unknown_fields = true,
    });

    // Bounds Check: Models
    if (parsed.value.models.len > Limits.MAX_MODELS) {
        parsed.deinit();
        return error.PricingDBTooManyModels;
    }

    // Caller must deinitialize the returned structure via schema.PricingDB.deinit()
    // or by invalidating the arena if managed externally.
    return parsed.value;
}
