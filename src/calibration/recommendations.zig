const std = @import("std");
const types = @import("types.zig");
const stats_mod = @import("stats.zig");

pub const QualityImpact = enum { unknown, same_family, different_family };

pub const Recommendation = struct {
    current_model: []const u8,
    alternative_model: []const u8,

    savings_bps: i32, // -6200 = 62% cheaper
    monthly_savings_micro: types.MicroUSD, // based on observed spend
    rationale: []const u8, // small deterministic string

    quality_impact: QualityImpact = .unknown,
};

pub const Options = struct {
    top_k_models: usize = 10,
    max_alternatives_per_model: usize = 5,
    min_savings_bps: i32 = 500, // 5% (filter noise)
};

pub fn generate(
    allocator: std.mem.Allocator,
    s: *const stats_mod.CalibrationStats,
    pricing_registry: anytype,
    opts: Options,
) ![]Recommendation {
    // 1) collect model spend
    var models = std.ArrayList(ModelSpend).init(allocator);
    defer models.deinit();

    var it = s.by_model.iterator();
    while (it.next()) |e| {
        // key slices are interned => stable
        try models.append(.{
            .model = e.key_ptr.*,
            .cost_micro = e.value_ptr.cost_micro,
        });
    }

    // 2) sort by spend desc (deterministic)
    std.sort.pdq(ModelSpend, models.items, {}, ModelSpend.moreSpendFirst);

    const take = @min(opts.top_k_models, models.items.len);

    var recs = std.ArrayList(Recommendation).init(allocator);
    defer recs.deinit();

    for (models.items[0..take]) |ms| {
        const cur_def_opt = pricing_registry.get(ms.model);
        if (cur_def_opt == null) continue; // can't compare if not known
        const cur_def = cur_def_opt.?;

        // Gather cheaper candidates
        var cands = std.ArrayList(Candidate).init(allocator);
        defer cands.deinit();

        var pit = pricing_registry.iterator();
        while (pit.next()) |p| {
            const alt_name = p.key;
            const alt_def = p.value;

            if (std.mem.eql(u8, alt_name, ms.model)) continue;

            // Compare unit prices (micro-usd per 1 token)
            const cur_unit = unitPriceMicroPerToken(cur_def);
            const alt_unit = unitPriceMicroPerToken(alt_def);

            if (alt_unit >= cur_unit) continue;

            // savings ratio = (cur - alt) / cur
            // -> bps = round(ratio * 10000)
            const diff = cur_unit - alt_unit;
            const savings_bps = ratioToBpsInt(diff, cur_unit);

            // Expect positive savings_bps here because diff > 0
            if (savings_bps < opts.min_savings_bps) continue;

            // Monthly savings based on observed spend on current model
            // approx: spend * savings_ratio.
            // Note: savings_bps is positive here (percentage cheaper).
            // Logic: if 50% cheaper, savings is cost * 0.5.
            const monthly_savings_micro = microMulBps(ms.cost_micro, savings_bps);

            try cands.append(.{
                .alt = alt_name,
                .savings_bps = savings_bps, // positive: 9000 = 90% cheaper
                .monthly_savings_micro = monthly_savings_micro,
            });
        }

        // sort best savings first (highest positive savings)
        std.sort.pdq(Candidate, cands.items, {}, Candidate.bestFirst);

        const take2 = @min(opts.max_alternatives_per_model, cands.items.len);
        for (cands.items[0..take2]) |c| {
            const rationale = try std.fmt.allocPrint(
                allocator,
                "Observed spend on {s}; {s} is ~{d}% cheaper by list price.",
                .{ ms.model, c.alt, @divTrunc(@abs(c.savings_bps), 100) },
            );

            try recs.append(.{
                .current_model = ms.model,
                .alternative_model = c.alt,
                .savings_bps = c.savings_bps,
                .monthly_savings_micro = c.monthly_savings_micro,
                .rationale = rationale,
                .quality_impact = classifyFamily(ms.model, c.alt),
            });
        }
    }

    return recs.toOwnedSlice();
}

const ModelSpend = struct {
    model: []const u8,
    cost_micro: types.MicroUSD,

    fn moreSpendFirst(_: void, a: ModelSpend, b: ModelSpend) bool {
        // Desc cost; tie-break by lexicographic model for determinism
        if (a.cost_micro != b.cost_micro) return a.cost_micro > b.cost_micro;
        return std.mem.lessThan(u8, a.model, b.model);
    }
};

const Candidate = struct {
    alt: []const u8,
    savings_bps: i32,
    monthly_savings_micro: types.MicroUSD,

    fn bestFirst(_: void, a: Candidate, b: Candidate) bool {
        // a.savings_bps = 5000 (50%). b.savings_bps = 1000 (10%).
        // We want 5000 first.
        if (a.savings_bps != b.savings_bps) return a.savings_bps > b.savings_bps;
        return std.mem.lessThan(u8, a.alt, b.alt);
    }
};

fn unitPriceMicroPerToken(def: anytype) i128 {
    const in_u = @as(i128, def.input_price_per_mtok);
    const out_u = @as(i128, def.output_price_per_mtok);
    return @divTrunc(in_u + out_u, 2 * 1_000_000);
}

fn ratioToBpsInt(diff: i128, base: i128) i32 {
    if (base <= 0) return 0;
    var q = @divTrunc(diff * 10_000, base);
    const r = @rem(diff * 10_000, base);
    if (2 * r >= base) q += 1;
    return @intCast(q);
}

fn microMulBps(value: types.MicroUSD, bps: i32) types.MicroUSD {
    // value * bps / 10000 with rounding half-up
    const numer: i128 = value * @as(i128, bps);
    const neg = numer < 0;
    const abs_n = if (neg) -numer else numer;

    var q = @divTrunc(abs_n, 10_000);
    const r = @rem(abs_n, 10_000);
    if (2 * r >= 10_000) q += 1;
    return if (neg) -q else q;
}

fn classifyFamily(cur: []const u8, alt: []const u8) QualityImpact {
    const a = familyKey(cur);
    const b = familyKey(alt);
    if (a.len != 0 and std.mem.eql(u8, a, b)) return .same_family;
    return .different_family;
}

fn familyKey(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '-')) |i| return s[0..i];
    return s;
}
