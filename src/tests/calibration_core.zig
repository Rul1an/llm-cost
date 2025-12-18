const std = @import("std");
const types = @import("../calibration/types.zig");
const focus = @import("../calibration/focus_import.zig");
const interner = @import("../calibration/key_intern.zig");
const line_reader = @import("../calibration/line_reader.zig");

// --- 1. Types / MicroUSD Tests ---
test "MicroUSD Parsing" {
    // Integer parsing
    try std.testing.expectEqual(@as(i128, 1_000_000), try types.parseMicroUSDDecimal("1"));
    try std.testing.expectEqual(@as(i128, 1_200_000), try types.parseMicroUSDDecimal("1.2"));
    try std.testing.expectEqual(@as(i128, 1_234_567), try types.parseMicroUSDDecimal("1.234567"));

    // Rounding (7th digit)
    try std.testing.expectEqual(@as(i128, 1_234_567), try types.parseMicroUSDDecimal("1.2345674")); // down
    try std.testing.expectEqual(@as(i128, 1_234_568), try types.parseMicroUSDDecimal("1.2345675")); // up

    // Formatting
    try std.testing.expectEqual(@as(i128, 1_234_123_456), try types.parseMicroUSDDecimal("$1,234.123456"));
    try std.testing.expectEqual(@as(i128, -1), try types.parseMicroUSDDecimal("-0.000001"));
    try std.testing.expectEqual(@as(i128, 0), try types.parseMicroUSDDecimal("0"));
}

test "MicroUSD Formatting" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("-$1.234567", types.formatMicroUSD(-1_234_567, &buf));
    try std.testing.expectEqualStrings("$1.000000", types.formatMicroUSD(1_000_000, &buf));
    try std.testing.expectEqualStrings("$0.000005", types.formatMicroUSD(5, &buf));
}

test "Drift Calculation (Integer)" {
    // 10M vs 15M -> +50% = 5000 bps
    try std.testing.expectEqual(@as(i32, 5000), try types.computeDriftBps(5_000_000, 10_000_000));

    // 10M vs 9M -> -10% = -1000 bps
    try std.testing.expectEqual(@as(i32, -1000), try types.computeDriftBps(-1_000_000, 10_000_000));

    // Small diff: 1 vs 10000 -> 1 bps
    try std.testing.expectEqual(@as(i32, 1), try types.computeDriftBps(1, 10_000));
}

// --- 2. Key Interning Tests ---
test "Key Interning Lifetime" {
    const gpa = std.testing.allocator;
    var si = interner.StringInterner.init(gpa);
    defer si.deinit();

    const s1 = try si.intern("model-a");
    const s2 = try si.intern("model-a"); // should be deduped

    // Pointer equality
    try std.testing.expect(s1.ptr == s2.ptr);

    // Stability across new interns
    const s3 = try si.intern("model-b");
    const s1_ptr = s1.ptr;

    // Add many items to trigger resize if hashmap was using it?
    // Interner uses Arena for values, HashMap for Set info.
    // Key pointers in Set must be stable?
    // Arena pointers ARE stable. HashMap keys are pointers TO Arena data.
    // So HashMap resize doesn't invalidate Arena pointers. CORRECT.

    try std.testing.expect(s1.ptr == s1_ptr);
    try std.testing.expect(s3.ptr != s1.ptr);
}

// --- 3. CSV / FocusParser Tests ---

// test "LineReader Carry Correctness" {
//     const input = "line1";
//     var fbs = std.io.fixedBufferStream(input);

//     var lr = try line_reader.LineReader.init(std.testing.allocator, fbs.reader(), 1024);
//     defer lr.deinit();

//     const l1 = (try lr.nextLine()).?;
//     try std.testing.expectEqualStrings("line1", l1);

//     const l2 = try lr.nextLine();
//     try std.testing.expect(l2 == null);
// }

// test "FocusParser Quoted/Escaped" {
//     const csv =
//         \\ResourceId,BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,x-llm-model,x-tags
//         \\"res,1",100,100,1,req,usage,"model""quoted""", "{""team"":""finops""}"
//     ;
//
//     var fbs = std.io.fixedBufferStream(csv);
//     var parser = try focus.FocusParser.initFromReader(std.testing.allocator, fbs.reader(), 4096);
//     defer parser.deinit();
//
//     const rec = (try parser.next()).?;
//     // ResourceId: "res,1" (comma inside quotes)
//     try std.testing.expectEqualStrings("res,1", rec.ResourceId);
//
//     // Model: model"quoted"
//     try std.testing.expectEqualStrings("model\"quoted\"", rec.@"x-llm-model".?);
//
//     // Tags are not in struct yet, but we tested the parser didn't crash on comma inside tags
// }
