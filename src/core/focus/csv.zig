const std = @import("std");
const schema = @import("schema.zig");

pub const CsvWriter = struct {
    writer: std.fs.File.Writer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) CsvWriter {
        return .{
            .writer = file.writer(),
            .allocator = allocator,
        };
    }

    /// Write the strict FOCUS header
    pub fn writeHeader(self: *CsvWriter) !void {
        for (schema.columns, 0..) |col, i| {
            if (i > 0) try self.writer.writeByte(',');
            try self.writer.writeAll(col);
        }
        try self.writer.writeByte('\n');
    }

    /// Write a single row, freeing resources appropriately if managed internally?
    /// No, the caller owns the row. The writer just writes.
    pub fn writeRow(self: *CsvWriter, row: schema.FocusRow) !void {
        // 1. ChargePeriodStart
        try self.writeEscaped(row.charge_period_start);
        try self.writer.writeByte(',');

        // 2. ChargeCategory
        try self.writeEscaped(row.charge_category);
        try self.writer.writeByte(',');

        // 3. BilledCost (4 decimal precision)
        try self.writer.print("{d:.4}", .{row.billed_cost});
        try self.writer.writeByte(',');

        // 4. ResourceId
        try self.writeEscaped(row.resource_id);
        try self.writer.writeByte(',');

        // 5. ResourceType
        try self.writeEscaped(row.resource_type);
        try self.writer.writeByte(',');

        // 6. RegionId
        try self.writeEscaped(row.region_id);
        try self.writer.writeByte(',');

        // 7. ServiceCategory
        try self.writeEscaped(row.service_category);
        try self.writer.writeByte(',');

        // 8. ServiceName
        try self.writeEscaped(row.service_name);
        try self.writer.writeByte(',');

        // 9. ConsumedQuantity
        try self.writer.print("{d}", .{row.consumed_quantity});
        try self.writer.writeByte(',');

        // 10. ConsumedUnit
        try self.writeEscaped(row.consumed_unit);
        try self.writer.writeByte(',');

        // 11. Tags (JSON)
        const tags_json = try self.tagsToJson(row.tags);
        defer self.allocator.free(tags_json);
        try self.writeEscaped(tags_json);

        try self.writer.writeByte('\n');
    }

    /// Escape logic for CSV values:
    /// If value contains comma, double-quote, or newline, wrap in quotes and escape internal quotes.
    fn writeEscaped(self: *CsvWriter, value: []const u8) !void {
        var needs_escape = false;
        for (value) |c| {
            if (c == ',' or c == '"' or c == '\n' or c == '\r') {
                needs_escape = true;
                break;
            }
        }

        if (needs_escape) {
            try self.writer.writeByte('"');
            for (value) |c| {
                if (c == '"') {
                    try self.writer.writeAll("\"\"");
                } else {
                    try self.writer.writeByte(c);
                }
            }
            try self.writer.writeByte('"');
        } else {
            try self.writer.writeAll(value);
        }
    }

    /// Serialize tags HashMap to strict JSON string
    fn tagsToJson(self: *CsvWriter, tags: std.StringHashMap([]const u8)) ![]const u8 {
        var json = std.ArrayList(u8).init(self.allocator);
        errdefer json.deinit();

        try json.append('{');
        var it = tags.iterator();
        var index: usize = 0;
        while (it.next()) |entry| {
            if (index > 0) try json.append(',');

            try json.append('"');
            try self.appendJsonEscaped(&json, entry.key_ptr.*);
            try json.appendSlice("\":\"");
            try self.appendJsonEscaped(&json, entry.value_ptr.*);
            try json.append('"');

            index += 1;
        }
        try json.append('}');
        return json.toOwnedSlice();
    }

    /// Escape characters for JSON strings
    fn appendJsonEscaped(self: *CsvWriter, json: *std.ArrayList(u8), value: []const u8) !void {
        _ = self;
        for (value) |c| {
            switch (c) {
                '"' => try json.appendSlice("\\\""),
                '\\' => try json.appendSlice("\\\\"),
                '\n' => try json.appendSlice("\\n"),
                '\r' => try json.appendSlice("\\r"),
                '\t' => try json.appendSlice("\\t"),
                else => try json.append(c),
            }
        }
    }
};
