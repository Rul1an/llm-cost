const std = @import("std");
const mod = @import("mod.zig");
const calibration = @import("calibration");

fn makeCsv(allocator: std.mem.Allocator, rows: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId\n");
    for (rows) |row| {
        try buf.appendSlice(row);
        try buf.append('\n');
    }
    return try buf.toOwnedSlice();
}

test "permutation: shuffled rows -> same totals" {
    const rows = [_][]const u8{
        "1.000000,1.000000,100,Tokens,Usage,a",
        "2.000000,2.000000,200,Tokens,Usage,b",
        "3.000000,3.000000,300,Tokens,Usage,c",
        "4.000000,4.000000,400,Tokens,Usage,d",
        "5.000000,5.000000,500,Tokens,Usage,e",
    };

    const csv0 = try makeCsv(std.testing.allocator, &rows);
    defer std.testing.allocator.free(csv0);

    const base = try mod.parseActualsFromString(std.testing.allocator, csv0, 23);

    var prng = std.Random.DefaultPrng.init(42);
    var rnd = prng.random();

    // multiple permutations
    var shuffled: [rows.len][]const u8 = rows;
    for (0..10) |_| {
        rnd.shuffle([]const u8, &shuffled);

        const csv = try makeCsv(std.testing.allocator, &shuffled);
        defer std.testing.allocator.free(csv);

        const s = try mod.parseActualsFromString(std.testing.allocator, csv, 23);

        try std.testing.expectEqual(base.record_count, s.record_count);
        try std.testing.expectEqual(base.total_cost, s.total_cost);
        try std.testing.expectEqual(base.total_quantity, s.total_quantity);
    }
}
