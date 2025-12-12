const std = @import("std");

/// Vantage-Compatible FOCUS Column Subset (Strict Order)
pub const columns = [_][]const u8{
    "ChargePeriodStart",
    "ChargeCategory",
    "BilledCost",
    "ResourceId",
    "ResourceType",
    "RegionId",
    "ServiceCategory",
    "ServiceName",
    "ConsumedQuantity",
    "ConsumedUnit",
    "Tags",
};

/// A single FOCUS export row with ownership semantics.
/// Must be deinitialized to prevent memory leaks during streaming.
pub const FocusRow = struct {
    allocator: std.mem.Allocator,

    // -- Columns --
    // 1. ChargePeriodStart (YYYY-MM-DD)
    charge_period_start: []const u8, // Owned
    // 2. ChargeCategory (Static "Usage")
    charge_category: []const u8 = "Usage",
    // 3. BilledCost (4 decimal precision)
    billed_cost: f64,
    // 4. ResourceId (Manifest ID or Slug)
    resource_id: []const u8, // Owned
    // 5. ResourceType (Static "LLM")
    resource_type: []const u8 = "LLM",
    // 6. RegionId (Empty for Global API)
    region_id: []const u8 = "",
    // 7. ServiceCategory (Static)
    service_category: []const u8 = "AI and Machine Learning",
    // 8. ServiceName (Static)
    service_name: []const u8 = "LLM Inference",
    // 9. ConsumedQuantity (Total Tokens)
    consumed_quantity: u64,
    // 10. ConsumedUnit (Static "Tokens")
    consumed_unit: []const u8 = "Tokens",
    // 11. Tags (JSON Payload) - Keys and Values are Owned
    tags: std.StringHashMap([]const u8),

    /// Initialize a new FocusRow with internal HashMap
    pub fn init(allocator: std.mem.Allocator) FocusRow {
        return .{
            .allocator = allocator,
            .charge_period_start = "", // Must be set by mapper
            .billed_cost = 0.0,
            .resource_id = "", // Must be set by mapper
            .consumed_quantity = 0,
            .tags = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Deep cleanup of all owned fields
    pub fn deinit(self: *FocusRow) void {
        // Free owned strings (check against empty/static defaults if needed,
        // but robust mapper should always duplicate dynamic content)
        // Note: For safety, mapper should strictly own these.
        // If empty string literal is used, free might crash if we don't track ownership strictly.
        // Convention: If length > 0, assume owned.
        if (self.charge_period_start.len > 0) self.allocator.free(self.charge_period_start);
        if (self.resource_id.len > 0) self.allocator.free(self.resource_id);

        var it = self.tags.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tags.deinit();
    }

    /// Helper to add an owned tag (dupes keys/values)
    pub fn addTag(self: *FocusRow, key: []const u8, value: []const u8) !void {
        const key_owned = try self.allocator.dupe(u8, key);
        const val_owned = try self.allocator.dupe(u8, value);
        try self.tags.put(key_owned, val_owned);
    }
};
