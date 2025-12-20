const std = @import("std");
const agentic = @import("../governance/agentic.zig");
const sarif = @import("sarif.zig");

/// Maps an Agentic Violation to a SARIF Result.
/// Note: Caller owns resulting memory (properties JSON string + result wrappers).
pub fn toSarifResult(
    allocator: std.mem.Allocator,
    v: agentic.Violation,
    default_artifact_uri: ?[]const u8,
) !sarif.Result {
    const artifact_uri = v.artifact orelse default_artifact_uri orelse "unknown";

    // Map Severity
    const level = switch (v.severity) {
        .warning => "warning",
        .@"error" => "error",
    };

    const rule_id = @tagName(v.rule);

    // Build Location
    var locations_arr = try allocator.alloc(sarif.Location, 1);
    locations_arr[0] = sarif.Location{
        .physicalLocation = .{
            .artifactLocation = .{ .uri = artifact_uri },
            .region = if (v.line) |l| .{ .startLine = l } else null,
        },
    };

    // Build Properties JSON Value
    const props = try buildPropertiesValue(allocator, v);

    return sarif.Result{
        .ruleId = rule_id,
        .level = level,
        .message = .{ .text = v.message },
        .locations = locations_arr,
        .properties = props,
    };
}

fn buildPropertiesValue(
    allocator: std.mem.Allocator,
    v: agentic.Violation,
) !?std.json.Value {
    const has_props =
        v.run_id != null or v.tool != null or v.model != null or
        v.actual != null or v.limit != null;

    if (!has_props) return null;

    var obj = std.json.ObjectMap.init(allocator);
    // Note: We transfer ownership of this map to the Value (and subsequently the caller)
    // so we do NOT errdefer/deinit here unless allocation fails before return.

    // Helper macro logic for optional strings
    if (v.run_id) |x| try obj.put("run_id", .{ .string = x });
    if (v.tool) |x| try obj.put("tool", .{ .string = x });
    if (v.model) |x| try obj.put("model", .{ .string = x });

    // Helper for floats
    if (v.actual) |x| try obj.put("actual", .{ .float = x });
    if (v.limit) |x| try obj.put("limit", .{ .float = x });

    if (v.actual) |a| {
        if (v.limit) |l| {
            if (l != 0) {
                const over_pct = (a / l - 1.0) * 100.0;
                try obj.put("overage_pct", .{ .float = over_pct });
            }
        }
    }

    return std.json.Value{ .object = obj };
}
