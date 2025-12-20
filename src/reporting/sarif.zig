const std = @import("std");
const agentic = @import("../governance/agentic.zig");
const adapter = @import("violation_adapter.zig");

// SARIF v2.1.0 Minimum Viable Structure
// Spec: https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html

pub const SarifLog = struct {
    version: []const u8 = "2.1.0",
    @"$schema": []const u8 = "https://json.schemastore.org/sarif-2.1.0.json",
    runs: []const Run,
};

pub const Run = struct {
    tool: Tool,
    results: []const Result,
};

pub const Tool = struct {
    driver: Driver,
};

pub const Driver = struct {
    name: []const u8 = "llm-cost",
    informationUri: []const u8 = "https://github.com/Rul1an/llm-cost",
    rules: []const Rule,
};

pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    shortDescription: Message,
    helpUri: []const u8 = "https://github.com/Rul1an/llm-cost/blob/main/docs/governance.md",
    properties: RuleProperties = .{},
};

pub const RuleProperties = struct {
    tags: []const []const u8 = &.{ "cost", "governance", "security" },
};

pub const Result = struct {
    ruleId: []const u8,
    level: []const u8, // "error", "warning", "note", "none" (default: "warning")
    message: Message,
    locations: []const Location,
    // Raw JSON object (pre-serialized) for dynamic properties
    properties: ?std.json.Value = null,
};

pub const Location = struct {
    physicalLocation: PhysicalLocation,
};

pub const PhysicalLocation = struct {
    artifactLocation: ArtifactLocation,
    region: ?Region = null,
};

pub const ArtifactLocation = struct {
    uri: []const u8,
};

pub const Region = struct {
    startLine: ?u32 = null,
};

pub const Message = struct {
    text: []const u8,
};

/// Generates a SARIF report from pre-converted Results.
/// Returns a JSON string (caller owns the memory).
pub fn generateReportFromResults(
    allocator: std.mem.Allocator,
    results: []const Result,
) ![]const u8 {
    // 1. Define Rules Metadata
    const rules = try allocator.alloc(Rule, 4);
    // TODO: Ideally share this with agentic enum, but hardcoding for MVP is fine
    rules[0] = .{ .id = "AGENT001", .name = "RunawayRun", .shortDescription = .{ .text = "Max cost per run exceeded" } };
    rules[1] = .{ .id = "AGENT002", .name = "RetryStorm", .shortDescription = .{ .text = "Excessive tool retries detected" } };
    rules[2] = .{ .id = "AGENT003", .name = "TokenExplosion", .shortDescription = .{ .text = "Token limit per step exceeded" } };
    rules[3] = .{ .id = "AGENT004", .name = "ShadowAI", .shortDescription = .{ .text = "Unauthorized model usage detected" } };

    // 2. Assemble Log
    const run = Run{
        .tool = .{
            .driver = .{
                .rules = rules,
            },
        },
        .results = results,
    };

    const runs = try allocator.alloc(Run, 1);
    runs[0] = run;

    const log = SarifLog{ .runs = runs };

    // 3. Serialize
    const json_string = try std.json.stringifyAlloc(allocator, log, .{ .whitespace = .indent_2 });

    // Cleanup intermediate arrays (rules, runs).
    // Do NOT free results or generic properties here as they belong to caller.
    allocator.free(rules);
    allocator.free(runs);

    return json_string;
}

/// Legacy wrapper for backward compat or direct use
pub fn generateReport(
    allocator: std.mem.Allocator,
    violations: []const agentic.Violation,
) ![]const u8 {
    var raw_results = std.ArrayList(Result).init(allocator);
    defer {
        for (raw_results.items) |*r| {
            allocator.free(r.locations);
            if (r.properties) |*p| {
                if (p.* == .object) p.object.deinit();
            }
        }
        raw_results.deinit();
    }

    for (violations) |v| {
        // Use adapter to convert
        const res = try adapter.toSarifResult(allocator, v, null);
        try raw_results.append(res);
    }

    return generateReportFromResults(allocator, raw_results.items);
}
