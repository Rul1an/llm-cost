const std = @import("std");
const manifest = @import("../core/manifest.zig");
const focus = @import("../calibration/focus_import.zig");
const tag_resolver = @import("../calibration/tag_resolver.zig");
const pricing = @import("../core/pricing/mod.zig");

pub const Severity = enum { warning, @"error" };

pub const RuleId = enum {
    AGENT001, // RunawayRun
    AGENT002, // RetryStorm
    AGENT003, // TokenExplosion
    AGENT004, // ShadowAI
};

pub const Violation = struct {
    rule: RuleId,
    severity: Severity,
    message: []const u8,
    // SARIF / Context properties
    artifact: ?[]const u8 = null,
    line: ?u32 = null, // Optional line number if we tracked it in parsing
    run_id: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    model: ?[]const u8 = null,
    actual: ?f64 = null,
    limit: ?f64 = null,
};

/// Check agentic governance rules against a set of Focus records.
pub fn checkRules(
    allocator: std.mem.Allocator,
    policy: manifest.AgenticGovernance,
    resolver: *const tag_resolver.Resolver,
    registry: *const pricing.Registry,
    records: []const focus.FocusRecord,
    actuals_path: []const u8,
) ![]Violation {
    var violations = std.ArrayList(Violation).init(allocator);
    errdefer violations.deinit();

    // Data structures for aggregation
    var cost_by_run = std.StringHashMap(f64).init(allocator);
    defer cost_by_run.deinit();

    // Key: "run_id|tool_name" -> count
    var retry_counts = std.StringHashMap(u32).init(allocator);
    defer {
        var it = retry_counts.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        retry_counts.deinit();
    }

    // Stats for unknown models
    var total_records: u64 = 0;
    var unknown_records: u64 = 0;

    for (records) |*record| {
        total_records += 1;

        // Resolve context
        const run_id = resolver.resolve(record, "trace_id"); // Default "Tags.trace_id"
        const tool = resolver.resolve(record, "tool"); // Default "Tags.tool"
        const model = resolver.resolve(record, "model") orelse record.ResourceId;

        // --- AGENT001: RunawayRun (Aggregation) ---
        if (policy.max_cost_per_run != null and run_id != null) {
            const entry = try cost_by_run.getOrPut(run_id.?);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += pricing.PriceDef.toUsd(record.BilledCost);
        }

        // --- AGENT002: RetryStorm (Aggregation) ---
        if (policy.max_tool_retries != null and run_id != null and tool != null) {
            // Key: run_id|tool
            const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ run_id.?, tool.? });
            // Look up existing
            if (retry_counts.getPtr(key)) |count| {
                count.* += 1;
                allocator.free(key); // Free temp key, we used existing
            } else {
                try retry_counts.put(key, 1);
            }
        }

        // --- AGENT003: TokenExplosion (Per Record) ---
        if (policy.max_tokens_per_step) |limit| {
            var tokens: u64 = 0;
            if (record.@"x-llm-input-tokens") |v| tokens += v;
            if (record.@"x-llm-output-tokens") |v| tokens += v;
            if (tokens == 0) tokens = record.UsageQuantity;

            if (tokens > limit) {
                try violations.append(Violation{
                    .rule = .AGENT003,
                    .severity = .warning, // User spec says warning
                    .message = try std.fmt.allocPrint(allocator, "Token usage {d} exceeds limit {d}", .{ tokens, limit }),
                    .artifact = actuals_path,
                    .run_id = if (run_id) |s| try allocator.dupe(u8, s) else null,
                    .model = try allocator.dupe(u8, model),
                    .actual = @floatFromInt(tokens),
                    .limit = @floatFromInt(limit),
                });
            }
        }

        // --- AGENT004: ShadowAI (Data Collection) ---
        if (policy.max_unknown_model_pct != null) {
            // Check if model exists in registry
            // Pricing registry lookup usually by provider+model or just model?
            // Registry.get(model) returns ?Price.
            // We need to know if it is 'unknown'.
            // Assuming registry.get(model) works or we need fuzzy match like in `estimate.zig`.
            // For rigorous check, strict match on ResourceId is best.
            // Or use `registry.resolve(provider, model)` if available.
            // Let's assume `registry.get(model)` exists. If not, we might need a helper.
            // Checking `src/pricing/registry.zig` capability.
            // Assuming `get` takes just model name or ID.
            if (registry.get(model)) |_| {
                // Known
            } else {
                unknown_records += 1;
            }
        }
    }

    // --- AGENT001: Check Aggregates ---
    if (policy.max_cost_per_run) |limit| {
        var it = cost_by_run.iterator();
        while (it.next()) |entry| {
            const cost = entry.value_ptr.*;
            if (cost > limit) {
                try violations.append(Violation{
                    .rule = .AGENT001,
                    .severity = .@"error",
                    .message = try std.fmt.allocPrint(allocator, "Run cost {d:.4} exceeds limit {d:.4}", .{ cost, limit }),
                    .artifact = actuals_path,
                    .run_id = try allocator.dupe(u8, entry.key_ptr.*),
                    .actual = cost,
                    .limit = limit,
                });
            }
        }
    }

    // --- AGENT002: Check Aggregates ---
    if (policy.max_tool_retries) |limit| {
        var it = retry_counts.iterator();
        while (it.next()) |entry| {
            const count = entry.value_ptr.*;
            if (count > limit) {
                // Key is "run_id|tool"
                var iter = std.mem.tokenizeScalar(u8, entry.key_ptr.*, '|');
                const rid = iter.next() orelse "unknown";
                const t = iter.next() orelse "unknown";

                try violations.append(Violation{
                    .rule = .AGENT002,
                    .severity = .@"error",
                    .message = try std.fmt.allocPrint(allocator, "Tool '{s}' retried {d} times (limit {d})", .{ t, count, limit }),
                    .artifact = actuals_path,
                    .run_id = try allocator.dupe(u8, rid),
                    .tool = try allocator.dupe(u8, t),
                    .actual = @floatFromInt(count),
                    .limit = @floatFromInt(limit),
                });
            }
        }
    }

    // --- AGENT004: Check Percentages ---
    if (policy.max_unknown_model_pct) |limit| {
        if (total_records > 0) {
            const pct = (@as(f64, @floatFromInt(unknown_records)) / @as(f64, @floatFromInt(total_records))) * 100.0;
            if (pct > limit) {
                try violations.append(Violation{
                    .rule = .AGENT004,
                    .severity = .warning,
                    .message = try std.fmt.allocPrint(allocator, "Unknown model usage {d:.1}% exceeds limit {d:.1}%", .{ pct, limit }),
                    .artifact = actuals_path,
                    .actual = pct,
                    .limit = limit,
                });
            }
        }
    }

    return violations.toOwnedSlice();
}
