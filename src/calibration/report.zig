const std = @import("std");
const types = @import("types.zig");
const mod = @import("mod.zig");

pub const OutputFormat = enum { table, json, toml };

pub fn format(r: mod.CalibrationResult, fmt: OutputFormat, w: anytype) !void {
    switch (fmt) {
        .table => try table(r, w),
        .json => try json(r, w),
        .toml => try toml(r, w),
    }
}

fn table(r: mod.CalibrationResult, w: anytype) !void {
    var b1: [48]u8 = undefined;
    var b2: [48]u8 = undefined;
    var b3: [48]u8 = undefined;

    try w.print(
        \\Calibration
        \\  estimated: {s}
        \\  actual:    {s}
        \\  drift:     {s} ({d} bps)
        \\  samples:   {d}
        \\  status:    {s}
        \\
    , .{
        types.formatMicroUSD(r.estimated_total, &b1),
        types.formatMicroUSD(r.actual_total, &b2),
        types.formatMicroUSD(r.drift_abs, &b3),
        r.drift_bps,
        r.sample_count,
        @tagName(r.status),
    });

    if (r.recommendations.len != 0) {
        try w.print("\nCost Optimization Opportunities\n", .{});
        for (r.recommendations) |rec| {
            var buf: [48]u8 = undefined;
            try w.print(
                "- {s} -> {s}: {d} bps, save {s}\n  {s}\n",
                .{
                    rec.current_model,
                    rec.alternative_model,
                    rec.savings_bps,
                    types.formatMicroUSD(rec.monthly_savings, &buf),
                    rec.rationale,
                },
            );
        }
    }
}

fn json(r: mod.CalibrationResult, w: anytype) !void {
    // Strict deterministic JSON: money as strings.
    var b1: [48]u8 = undefined;
    var b2: [48]u8 = undefined;
    var b3: [48]u8 = undefined;

    try w.print(
        \\{{"estimated_total":"{s}","actual_total":"{s}","drift":"{s}","drift_bps":{d},"sample_count":{d},"status":"{s}"
    , .{
        types.formatMicroUSD(r.estimated_total, &b1),
        types.formatMicroUSD(r.actual_total, &b2),
        types.formatMicroUSD(r.drift_abs, &b3),
        r.drift_bps,
        r.sample_count,
        @tagName(r.status),
    });

    if (r.recommendations.len != 0) {
        try w.print(",\"recommendations\":[", .{});
        for (r.recommendations, 0..) |rec, i| {
            if (i != 0) try w.print(",", .{});
            var buf: [48]u8 = undefined;
            try w.print(
                "{{\"current\":\"{s}\",\"alternative\":\"{s}\",\"savings_bps\":{d},\"monthly_savings\":\"{s}\",\"quality\":\"{s}\",\"rationale\":\"",
                .{
                    rec.current_model,
                    rec.alternative_model,
                    rec.savings_bps,
                    types.formatMicroUSD(rec.monthly_savings, &buf),
                    @tagName(rec.quality_impact),
                },
            );
            try jsonEscape(w, rec.rationale);
            try w.print("\"}}", .{});
        }
        try w.print("]", .{});
    }

    try w.print("}}\n", .{});
}

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.print("\\\"", .{}),
            '\\' => try w.print("\\\\", .{}),
            '\n' => try w.print("\\n", .{}),
            '\r' => try w.print("\\r", .{}),
            '\t' => try w.print("\\t", .{}),
            else => try w.writeByte(c),
        }
    }
}

fn toml(r: mod.CalibrationResult, w: anytype) !void {
    // minimal “ready to paste” knobs (extend later)
    try w.print(
        \\[calibration]
        \\drift_bps = {d}
        \\status = "{s}"
        \\
    , .{ r.drift_bps, @tagName(r.status) });
}
