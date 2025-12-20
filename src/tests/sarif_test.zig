const std = @import("std");
const testing = std.testing;
const sarif = @import("../reporting/sarif.zig");
const agentic = @import("../governance/agentic.zig");

test "SARIF: Generation" {
    const allocator = testing.allocator;

    var violations = std.ArrayList(agentic.Violation).init(allocator);
    defer violations.deinit();

    try violations.append(.{
        .rule = .AGENT001,
        .severity = .@"error",
        .message = "Run cost $1.50 exceeds limit $1.00",
        .artifact = "test.csv",
        .line = 2,
        .run_id = "trace-123",
        .actual = 1.50,
        .limit = 1.00,
    });

    const json = try sarif.generateReport(allocator, violations.items);
    defer allocator.free(json);

    // Simple string containment check to verify JSON structure
    try testing.expect(std.mem.indexOf(u8, json, "\"version\": \"2.1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"driver\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\": \"AGENT001\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"message\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "test.csv") != null);
}
