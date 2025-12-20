const std = @import("std");
const calibration = @import("calibration");

// We need PriceDef. Since it's not exposed by calibration module directly easily (it's in core/pricing/schema),
// we can just stick to duck typing or define a compatible struct if we can.
// But `recommendations.zig` uses `unitPriceMicroPerToken` which accesses fields.
// So we must provide fields: input_price_per_mtok, output_price_per_mtok.
// And recommendation logic accesses iterator keys/values.

const MockPriceDef = struct {
    input_price_per_mtok: u64,
    output_price_per_mtok: u64,
};

const MockRegistry = struct {
    prices: std.StringHashMap(MockPriceDef),

    pub fn init(allocator: std.mem.Allocator) MockRegistry {
        return .{ .prices = std.StringHashMap(MockPriceDef).init(allocator) };
    }

    pub fn deinit(self: *MockRegistry) void {
        self.prices.deinit();
    }

    pub fn put(self: *MockRegistry, name: []const u8, in: u64, out: u64) !void {
        try self.prices.put(name, .{ .input_price_per_mtok = in, .output_price_per_mtok = out });
    }

    pub fn get(self: *const MockRegistry, name: []const u8) ?MockPriceDef {
        return self.prices.get(name);
    }

    pub const Iterator = struct {
        inner: std.StringHashMap(MockPriceDef).Iterator,
        pub fn next(self: *Iterator) ?Entry {
            if (self.inner.next()) |e| {
                return Entry{ .key = e.key_ptr.*, .value = e.value_ptr.* };
            }
            return null;
        }
        pub const Entry = struct {
            key: []const u8,
            value: MockPriceDef,
        };
    };

    pub fn iterator(self: *const MockRegistry) Iterator {
        return .{ .inner = self.prices.iterator() };
    }
};

test "End-to-end: Calibration Run (Matches Output)" {
    const allocator = std.testing.allocator;

    // Create temp files for estimates and actuals
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "estimates.json", .data = 
        \\{"estimated_total_usd": "100.00"}
    });
    // Actuals: 2 records.
    // r1 uses "model-A" (expensive).
    // r2 uses "model-A".
    try tmp.dir.writeFile(.{ .sub_path = "actuals.csv", .data = 
        \\ResourceId,BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,x-llm-model
        \\r1,60.00,60.00,1,req,usage,model-A
        \\r2,60.00,60.00,1,req,usage,model-A
    });

    // Get absolute paths because run() expects them (via openFile)
    const estimates_path = try tmp.dir.realpathAlloc(allocator, "estimates.json");
    defer allocator.free(estimates_path);
    const actuals_path = try tmp.dir.realpathAlloc(allocator, "actuals.csv");
    defer allocator.free(actuals_path);

    const opts = calibration.RunOptions{
        .estimates_path = estimates_path,
        .actuals_path = actuals_path,
        .min_samples = 1, // small sample for test
    };

    // Setup Mock Registry
    var reg = MockRegistry.init(allocator);
    defer reg.deinit();
    // model-A: expensive (e.g. 100 per MTok)
    // model-B: cheap (e.g. 10 per MTok) - 90% cheaper
    try reg.put("model-A", 100_000_000, 100_000_000);
    try reg.put("model-B", 10_000_000, 10_000_000);

    var interner = calibration.key_intern.StringInterner.init(allocator);
    defer interner.deinit();

    var result = try calibration.run(allocator, opts, &reg, &interner);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(i128, 100_000_000), result.estimated_total_micro);
    try std.testing.expectEqual(@as(i128, 120_000_000), result.actual_total_micro);
    try std.testing.expectEqual(@as(i128, 20_000_000), result.drift_absolute_micro);
    try std.testing.expectEqual(@as(i32, 2000), result.drift_bps);
    try std.testing.expectEqual(@as(u64, 2), result.sample_count);

    // Status: 2000 bps = 20% -> Warn
    try std.testing.expectEqual(calibration.Status.warn, result.status);

    // Verify Recommendations
    try std.testing.expect(result.recommendations.len > 0);
    const rec = result.recommendations[0];
    try std.testing.expectEqualStrings("model-A", rec.current_model);
    try std.testing.expectEqualStrings("model-B", rec.alternative_model);
    // Savings: (100 - 10)/100 = 90% = 9000 bps
    try std.testing.expectEqual(@as(i32, 9000), rec.savings_bps);

    // Verify output formatting
    var out_buf = std.ArrayList(u8).init(allocator);
    defer out_buf.deinit();
    try calibration.formatOutput(result, calibration.report.OutputFormat.json, out_buf.writer());

    // Check JSON content
    const json_str = out_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"drift_bps\":2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"status\":\"warn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"recommendations\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"alternative\":\"model-B\"") != null);
}

test "End-to-end: Nasty CSV (Quotes, CRLF)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "estimates.json", .data = "{\"estimated_total_usd\": \"100.00\"}" });

    // Actuals with:
    // - CRLF line endings
    // - Quoted fields with commas ("usage, daily")
    // - Empty optional fields
    try tmp.dir.writeFile(.{ .sub_path = "actuals.csv", .data = "ResourceId,BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,x-llm-model\r\n" ++
        "r1,50.00,50.00,1,req,\"usage, daily\",model-A\r\n" ++
        "r2,\"50.00\",50.00,1,req,usage,\"model-A\"\r\n" });

    const estimates_path = try tmp.dir.realpathAlloc(allocator, "estimates.json");
    defer allocator.free(estimates_path);
    const actuals_path = try tmp.dir.realpathAlloc(allocator, "actuals.csv");
    defer allocator.free(actuals_path);

    const opts = calibration.RunOptions{
        .estimates_path = estimates_path,
        .actuals_path = actuals_path,
        .min_samples = 1,
    };

    var reg = MockRegistry.init(allocator);
    defer reg.deinit();
    try reg.put("model-A", 100_000_000, 100_000_000);

    var interner = calibration.key_intern.StringInterner.init(allocator);
    defer interner.deinit();

    var result = try calibration.run(allocator, opts, &reg, &interner);
    defer result.deinit(allocator);

    // 50 + 50 = 100.00 actual vs 100.00 estimated = 0 drift
    try std.testing.expectEqual(@as(i128, 100_000_000), result.actual_total_micro);
    try std.testing.expectEqual(@as(i32, 0), result.drift_bps);
    try std.testing.expectEqual(calibration.Status.ok, result.status);
    try std.testing.expectEqual(@as(u64, 2), result.sample_count);
}
