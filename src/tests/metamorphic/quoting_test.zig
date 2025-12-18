const std = @import("std");
const mod = @import("mod.zig");
const calibration = @import("calibration");

test "quoting: quoted vs unquoted identical values" {
    const csv_unquoted =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.230000,1.230000,1000,Tokens,Usage,simple
    ;

    const csv_quoted =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\"1.230000","1.230000","1000","Tokens","Usage","simple"
    ;

    const a = try mod.parseActualsFromString(std.testing.allocator, csv_unquoted, 7);
    const b = try mod.parseActualsFromString(std.testing.allocator, csv_quoted, 7);

    try std.testing.expectEqual(a.record_count, b.record_count);
    try std.testing.expectEqual(a.total_cost, b.total_cost);
    try std.testing.expectEqual(a.total_quantity, b.total_quantity);
}

test "quoting: escaped quotes inside field does not crash and remains consistent" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.230000,1.230000,1000,Tokens,Usage,"prompt with ""quotes"" inside"
    ;

    const sizes = [_]usize{ 1, 3, 8, 17, 64 };
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

test "quoting: embedded newline in quoted field -> outcome stable across chunk sizes" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.230000,1.230000,1000,Tokens,Usage,"multi
        \\line
        \\field"
        \\2.000000,2.000000,2000,Tokens,Usage,normal
    ;

    // Many parsers treat this as RFC4180-valid, but our line-based parser may reject it.
    // Metamorphic requirement: never crash, and behavior must be consistent across chunk sizes.
    const sizes = [_]usize{ 1, 2, 7, 31, 64, 256 };
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

test "quoting: unterminated quote at EOF -> must not crash" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId
        \\1.230000,1.230000,1000,Tokens,Usage,"unclosed
    ;

    _ = mod.parseOutcome(std.testing.allocator, csv, 1);
    _ = mod.parseOutcome(std.testing.allocator, csv, 17);
    _ = mod.parseOutcome(std.testing.allocator, csv, 256);
    // If it errors, that's fine; the absence of a crash is the test.
}
