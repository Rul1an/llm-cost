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

        // Final offsets (filled later)
        model_off: u32 = 0,
        prov_off: u32 = 0,
    };

    var records = std.ArrayList(Record).init(allocator);
    defer records.deinit();

    // Extract Records
    const root = parsed.value;
    var models_obj = root;
    if (root == .object) {
        if (root.object.get("models")) |m| {
            models_obj = m;
        }
    }

    if (models_obj == .object) {
        var it = models_obj.object.iterator();
        while (it.next()) |entry| {
            const data = entry.value_ptr.*;
            if (data != .object) continue;

            const model_id = entry.key_ptr.*;
            // Get Provider
            var provider: []const u8 = "unknown";
            if (data.object.get("provider")) |p| {
                if (p == .string) provider = p.string;
            }

            // Get Costs (Convert f64 -> i64 microUSD)
            // Logic: @round(val * 1_000_000)
            const getMicro = struct {
                fn call(val: std.json.Value) i64 {
                    if (val == .float) return @intFromFloat(@round(val.float * 1_000_000.0));
                    if (val == .integer) return @intFromFloat(@round(@as(f64, @floatFromInt(val.integer)) * 1_000_000.0));
                    return 0;
                }
            }.call;

            var input: i64 = 0;
            if (data.object.get("input_price_per_mtok")) |v| input = getMicro(v);

            var output: i64 = 0;
            if (data.object.get("output_price_per_mtok")) |v| output = getMicro(v);

            var reasoning: i64 = 0;
            if (data.object.get("output_reasoning_price_per_mtok")) |v| reasoning = getMicro(v);

            var ctx: u32 = 0;
            if (data.object.get("context_window")) |v| if (v == .integer) {
                ctx = @intCast(v.integer);
            };

            var max_out: u32 = 0;
            if (data.object.get("max_output_tokens")) |v| if (v == .integer) {
                max_out = @intCast(v.integer);
            };

            var flags: u32 = 0;
            if (data.object.get("is_deprecated")) |v| if (v == .bool and v.bool) {
                flags |= 1;
            };
            if (data.object.get("capabilities")) |caps| {
                if (caps == .object) {
                    if (caps.object.get("vision")) |v| {
                        if (v == .bool and v.bool) flags |= 2;
                    }
                    if (caps.object.get("function_calling")) |v| {
                        if (v == .bool and v.bool) flags |= 4;
                    }
                }
            }

            try records.append(.{
                .model_id = model_id,
                .provider = provider,
                .input_cost = input,
                .output_cost = output,
                .reasoning_cost = reasoning,
                .context = ctx,
                .max_output = max_out,
                .flags = flags,
                .hash = std.hash.Wyhash.hash(0, model_id),
            });
        }
    }
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
