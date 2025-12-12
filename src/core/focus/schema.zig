const std = @import("std");

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

pub const FocusRow = struct {
    allocator: std.mem.Allocator,

    // Core Columns
    charge_period_start: []const u8,
    charge_category: []const u8,
    billed_cost: f64,
    resource_id: []const u8,
    resource_type: []const u8,
    region_id: []const u8,
    service_category: []const u8,
    service_name: []const u8,
    consumed_quantity: ?u64,
    consumed_unit: []const u8,

    // Metadata (Mapped to Tags or Columns)
    resource_name: []const u8,
    tags: Tags,

    pub const Tags = struct {
        provider: []const u8,
        model: []const u8,
        token_count_input: u64,
        token_count_output: u64,
        cache_hit_ratio: ?f64,
        content_hash: []const u8,
        user_tags: std.StringHashMap([]const u8),
    };

    pub fn deinit(self: *FocusRow) void {
        self.allocator.free(self.charge_period_start);
        self.allocator.free(self.charge_category);
        // billed_cost is f64
        self.allocator.free(self.resource_id);
        self.allocator.free(self.resource_type);
        self.allocator.free(self.region_id);
        self.allocator.free(self.service_category);
        self.allocator.free(self.service_name);
        // consumed_quantity is ?u64
        self.allocator.free(self.consumed_unit);
        self.allocator.free(self.resource_name);

        self.allocator.free(self.tags.provider);
        self.allocator.free(self.tags.model);
        self.allocator.free(self.tags.content_hash);

        var it = self.tags.user_tags.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tags.user_tags.deinit();
    }
};
