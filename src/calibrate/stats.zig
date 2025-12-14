const std = @import("std");
const agg = @import("aggregate.zig");

pub const DriftStatus = enum { ok, warning, error_, critical, no_baseline };

pub const Drift = struct {
    status: DriftStatus,
    /// signed drift in basis points (1 bp = 0.01%)
    /// +1000 = +10.00%, -250 = -2.50%
    drift_bps: i64,
};

/// Calculates drift in basis points from a Ratio.
/// Logic: ((num - den) * 10000) / den
pub fn driftFromRatio(r: ?agg.Ratio) Drift {
    if (r == null) return .{ .status = .no_baseline, .drift_bps = 0 };

    const ratio = r.?;
    var num = ratio.num;
    var den = ratio.den;

    // Normalize to positive denominator for consistent division behavior
    if (den < 0) {
        den = -den;
        num = -num;
    }

    if (den == 0) return .{ .status = .no_baseline, .drift_bps = 0 };

    const diff: i128 = num - den;
    const bps_i128: i128 = @divTrunc(diff * 10_000, den);

    // clamp into i64 (very extreme multipliers)
    const bps: i64 = if (bps_i128 > std.math.maxInt(i64)) std.math.maxInt(i64) else if (bps_i128 < std.math.minInt(i64)) std.math.minInt(i64) else @intCast(bps_i128);

    const abs_bps: u64 = @intCast(@abs(bps));
    const status: DriftStatus =
        if (abs_bps >= 10_000) .critical // >= 100%
        else if (abs_bps >= 5_000) .error_ // >= 50%
        else if (abs_bps >= 2_000) .warning // >= 20%
        else .ok;

    return .{ .status = status, .drift_bps = bps };
}

pub const Wilson = struct {
    /// center estimate in SCALE units (0..SCALE)
    center: u64,
    /// half-width in SCALE units
    half_width: u64,
};

pub const WilsonError = error{
    InvalidInput,
    Overflow,
};

/// 95% Confidence Interval (z approx 1.96)
pub fn wilson95(successes: u64, trials: u64) WilsonError!Wilson {
    // z for 95% approx 1.96 => store as fixed-point 1_960_000
    return wilsonInterval(successes, trials, 1_960_000);
}

/// Deterministic Wilson score interval for a proportion.
/// All internal math is integer/fixed-point (SCALE = 1_000_000). No floats.
///
/// z_fp is z in 1e6 scale (e.g. 1.96 -> 1_960_000).
pub fn wilsonInterval(successes: u64, trials: u64, z_fp: u64) WilsonError!Wilson {
    if (trials == 0) return error.InvalidInput;
    if (successes > trials) return error.InvalidInput;

    const SCALE: u128 = 1_000_000;

    const n: u128 = trials;
    const s: u128 = successes;

    // p_hat in fixed point
    const p_fp: u128 = (s * SCALE) / n;

    // z^2 in fixed point: (z_fp^2 / 1e6)
    const z2_fp: u128 = (@as(u128, z_fp) * @as(u128, z_fp)) / SCALE;

    // denom = 1 + z^2/n
    // in fixed-point SCALE: denom_fp = SCALE + z2_fp/n (since z2_fp is already scaled)
    const denom_fp: u128 = SCALE + z2_fp / n;

    // center numerator: p + z^2/(2n)
    // both in SCALE: center_num_fp = p_fp + z2_fp / (2 * n)
    const center_num_fp: u128 = p_fp + z2_fp / (2 * n);

    // center = center_num / denom
    const center_fp: u128 = (center_num_fp * SCALE) / denom_fp;

    // term under sqrt:
    // p(1-p)/n + z^2/(4n^2)
    // p_fp is SCALE, so p(1-p) in SCALE^2: p_fp*(SCALE - p_fp)
    const p_var_fp2: u128 = (p_fp * (SCALE - p_fp)) / n;

    // z^2/(4n^2) in SCALE^2
    const z_term_fp2: u128 = (z2_fp * SCALE) / (4 * n * n);

    const rad_fp2: u128 = p_var_fp2 + z_term_fp2;

    // sqrt(rad_fp2) returns SCALE units (because rad is SCALE^2)
    const sqrt_fp: u128 = isqrt_u128(rad_fp2);

    // half width: z * sqrt(...) / denom
    const half_num_fp: u128 = (@as(u128, z_fp) * sqrt_fp) / SCALE;

    const half_fp: u128 = (half_num_fp * SCALE) / denom_fp;

    return .{
        .center = @intCast(@min(@as(u128, 1_000_000), center_fp)),
        .half_width = @intCast(@min(@as(u128, 1_000_000), half_fp)),
    };
}

/// Deterministic integer sqrt for u128 (floor).
fn isqrt_u128(x: u128) u128 {
    if (x == 0) return 0;

    // Newton-Raphson integer sqrt
    var r: u128 = x;
    var prev: u128 = 0;

    while (r != prev) {
        prev = r;
        if (r == 0) break; // Should not trigger given x!=0 check loop, but safe
        r = (r + x / r) / 2;
    }
    // ensure floor
    while (true) {
        // Safe check for overflow x*x using @sqrt approximation
        if (r <= 18446744073709551615) { // maxInt(u64), so (r+1)^2 might fit u128
            if ((r + 1) * (r + 1) <= x) {
                r += 1;
                continue;
            }
        }
        if (r * r > x) {
            r -= 1;
            continue;
        }
        break;
    }
    return r;
}

test "Drift - Basic logic" {
    // 100 actual / 100 est = 0 drift
    const d1 = driftFromRatio(agg.Ratio{ .num = 100, .den = 100 });
    try std.testing.expectEqual(@as(i64, 0), d1.drift_bps);
    try std.testing.expect(d1.status == .ok);

    // 120 actual / 100 est = +20% = +2000 bps
    const d2 = driftFromRatio(agg.Ratio{ .num = 120, .den = 100 });
    try std.testing.expectEqual(@as(i64, 2000), d2.drift_bps);
    try std.testing.expect(d2.status == .warning); // >= 2000 is warning

    // 50 actual / 100 est = -50% = -5000 bps
    const d3 = driftFromRatio(agg.Ratio{ .num = 50, .den = 100 });
    try std.testing.expectEqual(@as(i64, -5000), d3.drift_bps);
    try std.testing.expect(d3.status == .error_);
}

test "Wilson - Basic bounds" {
    // p=0.28 (237/847)
    const w = try wilson95(237, 847);
    // center should be around 0.28 (280000)
    try std.testing.expect(w.center > 270_000 and w.center < 290_000);
    try std.testing.expect(w.half_width > 0);
}

test "Wilson - Extremes" {
    // 0/10
    const w0 = try wilson95(0, 10);
    try std.testing.expect(w0.center < 150_000); // dragged up from 0 (~138k)
    try std.testing.expect(w0.half_width > 0);

    // 10/10
    const w1 = try wilson95(10, 10);
    try std.testing.expect(w1.center > 800_000); // dragged down from 1 (~860k)
    try std.testing.expect(w1.half_width > 0);
}
test "Drift Robustness" {
    // 1. Baseline Zero
    const r_zero = agg.Ratio{ .num = 100, .den = 0 };
    const d_zero = driftFromRatio(r_zero);
    try std.testing.expectEqual(DriftStatus.no_baseline, d_zero.status);
    try std.testing.expectEqual(@as(i64, 0), d_zero.drift_bps);

    // 2. Large Values (Overflow check)
    // 1 Trillion USD (1e12) * 1e6 = 1e18 micros.
    // i128 max is ~3e38. Safe.
    const trillion: i128 = 1_000_000_000_000 * 1_000_000;
    const r_huge = agg.Ratio{ .num = trillion + (trillion / 10), .den = trillion }; // +10%
    const d_huge = driftFromRatio(r_huge);
    try std.testing.expectEqual(DriftStatus.ok, d_huge.status); // 1000 bps < 2000 warning
    try std.testing.expectEqual(@as(i64, 1000), d_huge.drift_bps);

    // 3. Negative Values (Refunds)
    // Est: -100, Act: -90. (Recieved less refund than expected -> Cost "Drift" relative to baseline?)
    // Math: (-90 - (-100)) / -100 = 10 / -100 = -10%.
    // Our logic normalizes den to 100, num to 90.
    // 90 - 100 = -10. -10/100 = -10%.
    // Result is consistent.
    const r_neg = agg.Ratio{ .num = -90, .den = -100 };
    const d_neg = driftFromRatio(r_neg);
    try std.testing.expectEqual(@as(i64, -1000), d_neg.drift_bps);

    // 4. Mixed Signs
    // Est: 100 (Cost), Act: -50 (Refund).
    // Math: (-50 - 100) / 100 = -150 / 100 = -150%.
    // HUGE savings.
    const r_mixed = agg.Ratio{ .num = -50, .den = 100 };
    const d_mixed = driftFromRatio(r_mixed);
    try std.testing.expectEqual(@as(i64, -15000), d_mixed.drift_bps);
    try std.testing.expectEqual(DriftStatus.critical, d_mixed.status);
}
