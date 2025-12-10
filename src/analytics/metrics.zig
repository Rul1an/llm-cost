const std = @import("std");
const math = std.math;

/// Calculate Fertility: tokens per word
/// Lower is better (more efficient tokenization)
pub fn calculateFertility(tokens: usize, words: usize) f64 {
    if (words == 0) return 0.0;
    return @as(f64, @floatFromInt(tokens)) / @as(f64, @floatFromInt(words));
}

/// Calculate Parity Ratio: fertility relative to baseline
/// 1.0 = same as baseline, >1.0 = worse than baseline (more "taxed")
pub fn calculateParityRatio(fertility: f64, baseline_fertility: f64) f64 {
    if (baseline_fertility == 0.0) return 0.0;
    return fertility / baseline_fertility;
}

/// Calculate Gini Coefficient for a set of values
/// Formula: G = Σ|xi - xj| / (2n²x̄)
/// Returns 0.0 for perfect equality, approaches 1.0 for maximum inequality
pub fn calculateGini(values: []const f64) f64 {
    const n = values.len;
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;

    // Calculate mean
    var sum: f64 = 0.0;
    for (values) |v| {
        sum += v;
    }
    const mean = sum / @as(f64, @floatFromInt(n));

    if (mean == 0.0) return 0.0;

    // Calculate sum of absolute differences
    var diff_sum: f64 = 0.0;
    for (values) |xi| {
        for (values) |xj| {
            diff_sum += @abs(xi - xj);
        }
    }

    // Gini formula
    const n_f = @as(f64, @floatFromInt(n));
    return diff_sum / (2.0 * n_f * n_f * mean);
}

/// Calculate compression ratio: bytes per token
/// Higher is better (more bytes encoded per token)
pub fn calculateCompressionRatio(bytes: usize, tokens: usize) f64 {
    if (tokens == 0) return 0.0;
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(tokens));
}

// =============================================================================
// Tests
// =============================================================================

test "fertility: basic calculation" {
    // 125 tokens for 100 words = 1.25 fertility
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), calculateFertility(125, 100), 0.001);
}

test "fertility: zero words" {
    try std.testing.expectEqual(@as(f64, 0.0), calculateFertility(100, 0));
}

test "parity ratio: same as baseline" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), calculateParityRatio(1.25, 1.25), 0.001);
}

test "parity ratio: worse than baseline" {
    // 2.5 fertility vs 1.25 baseline = 2.0 parity ratio (2x worse)
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), calculateParityRatio(2.5, 1.25), 0.001);
}

test "gini: perfect equality" {
    // All same values = Gini of 0
    const values = [_]f64{ 1.0, 1.0, 1.0, 1.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), calculateGini(&values), 0.001);
}

test "gini: some inequality" {
    // Mixed values
    const values = [_]f64{ 1.0, 1.0, 1.0, 2.0 };
    const gini = calculateGini(&values);
    try std.testing.expect(gini > 0.0);
    try std.testing.expect(gini < 1.0);
}

test "gini: high inequality" {
    // One very high value
    const values = [_]f64{ 1.0, 1.0, 1.0, 100.0 };
    const gini = calculateGini(&values);
    try std.testing.expect(gini > 0.5); // Should be quite high
    try std.testing.expect(gini < 1.0);
}

test "gini: empty array" {
    const values = [_]f64{};
    try std.testing.expectEqual(@as(f64, 0.0), calculateGini(&values));
}

test "gini: single value" {
    const values = [_]f64{5.0};
    try std.testing.expectEqual(@as(f64, 0.0), calculateGini(&values));
}

test "compression ratio: basic" {
    // 1000 bytes / 200 tokens = 5.0 bytes per token
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), calculateCompressionRatio(1000, 200), 0.001);
}
