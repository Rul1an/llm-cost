const std = @import("std");
const types = @import("calibration").types;
const mod = @import("mod.zig");
const calibration = @import("calibration");

test "roundtrip: MicroUSD format -> parse is lossless" {
    const vals = [_]types.MicroUSD{
        0,
        1,
        999_999, // $0.999999
        1_000_000, // $1.000000
        123_456_789_012, // $123456.789012
        -50_000_000, // -$50.000000
    };

    for (vals) |v| {
        var buf: [64]u8 = undefined;
        const s = types.formatMicroUSD(v, &buf);

        const parsed = try types.parseMicroUSDDecimal(s);
        try std.testing.expectEqual(v, parsed);
    }
}

test "roundtrip: parse tolerates commas, whitespace, and currency symbol" {
    const parsed = try types.parseMicroUSDDecimal("  $1,234.500006  ");
    // $1,234.500006 = 1_234_500_006 microUSD
    try std.testing.expectEqual(@as(types.MicroUSD, 1_234_500_006), parsed);
}
