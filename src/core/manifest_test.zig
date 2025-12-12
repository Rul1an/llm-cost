const std = @import("std");
const manifest = @import("manifest.zig");
const testing = std.testing;

test "manifest: v1 backward compatibility" {
    const toml =
        \\[budget]
        \\max_cost_usd = 10.0
        \\warn_threshold = 0.9
        \\
        \\[policy]
        \\allowed_models = ["gpt-4o", "claude-3"]
    ;

    var policy = try manifest.parse(testing.allocator, toml);
    defer policy.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 10.0), policy.max_cost_usd.?);
    try testing.expectEqual(@as(f64, 0.9), policy.warn_threshold);
    try testing.expect(policy.allowed_models != null);
    try testing.expectEqual(@as(usize, 2), policy.allowed_models.?.len);
    try testing.expectEqualStrings("gpt-4o", policy.allowed_models.?[0]);
}

test "manifest: defaults section" {
    const toml =
        \\[defaults]
        \\model = "gpt-4o-mini"
    ;

    var policy = try manifest.parse(testing.allocator, toml);
    defer policy.deinit(testing.allocator);

    try testing.expect(policy.default_model != null);
    try testing.expectEqualStrings("gpt-4o-mini", policy.default_model.?);
}

test "manifest: array of prompts" {
    const toml =
        \\[[prompts]]
        \\path = "prompts/search.txt"
        \\prompt_id = "search"
        \\
        \\[[prompts]]
        \\path = "prompts/login.txt"
        \\# implied prompt_id null
    ;

    var policy = try manifest.parse(testing.allocator, toml);
    defer policy.deinit(testing.allocator);

    try testing.expect(policy.prompts != null);
    try testing.expectEqual(@as(usize, 2), policy.prompts.?.len);

    const p1 = policy.prompts.?[0];
    try testing.expectEqualStrings("prompts/search.txt", p1.path);
    try testing.expectEqualStrings("search", p1.prompt_id.?);

    const p2 = policy.prompts.?[1];
    try testing.expectEqualStrings("prompts/login.txt", p2.path);
    try testing.expect(p2.prompt_id == null);
}

test "manifest: inline tags table" {
    const toml =
        \\[[prompts]]
        \\path = "tagged.txt"
        \\tags = { team = "platform", tier = "critical" }
    ;

    var policy = try manifest.parse(testing.allocator, toml);
    defer policy.deinit(testing.allocator);

    try testing.expect(policy.prompts != null);
    const p = policy.prompts.?[0];
    try testing.expect(p.tags != null);

    const tags = p.tags.?;
    try testing.expectEqualStrings("platform", tags.get("team").?);
    try testing.expectEqualStrings("critical", tags.get("tier").?);
}
