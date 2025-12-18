const std = @import("std");
// Build system exposes binary format module
const binary_fmt = @import("binary_pricing");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <input.json> <output.bin>\n", .{args[0]});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    const json_content = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(json_content);

    // 1. Calculate Checksum (Source of truth)
    const source_checksum = std.hash.Wyhash.hash(0, json_content);

    // 2. Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // 3. Intermediate Representation
    const Record = struct {
        model_id: []const u8,
        provider: []const u8,
        input_cost: i64,
        output_cost: i64,
        reasoning_cost: i64,
        context: u32,
        max_output: u32,
        flags: u32,
        hash: u64,
// ...
            var reasoning: i64 = 0;
            if (data.object.get("output_reasoning_price_per_mtok")) |v| reasoning = getMicro(v);

            var ctx: u32 = 0;
// ...
            try records.append(.{
                .model_id = model_id,
                .provider = provider,
                .input_cost = input,
                .output_cost = output,
                .reasoning_cost = reasoning,
                .context = ctx,
// ...
    // Records
    var zeroes: [64]u8 = undefined;
    @memset(&zeroes, 0);

    for (records.items) |rec| {
        try writer.writeInt(u64, rec.hash, .little); // 0
        try writer.writeInt(u32, rec.model_off, .little); // 8
        try writer.writeInt(u32, rec.prov_off, .little); // 12
        try writer.writeInt(i64, rec.input_cost, .little); // 16
        try writer.writeInt(i64, rec.output_cost, .little); // 24
        try writer.writeInt(u32, rec.context, .little); // 32
        try writer.writeInt(u32, rec.max_output, .little); // 36
        try writer.writeInt(u32, rec.flags, .little); // 40
        try writer.writeInt(i64, rec.reasoning_cost, .little); // 44
        // Padding (52 to 64 = 12 bytes)
        try writer.writeByteNTimes(0, 12);
    }

    // String Table
    try writer.writeAll(string_table.items);

    std.debug.print("Compiled: {d} records, {d} table bytes.\n", .{ records.items.len, string_table.items.len });
}
