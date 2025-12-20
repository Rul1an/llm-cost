const std = @import("std");
const testing = std.testing;
const agentic = @import("../governance/agentic.zig");
const manifest = @import("../core/manifest.zig");
const focus = @import("../calibration/focus_import.zig");
const tag_resolver = @import("../calibration/tag_resolver.zig");
const Pricing = @import("../core/pricing/mod.zig");

// Helper to load fixture
fn loadCvs(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(focus.FocusRecord) {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var parser = try focus.FocusParser.initFromReader(allocator, f.reader(), 1024 * 1024);
    defer parser.deinit();

    var records = std.ArrayList(focus.FocusRecord).init(allocator);

    while (try parser.next()) |rec| {
        // Deep copy
        var copy = rec;
        copy.UsageUnit = try allocator.dupe(u8, rec.UsageUnit);
        copy.ChargeCategory = try allocator.dupe(u8, rec.ChargeCategory);
        copy.ResourceId = try allocator.dupe(u8, rec.ResourceId);
        if (rec.InvoiceIssuerName) |s| copy.InvoiceIssuerName = try allocator.dupe(u8, s);
        if (rec.@"x-llm-model") |s| copy.@"x-llm-model" = try allocator.dupe(u8, s);

        copy.tags = std.StringHashMap([]const u8).init(allocator);
        var it = rec.tags.iterator();
        while (it.next()) |entry| {
            const k = try allocator.dupe(u8, entry.key_ptr.*);
            const v = try allocator.dupe(u8, entry.value_ptr.*);
            try copy.tags.put(k, v);
        }
        try records.append(copy);
    }
    return records;
}

fn freeRecords(allocator: std.mem.Allocator, records: *std.ArrayList(focus.FocusRecord)) void {
    for (records.items) |*r| {
        allocator.free(r.UsageUnit);
        allocator.free(r.ChargeCategory);
        allocator.free(r.ResourceId);
        if (r.InvoiceIssuerName) |s| allocator.free(s);
        if (r.@"x-llm-model") |s| allocator.free(s);
        var it = r.tags.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        r.tags.deinit();
    }
    records.deinit();
}

test "AGENT001: RunawayRun" {
    const allocator = testing.allocator;

    var records = try loadCvs(allocator, "src/tests/fixtures/expensive_run.csv");
    defer freeRecords(allocator, &records);

    const policy = manifest.AgenticGovernance{
        .max_cost_per_run = 25.0, // Total is 30.0 in fixture
    };

    var resolver = try tag_resolver.Resolver.init(allocator, null);
    defer resolver.deinit();

    // Mock registry (or load real one if available, but mock struct is easier?)
    // agentic.checkRules only needs registry for AGENT004.
    // Assuming empty registry for now or minimal real one.
    // If Pricing.Registry requires loading file, we might skip AGENT004 here unless we mock it.
    // For AGENT001 it shouldn't matter.

    // Using real registry constructor might be heavy. Let's create an empty one?
    // Registry struct has private state?
    // Let's load the real registry.json/bin if possible, or skip registry for AGENT001.
    // Check `agentic.zig`: registry is used in AGENT004.
    // We can pass a pointer to a struct that mimics interface? No, Zig is typed.
    // We need an actual Registry instance.
    // Let's assume we can init a minimal registry or just load the default.

    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    const violations = try agentic.checkRules(allocator, policy, &resolver, &registry, records.items, "dummy.csv");
    defer {
        for (violations) |v| {
            allocator.free(v.message);
            if (v.run_id) |s| allocator.free(s);
            if (v.tool) |s| allocator.free(s);
            if (v.model) |s| allocator.free(s);
        }
        allocator.free(violations);
    }

    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(agentic.RuleId.AGENT001, violations[0].rule);
    try testing.expectEqual(agentic.Severity.@"error", violations[0].severity);
}

test "AGENT002: RetryStorm" {
    const allocator = testing.allocator;
    var records = try loadCvs(allocator, "src/tests/fixtures/retry_storm.csv"); // 4 entries
    defer freeRecords(allocator, &records);

    const policy = manifest.AgenticGovernance{
        .max_tool_retries = 3, // 4 entries > 3
    };

    var resolver = try tag_resolver.Resolver.init(allocator, null);
    defer resolver.deinit();
    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    const violations = try agentic.checkRules(allocator, policy, &resolver, &registry, records.items, "dummy.csv");
    defer {
        for (violations) |v| {
            allocator.free(v.message);
            if (v.run_id) |s| allocator.free(s);
            if (v.tool) |s| allocator.free(s);
            if (v.model) |s| allocator.free(s);
        }
        allocator.free(violations);
    }

    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(agentic.RuleId.AGENT002, violations[0].rule);
    try testing.expectEqual(agentic.Severity.@"error", violations[0].severity);
}

test "AGENT004: ShadowAI (Unknown Model)" {
    const allocator = testing.allocator;
    var records = try loadCvs(allocator, "src/tests/fixtures/unknown_model_mix.csv"); // 3 total, 1 unknown
    defer freeRecords(allocator, &records);

    // 1 unknown / 3 total = 33.3%
    const policy = manifest.AgenticGovernance{
        .max_unknown_model_pct = 10.0,
    };

    var resolver = try tag_resolver.Resolver.init(allocator, null);
    defer resolver.deinit();

    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();
    // Pre-populate registry with "gpt-4o" so it's known?
    // Registry.init likely loads from disk or embedded.
    // If "gpt-4o" is in defaults, great. "custom-finetune-7b" should be unknown.
    // We assume default DB has gpt-4o.

    const violations = try agentic.checkRules(allocator, policy, &resolver, &registry, records.items, "dummy.csv");
    defer {
        for (violations) |v| {
            allocator.free(v.message);
            if (v.run_id) |s| allocator.free(s);
            if (v.tool) |s| allocator.free(s);
            if (v.model) |s| allocator.free(s);
        }
        allocator.free(violations);
    }

    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(agentic.RuleId.AGENT004, violations[0].rule);
    try testing.expectEqual(agentic.Severity.warning, violations[0].severity);
}

test "Agentic Manifest Parsing" {
    const allocator = testing.allocator;
    const toml =
        \\
        \\[governance.agentic]
        \\max_cost_per_run = 10.5
        \\max_tool_retries = 5
        \\max_tokens_per_step = 1000
        \\max_unknown_model_pct = 20.0
        \\
    ;
    var policy = try manifest.parse(allocator, toml);
    defer policy.deinit(allocator);

    try testing.expectEqual(@as(?f64, 10.5), policy.agentic.max_cost_per_run);
    try testing.expectEqual(@as(?u32, 5), policy.agentic.max_tool_retries);
    try testing.expectEqual(@as(?u64, 1000), policy.agentic.max_tokens_per_step);
    try testing.expectEqual(@as(?f64, 20.0), policy.agentic.max_unknown_model_pct);
}
