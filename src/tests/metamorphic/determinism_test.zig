const std = @import("std");
const mod = @import("mod.zig");

const calibration = @import("calibration");

test "determinism: calibrate TOML output is byte-identical (10x)" {
    const estimates =
        \\{"estimated_total_micro_usd":10000000,"items":[{"resource_id":"a","estimated_micro_usd":10000000}]}
    ;
    const actuals =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\10.000000,10.000000,1,Tokens,Usage,a
    ;

    const opts: calibration.RunOptions = .{
        .estimates_path = "estimates.json",
        .actuals_path = "actuals.csv",
        .min_samples = 1,
        .warning_threshold_bps = 2000,
        .error_threshold_bps = 5000,
    };

    const out1 = try mod.runCalibrateFromStrings(std.testing.allocator, estimates, actuals, opts, .toml);
    defer std.testing.allocator.free(out1);

    // Run 10x to verify stability
    for (0..10) |_| {
        const out_i = try mod.runCalibrateFromStrings(std.testing.allocator, estimates, actuals, opts, .toml);
        defer std.testing.allocator.free(out_i);
        try std.testing.expectEqualStrings(out1, out_i);
    }
}

test "determinism: calibrate JSON output is byte-identical (10x)" {
    const estimates =
        \\{"estimated_total_micro_usd":1000000,"items":[{"resource_id":"a","estimated_micro_usd":1000000}]}
    ;
    const actuals =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.000000,1.000000,1,Tokens,Usage,a
    ;

    const opts: calibration.RunOptions = .{
        .estimates_path = "estimates.json",
        .actuals_path = "actuals.csv",
        .min_samples = 1,
    };

    const out1 = try mod.runCalibrateFromStrings(std.testing.allocator, estimates, actuals, opts, .json);
    defer std.testing.allocator.free(out1);

    // Run 10x
    for (0..10) |_| {
        const out_i = try mod.runCalibrateFromStrings(std.testing.allocator, estimates, actuals, opts, .json);
        defer std.testing.allocator.free(out_i);
        try std.testing.expectEqualStrings(out1, out_i);
    }
}
