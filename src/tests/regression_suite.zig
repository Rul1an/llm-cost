const std = @import("std");
const testing = std.testing;

const calibration = @import("calibration");
const Pricing = @import("pricing");
const key_intern = calibration.key_intern;
const manifest = @import("policy_manifest");
const helpers = @import("helpers");
const TestEnv = helpers.TestEnv;

fn runCalibrateFromStrings(
    allocator: std.mem.Allocator,
    estimates_json: []const u8,
    actuals_csv: []const u8,
    opts: calibration.RunOptions,
) !calibration.CalibrationResult {
    var env = TestEnv.init(allocator);
    defer env.deinit();

    try env.write("estimates.json", estimates_json);
    try env.write("actuals.csv", actuals_csv);

    // Mock Registry: Avoid dependency on embedded/cached DB
    const map = std.StringHashMap(Pricing.PriceDef).init(allocator);
    var registry = Pricing.Registry{
        .allocator = allocator,
        .backend = .{ .HashMap = map },
        .source = .Embedded,
        .generated_at = 0,
    };
    defer registry.deinit();

    var interner = key_intern.StringInterner.init(allocator);
    defer interner.deinit();

    // Coerce generic error set for withTempCwd compatibility (handles OS errors)
    const Wrapper = struct {
        fn run(a: std.mem.Allocator, o: calibration.RunOptions, r: *Pricing.Registry, i: *key_intern.StringInterner) anyerror!calibration.CalibrationResult {
            return calibration.run(a, o, r, i);
        }
    };

    const result = try helpers.withTempCwd(
        allocator,
        env.tmp.dir,
        Wrapper.run,
        .{ allocator, opts, &registry, &interner },
    );

    return result;
}

test "regression: v1.3 llm-cost.toml parsing" {
    const v1_3_toml =
        \\# llm-cost v1.3 style config
        \\[defaults]
        \\model = "gpt-4"
        \\[budget]
        \\max_cost_usd = 100.0
        \\[estimates]
        \\output = ".llm_cost/estimates.json"
        \\[pricing]
        \\cache_dir = ".cache/llm-cost"
    ;

    var policy = try manifest.parse(testing.allocator, v1_3_toml);
    defer policy.deinit(testing.allocator);

    // Assertions: Known fields parsed, unknown sections ignored
    try testing.expectEqualStrings("gpt-4", policy.default_model.?);
    try testing.expectEqual(100.0, policy.max_cost_usd.?);
}

test "regression: Vantage FOCUS 1.0 CSV ingestion" {
    const estimates =
        \\{ "estimated_total_micro": 1000000 }
    ;

    // Row 1: 10 micro, Row 2: 20 micro
    const actuals =
        \\ChargePeriodStart,ChargeCategory,BilledCost,ResourceId,ServiceName,Tags
        \\2025-01-01,Usage,0.000010,focus-id,LLM Inference,"{""model"":""gpt-4o"",""x-token-count-input"":2,""x-token-count-output"":0}"
        \\2025-01-01,Usage,0.000020,focus-id-2,LLM Inference,"{""model"":""gpt-4o-mini"",""x-token-count-input"":3,""x-token-count-output"":1}"
        \\
    ;

    const opts = calibration.RunOptions{
        .estimates_path = "estimates.json",
        .actuals_path = "actuals.csv",
        .min_samples = 1,
    };

    var result = try runCalibrateFromStrings(testing.allocator, estimates, actuals, opts);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.sample_count);
    try testing.expectEqual(@as(i128, 30), result.actual_total_micro);
}

test "regression: Vantage CSV without model degrades gracefully" {
    const estimates =
        \\{ "estimated_total_micro": 1000000 }
    ;

    // Missing 'model' key in tags
    const actuals =
        \\ChargePeriodStart,ChargeCategory,BilledCost,ResourceId,ServiceName,Tags
        \\2025-01-01,Usage,0.000010,focus-id,LLM Inference,"{""x-token-count-input"":2}"
        \\
    ;

    const opts = calibration.RunOptions{
        .estimates_path = "estimates.json",
        .actuals_path = "actuals.csv",
        .min_samples = 1,
    };

    var result = try runCalibrateFromStrings(testing.allocator, estimates, actuals, opts);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.sample_count);
    try testing.expectEqual(@as(i128, 10), result.actual_total_micro);
}
