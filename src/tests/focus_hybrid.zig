const std = @import("std");
const focus = @import("../calibration/focus_import.zig");
const types = @import("../calibration/types.zig");

test "FOCUS v1.0: Detects version and parses standard cols" {
    const csv_data =
        \\BilledCost,EffectiveCost,ResourceId,ChargeCategory,UsageQuantity,UsageUnit
        \\1.00,1.00,res-1,Usage,1,Unit
    ;

    var fbs = std.io.fixedBufferStream(csv_data);
    var parser = try focus.FocusParser.initFromReader(std.testing.allocator, fbs.reader(), 1024);
    defer parser.deinit();

    try std.testing.expectEqual(focus.FocusVersion.v1_0, parser.version);

    const rec = (try parser.next()).?;
    try std.testing.expectEqualStrings("res-1", rec.ResourceId);
    try std.testing.expect(rec.InvoiceIssuerName == null);
}

test "FOCUS v1.2: Detects version and parses InvoiceIssuerName" {
    const csv_data =
        \\InvoiceIssuerName,BilledCost,EffectiveCost,ResourceId,ChargeCategory,UsageQuantity,UsageUnit
        \\AWS,2.00,2.00,res-2,Usage,1,Unit
    ;

    var fbs = std.io.fixedBufferStream(csv_data);
    var parser = try focus.FocusParser.initFromReader(std.testing.allocator, fbs.reader(), 1024);
    defer parser.deinit();

    try std.testing.expectEqual(focus.FocusVersion.v1_2, parser.version);

    const rec = (try parser.next()).?;
    try std.testing.expectEqualStrings("res-2", rec.ResourceId);
    try std.testing.expectEqualStrings("AWS", rec.InvoiceIssuerName.?);
}

test "FOCUS Hybrid: v1.2 headers but missing optional values produces null" {
    const csv_data =
        \\InvoiceIssuerName,BilledCost,EffectiveCost,ResourceId,ChargeCategory
        \\,3.00,3.00,res-3,Usage
    ;

    var fbs = std.io.fixedBufferStream(csv_data);
    var parser = try focus.FocusParser.initFromReader(std.testing.allocator, fbs.reader(), 1024);
    defer parser.deinit();

    try std.testing.expectEqual(focus.FocusVersion.v1_2, parser.version);

    const rec = (try parser.next()).?;
    // Empty field in CSV -> null (due to length check)
    try std.testing.expect(rec.InvoiceIssuerName == null);
}

test "FOCUS hybrid: v1.2 detected via InvoiceId only (no InvoiceIssuerName)" {
    const csv =
        \\BilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId,InvoiceId
        \\1.00,1.00,100,Tokens,Usage,res-a,INV-123
        \\
    ;

    var fbs = std.io.fixedBufferStream(csv);
    var parser = try focus.FocusParser.initFromReader(std.testing.allocator, fbs.reader(), 1024 * 1024);
    defer parser.deinit();

    try std.testing.expectEqual(focus.FocusVersion.v1_2, parser.version);

    const rec = (try parser.next()).?;
    // InvoiceId is not parsed into record yet, so just check it doesn't crash
    try std.testing.expect(rec.InvoiceIssuerName == null);
}

test "FOCUS hybrid: BOM in first header is tolerated" {
    const csv =
        "\xEF\xBB\xBFBilledCost,EffectiveCost,UsageQuantity,UsageUnit,ChargeCategory,ResourceId\n" ++
        "1.00,1.00,100,Tokens,Usage,res-a\n";

    var fbs = std.io.fixedBufferStream(csv);
    var parser = try focus.FocusParser.initFromReader(std.testing.allocator, fbs.reader(), 1024 * 1024);
    defer parser.deinit();

    try std.testing.expectEqual(focus.FocusVersion.v1_0, parser.version); // No v1.2 signals
    try std.testing.expect(parser.col.BilledCost != null); // BOM stripped correctly

    _ = (try parser.next()).?;
}
