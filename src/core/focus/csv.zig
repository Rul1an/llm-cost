const std = @import("std");
const schema = @import("schema.zig");

const ReservedTagKeys = struct {
    pub fn isReserved(key: []const u8) bool {
        // System / reserved keys (must not be overridden by user tags)
        return std.mem.eql(u8, key, "llm-cost-type") or
            std.mem.eql(u8, key, "focus-version") or
            std.mem.eql(u8, key, "focus-target") or
            std.mem.eql(u8, key, "provider") or
            std.mem.eql(u8, key, "model") or
            std.mem.eql(u8, key, "effective-cost") or
            std.mem.eql(u8, key, "resource-name") or
            std.mem.eql(u8, key, "x-token-count-input") or
            std.mem.eql(u8, key, "x-token-count-output") or
            std.mem.eql(u8, key, "x-cache-hit-ratio") or
            std.mem.eql(u8, key, "x-content-hash");
    }
};

pub const CsvWriter = struct {
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter) CsvWriter {
        return .{
            .writer = writer,
            .allocator = allocator,
        };
    }

    pub fn writeHeader(self: *CsvWriter) !void {
        for (schema.columns, 0..) |col, i| {
            if (i > 0) try self.writer.writeByte(',');
            try self.writer.writeAll(col);
        }
        try self.writer.writeByte('\n');
    }

    pub fn writeRow(self: *CsvWriter, row: schema.FocusRow) !void {
        // Vantage-supported FOCUS subset (strict):
        // ChargePeriodStart,ChargeCategory,BilledCost,ResourceId,ResourceType,RegionId,ServiceCategory,ServiceName,ConsumedQuantity,ConsumedUnit,Tags

        // ChargePeriodStart (YYYY-MM-DD, UTC)
        try self.writeEscaped(row.charge_period_start);
        try self.writer.writeByte(',');

        // ChargeCategory (Usage)
        try self.writeEscaped(row.charge_category);
        try self.writer.writeByte(',');

        // BilledCost (deterministic fixed-point string)
        const billed_cost_str = try self.costToString(row.billed_cost);
        defer self.allocator.free(billed_cost_str);
        try self.writer.writeAll(billed_cost_str);
        try self.writer.writeByte(',');

        // ResourceId (optional but recommended)
        try self.writeEscaped(row.resource_id);
        try self.writer.writeByte(',');

        // ResourceType (optional)
        try self.writeEscaped(row.resource_type);
        try self.writer.writeByte(',');

        // RegionId (optional; empty for global LLM APIs)
        try self.writeEscaped(row.region_id);
        try self.writer.writeByte(',');

        // ServiceCategory (optional)
        try self.writeEscaped(row.service_category);
        try self.writer.writeByte(',');

        // ServiceName (required by Vantage)
        try self.writeEscaped(row.service_name);
        try self.writer.writeByte(',');

        // ConsumedQuantity / ConsumedUnit (optional; unit only if quantity present)
        if (row.consumed_quantity) |q| {
            try self.writer.print("{d}", .{q});
            try self.writer.writeByte(',');
            try self.writeEscaped(row.consumed_unit);
        } else {
            try self.writer.writeByte(','); // empty ConsumedQuantity
            // ConsumedUnit must be empty if quantity is absent
        }
        try self.writer.writeByte(',');

        // Tags (JSON, deterministic ordering + reserved-key policy)
        const tags_json = try self.tagsToJson(row, billed_cost_str);
        defer self.allocator.free(tags_json);
        try self.writeEscaped(tags_json);

        try self.writer.writeByte('\n');
    }

    fn writeEscaped(self: *CsvWriter, value: []const u8) !void {
        // RFC 4180 escaping
        const needs_quotes = std.mem.indexOfAny(u8, value, ",\"\n\r") != null;
        if (needs_quotes) {
            try self.writer.writeByte('"');
            for (value) |c| {
                if (c == '"') {
                    try self.writer.writeByte('"');
                }
                try self.writer.writeByte(c);
            }
            try self.writer.writeByte('"');
        } else {
            try self.writer.writeAll(value);
        }
    }

    /// Convert cost to deterministic string:
    /// - Convert f64 -> pico-USD (1 USD = 1e12 pico) with rounding
    /// - Print as {dollars}.{fraction:0>12}
    fn costToString(self: *CsvWriter, cost_usd: f64) ![]const u8 {
        const scale: f64 = 1_000_000_000_000.0; // 1e12
        const sign: i128 = if (cost_usd < 0) -1 else 1;
        const abs = @abs(cost_usd);
        const pico_f = abs * scale;
        const pico_abs: i128 = @intFromFloat(@round(pico_f));
        const pico: i128 = pico_abs * sign;

        const dollars: i128 = @divTrunc(pico, 1_000_000_000_000);
        var frac: i128 = @mod(pico, 1_000_000_000_000);
        if (frac < 0) frac = -frac;

        return try std.fmt.allocPrint(self.allocator, "{d}.{d:0>12}", .{ @as(i64, @intCast(dollars)), @as(u64, @intCast(frac)) });
    }

    fn tagsToJson(self: *CsvWriter, row: schema.FocusRow, billed_cost_str: []const u8) ![]const u8 {
        const CanonicalJsonWriter = @import("../json_canonical.zig").CanonicalJsonWriter;

        var jw = CanonicalJsonWriter.init(self.allocator);
        defer jw.deinit();

        // 1. Add System Tags (Fixed values or already strings)
        try jw.putString("llm-cost-type", "estimate");
        try jw.putString("focus-version", "1.0");
        try jw.putString("focus-target", "vantage");
        try jw.putString("provider", row.tags.provider);
        try jw.putString("model", row.tags.model);
        try jw.putString("effective-cost", billed_cost_str);
        try jw.putString("resource-name", row.resource_name);
        try jw.putString("x-content-hash", row.tags.content_hash);

        // 2. Add Metrics (Integers / Floats need formatting first? Or use putInt/put)
        // CanonicalJsonWriter.putInt supports stringify-able types.
        try jw.putInt("x-token-count-input", row.tags.token_count_input);
        try jw.putInt("x-token-count-output", row.tags.token_count_output);

        if (row.tags.cache_hit_ratio) |ratio| {
            // For floats, we want specific precision formatting before putting
            const ratio_s = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{ratio});
            defer self.allocator.free(ratio_s);
            // Since split logic expects pre-encoded or we use putString...
            // Wait, ratio_s is raw string "0.50". putString will quote it: "0.50".
            // Correct. Ratios in JSON are usually numbers, but FOCUS metadata might be strings or numbers.
            // Original implementation was: "x-cache-hit-ratio": "0.50" (String).
            // Let's stick to string for metadata to be safe, or number?
            // Previous code: formatted with {d:.2} then appended with quotes. So it was a string.
            try jw.put("x-cache-hit-ratio", ratio_s);
        }

        // 3. Add User Tags (Filter reserved)
        if (row.tags.user_tags.count() > 0) {
            var it = row.tags.user_tags.keyIterator();
            while (it.next()) |k| {
                if (ReservedTagKeys.isReserved(k.*)) continue;
                const v = row.tags.user_tags.get(k.*) orelse continue;
                try jw.putString(k.*, v);
            }
        }

        // 4. Emit
        var json_buf = std.ArrayList(u8).init(self.allocator);
        errdefer json_buf.deinit();

        try jw.write(json_buf.writer());
        return json_buf.toOwnedSlice();
    }

    /// Escape special characters for JSON string values
    /// Handles: " \ newline carriage-return tab
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
