const std = @import("std");
const JsonValue = std.json.Value;

/// Input: OTel JSON string (full file content)
/// Output: FOCUS-ish CSV written to writer
pub fn convertJsonToFocusCsv(allocator: std.mem.Allocator, input_json: []const u8, writer: anytype) !void {
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, input_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;

    // Header
    try writer.writeAll("UsageStartTime,UsageEndTime,ChargeCategory,Provider,ResourceId,UsageQuantity,UsageUnit,x-token-count-input,x-token-count-output,Tags\n");

    const root = parsed.value.object;

    const resourceSpans = root.get("resourceSpans");
    if (resourceSpans == null or resourceSpans.? != .array) return; // Empty or invalid

    for (resourceSpans.?.array.items) |resSpan| {
        if (resSpan != .object) continue;

        const scopeSpans = resSpan.object.get("scopeSpans");
        if (scopeSpans == null or scopeSpans.? != .array) continue;

        for (scopeSpans.?.array.items) |scopeSpan| {
            if (scopeSpan != .object) continue;

            const spans = scopeSpan.object.get("spans");
            if (spans == null or spans.? != .array) continue;

            for (spans.?.array.items) |span| {
                if (span != .object) continue;
                try processSpan(allocator, span.object, writer);
            }
        }
    }
}

fn processSpan(allocator: std.mem.Allocator, span: std.json.ObjectMap, writer: anytype) !void {
    // Attributes map
    var attrs = std.StringHashMap([]const u8).init(allocator);
    defer attrs.deinit();

    // We also need integers for tokens
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;

    // Extract attributes
    if (span.get("attributes")) |attribs| {
        if (attribs == .array) {
            for (attribs.array.items) |attr| {
                if (attr != .object) continue;
                const k = attr.object.get("key");
                const v = attr.object.get("value");

                if (k != null and k.? == .string and v != null and v.? == .object) {
                    const key_str = k.?.string;
                    const val_obj = v.?.object;

                    // Robust value parsing (stringValue, intValue, doubleValue, etc.)
                    if (val_obj.get("stringValue")) |val| {
                        if (val == .string) try attrs.put(key_str, val.string);
                    } else if (val_obj.get("intValue")) |val| {
                        // OTel intValue can be string or int
                        const int_val: u64 = switch (val) {
                            .string => std.fmt.parseInt(u64, val.string, 10) catch 0,
                            .integer => @intCast(val.integer),
                            else => 0,
                        };
                        if (std.mem.eql(u8, key_str, "gen_ai.usage.input_tokens")) input_tokens = int_val;
                        if (std.mem.eql(u8, key_str, "gen_ai.usage.output_tokens")) output_tokens = int_val;
                    }
                }
            }
        }
    }

    // Filter: Must have model or be a relevant GenAI span
    const model = attrs.get("gen_ai.request.model") orelse return;

    // Fields
    const provider_raw = attrs.get("gen_ai.provider.name") orelse "Unknown";
    const provider = normalizeProvider(provider_raw);

    // Timestamps
    const start_time = parseNano(span.get("startTimeUnixNano"));
    const end_time = parseNano(span.get("endTimeUnixNano"));

    const start_iso = try fmtIso(allocator, start_time);
    defer allocator.free(start_iso);
    const end_iso = try fmtIso(allocator, end_time);
    defer allocator.free(end_iso);

    const usage_qty = input_tokens + output_tokens;

    // Tags Construction (JSON encoded)
    var tags_json = std.ArrayList(u8).init(allocator);
    defer tags_json.deinit();
    try tags_json.writer().writeAll("{");

    var first = true;

    // Trace ID
    if (span.get("traceId")) |tid| {
        if (tid == .string) {
            if (!first) try tags_json.writer().writeAll(",");
            try tags_json.writer().writeAll("\"trace_id\":\"");
            try writeEscapedJsonString(tags_json.writer(), tid.string);
            try tags_json.writer().writeAll("\"");
            first = false;
        }
    }

    // Agent
    if (attrs.get("gen_ai.agent.name")) |agent| {
        if (!first) try tags_json.writer().writeAll(",");
        try tags_json.writer().writeAll("\"agent\":\"");
        try writeEscapedJsonString(tags_json.writer(), agent);
        try tags_json.writer().writeAll("\"");
        first = false;
    }

    // Tool
    if (attrs.get("gen_ai.tool.name")) |tool| {
        if (!first) try tags_json.writer().writeAll(",");
        try tags_json.writer().writeAll("\"tool\":\"");
        try writeEscapedJsonString(tags_json.writer(), tool);
        try tags_json.writer().writeAll("\"");
        first = false;
    }

    try tags_json.writer().writeAll("}");

    // CSV Output: UsageStartTime,UsageEndTime,ChargeCategory,Provider,ResourceId,UsageQuantity,UsageUnit,x-token-count-input,x-token-count-output,Tags

    // Escape tags for CSV (doubled quotes)
    const tag_str = tags_json.items;
    var escaped_tags = std.ArrayList(u8).init(allocator);
    defer escaped_tags.deinit();
    try escaped_tags.append('"');
    for (tag_str) |c| {
        if (c == '"') try escaped_tags.append('"');
        try escaped_tags.append(c);
    }
    try escaped_tags.append('"');

    // Formula Injection Protection
    var safe_model: []const u8 = model;
    if (std.mem.startsWith(u8, safe_model, "=") or std.mem.startsWith(u8, safe_model, "+") or std.mem.startsWith(u8, safe_model, "-") or std.mem.startsWith(u8, safe_model, "@")) {
        safe_model = try std.fmt.allocPrint(allocator, "'{s}", .{model});
        // Note: we leak this small allocation for MVP safety, or use an arena.
        // Given allocator usage, this should be fine or we can optimize if needed.
    }
    const safe_provider = if (std.mem.startsWith(u8, provider, "=") or std.mem.startsWith(u8, provider, "+") or std.mem.startsWith(u8, provider, "-") or std.mem.startsWith(u8, provider, "@"))
        try std.fmt.allocPrint(allocator, "'{s}", .{provider})
    else
        provider;

    try writer.print("{s},{s},Usage,{s},{s},{d},Tokens,{d},{d},{s}\n", .{ start_iso, end_iso, safe_provider, safe_model, usage_qty, input_tokens, output_tokens, escaped_tags.items });
}

fn normalizeProvider(raw: []const u8) []const u8 {
    const s = raw;
    if (std.ascii.eqlIgnoreCase(s, "openai") or std.ascii.eqlIgnoreCase(s, "AzureOpenAI")) return "OpenAI";
    if (std.ascii.eqlIgnoreCase(s, "anthropic") or std.ascii.eqlIgnoreCase(s, "AnthropicAI")) return "Anthropic";
    if (std.ascii.eqlIgnoreCase(s, "azure")) return "Azure";
    if (std.ascii.eqlIgnoreCase(s, "google") or std.ascii.eqlIgnoreCase(s, "vertex")) return "Google";
    if (std.mem.eql(u8, s, "Unknown")) return "Unknown";
    return s;
}

fn parseNano(val: ?JsonValue) i64 {
    if (val == null) return 0;
    switch (val.?) {
        .string => |s| return std.fmt.parseInt(i64, s, 10) catch 0,
        .integer => |i| return @intCast(i),
        else => return 0,
    }
}

fn fmtIso(allocator: std.mem.Allocator, nanos: i64) ![]const u8 {
    // Convert to strict ISO8601 UTC: YYYY-MM-DDTHH:MM:SSZ
    if (nanos == 0) return allocator.dupe(u8, "1970-01-01T00:00:00Z");

    const total_seconds = @divFloor(nanos, 1_000_000_000);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, total_seconds)) };
    const day_seconds = es.getDaySeconds();
    const year_day = es.getEpochDay();
    const year = year_day.calculateYearDay();
    const month_day = year.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn writeEscapedJsonString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
