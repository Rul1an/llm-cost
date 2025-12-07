const std = @import("std");
const engine = @import("../core/engine.zig");

pub const OutputFormat = engine.OutputFormat;

pub const ResultRecord = struct {
    model: []const u8,
    tokens_input: usize,
    tokens_output: usize = 0,
    tokens_reasoning: usize = 0,

    cost_usd: ?f64 = null,

    tokenizer: []const u8 = "unknown",
    approximate: bool = false,
};

pub fn formatOutput(
    allocator: std.mem.Allocator,
    writer: anytype,
    format: OutputFormat,
    data: ResultRecord,
) !void {
    switch (format) {
        .text => try renderText(writer, data),
        .json => try renderJson(allocator, writer, data),
        .ndjson => try renderNdjson(allocator, writer, data),
    }
}

fn renderText(writer: anytype, data: ResultRecord) !void {
    try writer.print("model: {s}\n", .{data.model});
    try writer.print("tokenizer: {s}\n", .{data.tokenizer});
    if (data.approximate) {
        try writer.print("approximate: true\n", .{});
    }
    try writer.print("tokens_input: {d}\n", .{data.tokens_input});
    if (data.tokens_output > 0) {
        try writer.print("tokens_output: {d}\n", .{data.tokens_output});
    }
    if (data.tokens_reasoning > 0) {
        try writer.print("tokens_reasoning: {d}\n", .{data.tokens_reasoning});
    }
    if (data.cost_usd) |cost| {
        try writer.print("cost_usd: {d:.6}\n", .{cost});
    }
}

fn renderJson(_: std.mem.Allocator, writer: anytype, data: ResultRecord) !void {
    // std.json.stringify requires an object, ResultRecord works directly
    try writer.print("{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })});
    try writer.print("\n", .{});
}

fn renderNdjson(_: std.mem.Allocator, writer: anytype, data: ResultRecord) !void {
    // NDJSON is just minified JSON + newline
    try writer.print("{f}", .{std.json.fmt(data, .{ .whitespace = .minified })});
    try writer.print("\n", .{});
}
