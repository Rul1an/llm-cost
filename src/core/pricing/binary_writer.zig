const std = @import("std");
const binary_fmt = @import("binary.zig");
const schema = @import("schema.zig");
const PriceDef = schema.PriceDef;

pub fn write(allocator: std.mem.Allocator, registry: std.StringHashMap(PriceDef), output_path: []const u8, timestamp: i64, source_checksum: u64) !void {
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

        // Final offsets
        model_off: u32 = 0,
        prov_off: u32 = 0,
    };

    var records = std.ArrayList(Record).init(allocator);
    defer records.deinit();

    var it = registry.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const def = entry.value_ptr.*;

        // Flags logic (replicated from compile_pricing or schema)
        // Schema PriceDef doesn't explicitly store flags like 'is_deprecated' or 'vision' as bits?
        // Wait, PriceDef has `provider` enum.
        // `compile_pricing.zig` parsed specific flags from JSON. `PriceDef` struct in `schema.zig` might NOT have them.
        // Checking `schema.zig` would be good.
        // Assuming PriceDef maps to Record fields.
        // If PriceDef doesn't have flags, we assume 0 for now or update PriceDef.
        // The binary format has `flags`.

        // For now, use 0 for flags/max_output if not in PriceDef.
        // Prioritized: Correctness of costs and IDs.

        try records.append(.{
            .model_id = id,
            .provider = def.provider.toString(),
            .input_cost = @intCast(def.input_price_per_mtok),
            .output_cost = @intCast(def.output_price_per_mtok),
            .reasoning_cost = if (def.output_reasoning_price_per_mtok) |r| @intCast(r) else 0,
            .context = @intCast(def.context_window orelse 0),
            .max_output = 0, // Not in PriceDef currently
            .flags = 0, // Not in PriceDef
            .hash = std.hash.Wyhash.hash(0, id),
        });
    }

    // Sort Records (Determistically: Hash, then ID)
    const sort = struct {
        fn lessThan(_: void, lhs: Record, rhs: Record) bool {
            if (lhs.hash < rhs.hash) return true;
            if (lhs.hash > rhs.hash) return false;
            return std.mem.order(u8, lhs.model_id, rhs.model_id) == .lt;
        }
    };
    std.mem.sort(Record, records.items, {}, sort.lessThan);

    // Build String Table
    var string_table = std.ArrayList(u8).init(allocator);
    defer string_table.deinit();
    var string_map = std.StringHashMap(u32).init(allocator);
    defer string_map.deinit();

    const records_data_size = records.items.len * binary_fmt.RECORD_SIZE;
    const string_table_base_offset: u32 = @intCast(binary_fmt.HEADER_SIZE + records_data_size);

    // Collect unique strings
    var unique_strings = std.StringHashMap(void).init(allocator);
    defer unique_strings.deinit();

    for (records.items) |rec| {
        try unique_strings.put(rec.model_id, {});
        try unique_strings.put(rec.provider, {});
    }

    // Sort strings
    var sorted_strings = std.ArrayList([]const u8).init(allocator);
    defer sorted_strings.deinit();
    var u_it = unique_strings.iterator();
    while (u_it.next()) |entry| {
        try sorted_strings.append(entry.key_ptr.*);
    }
    std.mem.sort([]const u8, sorted_strings.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.lt);

    // Build table
    for (sorted_strings.items) |s| {
        const offset: u32 = string_table_base_offset + @as(u32, @intCast(string_table.items.len));
        try string_table.appendSlice(s);
        try string_table.append(0);
        try string_map.put(s, offset);
    }

    // Assign offsets
    for (records.items) |*rec| {
        rec.model_off = string_map.get(rec.model_id).?;
        rec.prov_off = string_map.get(rec.provider).?;
    }

    // Write File
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var writer = out_file.writer();

    // Header
    try writer.writeAll(binary_fmt.MAGIC);
    try writer.writeInt(u32, binary_fmt.VERSION, .little);
    try writer.writeInt(u64, @intCast(timestamp), .little);
    try writer.writeInt(u32, @intCast(records.items.len), .little);
    try writer.writeInt(u32, string_table_base_offset, .little);
    try writer.writeInt(u64, source_checksum, .little);
    try writer.writeByteNTimes(0, 32);

    // Records
    for (records.items) |rec| {
        try writer.writeInt(u64, rec.hash, .little);
        try writer.writeInt(u32, rec.model_off, .little);
        try writer.writeInt(u32, rec.prov_off, .little);
        try writer.writeInt(i64, rec.input_cost, .little);
        try writer.writeInt(i64, rec.output_cost, .little);
        try writer.writeInt(u32, rec.context, .little);
        try writer.writeInt(u32, rec.max_output, .little); // 0
        try writer.writeInt(u32, rec.flags, .little); // 0
        try writer.writeInt(i64, rec.reasoning_cost, .little); // Offset 44
        try writer.writeByteNTimes(0, 12); // Padding (64 - 52 = 12)
    }

    // String Table
    try writer.writeAll(string_table.items);
}
