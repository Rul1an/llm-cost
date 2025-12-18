const std = @import("std");
const mod = @import("mod.zig");
const calibration = @import("calibration");

test "chunking: 1-byte reads == 16KB reads (simple CSV)" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.000000,1.000000,100,Tokens,Usage,a
        \\2.000000,2.000000,200,Tokens,Usage,b
        \\3.000000,3.000000,300,Tokens,Usage,c
    ;

    const tiny = try mod.parseActualsFromString(std.testing.allocator, csv, 1);
    const large = try mod.parseActualsFromString(std.testing.allocator, csv, 16 * 1024);

    try std.testing.expectEqual(tiny.record_count, large.record_count);
    try std.testing.expectEqual(tiny.total_cost, large.total_cost);
    try std.testing.expectEqual(tiny.total_quantity, large.total_quantity);
}

test "chunking: split exactly at newline boundary" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.000000,1.000000,1,Tokens,Usage,a
        \\2.000000,2.000000,2,Tokens,Usage,b
    ;

    // Force boundary in awkward places.
    const sizes = [_]usize{ 1, 2, 7, 31, 64 };
    var baseline: ?mod.ActualsSummary = null;

    for (sizes) |sz| {
        const s = try mod.parseActualsFromString(std.testing.allocator, csv, sz);
        if (baseline == null) baseline = s;
        try std.testing.expectEqual(baseline.?.record_count, s.record_count);
        try std.testing.expectEqual(baseline.?.total_cost, s.total_cost);
        try std.testing.expectEqual(baseline.?.total_quantity, s.total_quantity);
    }
}

test "chunking: split in middle of quoted field (consistency across sizes)" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.000000,1.000000,100,Tokens,Usage,"prompt,with,commas"
        \\2.000000,2.000000,200,Tokens,Usage,normal
    ;

    const sizes = [_]usize{ 1, 7, 15, 31, 64, 128, 1024 };
    var baseline: ?mod.Outcome = null;

    for (sizes) |sz| {
        const o = mod.parseOutcome(std.testing.allocator, csv, sz);

        if (baseline == null) baseline = o;

        switch (baseline.?) {
            .ok => |b| switch (o) {
                .ok => |s| {
                    try std.testing.expectEqual(b.record_count, s.record_count);
                    try std.testing.expectEqual(b.total_cost, s.total_cost);
                    try std.testing.expectEqual(b.total_quantity, s.total_quantity);
                },
                .err => return error.TestUnexpectedResult,
            },
            .err => |b_err| switch (o) {
                .err => |e| try std.testing.expectEqualStrings(b_err, e),
                .ok => return error.TestUnexpectedResult,
            },
        }
    }
}
