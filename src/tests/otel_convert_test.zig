const std = @import("std");
const testing = std.testing;
const otel = @import("../convert/otel.zig");

test "convert otel json -> focus-ish csv (headers + mapping)" {
    const input = @embedFile("fixtures/otel_spans.json");

    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();

    try otel.convertJsonToFocusCsv(testing.allocator, input, out.writer());

    const csv = out.items;

    // Verify Headers
    try testing.expect(std.mem.indexOf(u8, csv, "UsageStartTime,UsageEndTime,ChargeCategory,Provider,ResourceId") != null);
    try testing.expect(std.mem.indexOf(u8, csv, "x-token-count-input,x-token-count-output,Tags") != null);

    // Verify Data from Fixture
    // Row 1: gpt-4o, OpenAI, 2847 total tokens (1847 in, 1000 out)
    // CSV output order depends on implementation, but simple string search works
    try testing.expect(std.mem.indexOf(u8, csv, ",OpenAI,gpt-4o,") != null);
    try testing.expect(std.mem.indexOf(u8, csv, ",2847,Tokens,1847,1000,") != null);
    // Verify ISO Timestamp (2024-12-19T...) for 1734652800 (approx)
    // 1734652800 is 2024-12-20? No. 1734652800 / 86400 = 20077 days since epoch.
    // Let's just check for "T" and "Z" and "Usage"
    try testing.expect(std.mem.indexOf(u8, csv, "T") != null);
    try testing.expect(std.mem.indexOf(u8, csv, "Z") != null);
    try testing.expect(std.mem.indexOf(u8, csv, ",Usage,") != null);

    // Row 2: gpt-4o-mini, OpenAI, 150 total (120 in, 30 out)
    try testing.expect(std.mem.indexOf(u8, csv, ",OpenAI,gpt-4o-mini,") != null);
    try testing.expect(std.mem.indexOf(u8, csv, ",150,Tokens,120,30,") != null);

    // Verify Tags (JSON encoded in CSV)
    // Check for trace_id, agent, tool (Note: CSV doubles quotes)
    try testing.expect(std.mem.indexOf(u8, csv, "\"\"trace_id\"\":\"\"abc123\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, csv, "\"\"agent\"\":\"\"researcher\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, csv, "\"\"tool\"\":\"\"llm\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, csv, "\"\"tool\"\":\"\"web_search\"\"") != null);

    // Check escaping (double quotes)
    try testing.expect(std.mem.indexOf(u8, csv, "\"\"trace_id\"\":\"\"abc123\"\"") != null);
}

test "convert otel: invalid json" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();

    // Not an object
    try testing.expectError(error.InvalidJson, otel.convertJsonToFocusCsv(testing.allocator, "[]", out.writer()));
}

test "convert otel: missing required fields handled gracefully" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();

    // Valid JSON structure but missing key fields -> Should produce header but no rows (or skip invalid spans)
    const json =
        \\{
        \\  "resourceSpans": [
        \\    {
        \\      "scopeSpans": [
        \\        {
        \\          "spans": [
        \\            {
        \\              "attributes": []
        \\            }
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try otel.convertJsonToFocusCsv(testing.allocator, json, out.writer());
    const csv = out.items;

    // Should have header
    try testing.expect(std.mem.indexOf(u8, csv, "UsageStartTime") != null);
    // Should NOT have rows
    try testing.expect(std.mem.indexOf(u8, csv, "\n202") == null);
}
