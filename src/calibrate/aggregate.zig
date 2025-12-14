const std = @import("std");
const Allocator = std.mem.Allocator;

/// Rational representation of multiplier (no floats)
pub const Ratio = struct {
    num: i128,  // actual
    den: i128,  // estimate (never 0 if Ratio exists)
};

pub const GroupKey = struct {
    model: []const u8,      // interned in perm arena
    scenario: []const u8,   // interned in perm arena

    pub const Context = struct {
        pub fn hash(_: Context, k: GroupKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.model);
            h.update(&[_]u8{0}); // separator
            h.update(k.scenario);
            return h.final();
        }

        pub fn eql(_: Context, a: GroupKey, b: GroupKey) bool {
            return std.mem.eql(u8, a.model, b.model) and
                   std.mem.eql(u8, a.scenario, b.scenario);
        }
    };
};

pub const Aggregate = struct {
    sum_est_micro: i128 = 0,
    sum_act_micro: i128 = 0,
    n_rows: u64 = 0,           // FOCUS line items
    n_calls: u64 = 0,          // x-call-count sum (for confidence)
    sum_abs_err_micro: i128 = 0,

    // Cache statistics
    cache_hit_calls: u64 = 0, // Sum of (call_count * hit_ratio)
    cache_calls: u64 = 0,     // Sum of call_count where ratio was present

    /// Add a matched pair to this aggregate
    pub fn add(self: *Aggregate, est: i128, act: i128, call_count: u64) !void {
        self.sum_est_micro = try std.math.add(i128, self.sum_est_micro, est);
        self.sum_act_micro = try std.math.add(i128, self.sum_act_micro, act);
        self.n_rows += 1;
        self.n_calls += call_count;

        const diff = act - est;
        const abs_diff = if (diff < 0) -diff else diff;
        self.sum_abs_err_micro = try std.math.add(i128, self.sum_abs_err_micro, abs_diff);
    }

    /// Add cache statistics (deterministic rounding)
    pub fn addCache(self: *Aggregate, call_count: u64, ppm: u64) void {
        const SCALE: u128 = 1_000_000;
        const cc: u128 = call_count;
        const ratio: u128 = ppm; // ppm is 0..1M

        // hits = round_half_up(cc * ppm / SCALE)
        const prod: u128 = cc * ratio;
        const hits: u128 = (prod + (SCALE / 2)) / SCALE;

        self.cache_calls += call_count;
        self.cache_hit_calls += @intCast(hits);
    }

    /// Returns null if no baseline (est == 0)
    pub fn multiplierRatio(self: Aggregate) ?Ratio {
        if (self.sum_est_micro == 0) return null;
        return Ratio{
            .num = self.sum_act_micro,
            .den = self.sum_est_micro,
        };
    }
};

pub const GroupMap = std.HashMapUnmanaged(
    GroupKey,
    Aggregate,
    GroupKey.Context,
    80, // load factor percent
);

/// Interns strings to avoid duplication.
/// Uses perm allocator for storage, gpa for the map.
pub const StringInterner = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *StringInterner, gpa: Allocator) void {
        self.map.deinit(gpa);
    }

    pub fn intern(self: *StringInterner, gpa: Allocator, perm: Allocator, s: []const u8) ![]const u8 {
        if (self.map.get(s)) |v| return v; // lookup by bytes is ok
        const dup = try perm.dupe(u8, s);  // key must be perm-lived
        try self.map.put(gpa, dup, dup);
        return dup;
    }
};

test "Aggregate.add overflow protection" {
    var agg: Aggregate = .{};

    // Should not overflow
    try agg.add(std.math.maxInt(i128) / 2, std.math.maxInt(i128) / 2, 1);

    // Should error on overflow
    try std.testing.expectError(
        error.Overflow,
        agg.add(std.math.maxInt(i128), 1, 1),
    );
}

test "Aggregate.multiplierRatio no baseline" {
    var agg: Aggregate = .{};
    agg.sum_act_micro = 100;
    agg.sum_est_micro = 0;

    try std.testing.expect(agg.multiplierRatio() == null);
}

test "Aggregate.addCache rounding" {
    var agg: Aggregate = .{};

    // 10 calls, 0.95 hit ratio (950_000 ppm) -> 9.5 hits -> rounds to 10
    agg.addCache(10, 950_000);
    try std.testing.expectEqual(@as(u64, 10), agg.cache_calls);
    try std.testing.expectEqual(@as(u64, 10), agg.cache_hit_calls);

    // 100 calls, 0.001234 hit ratio (1234 ppm) -> 0.1234 hits -> rounds to 0
    agg.addCache(100, 1234);
    try std.testing.expectEqual(@as(u64, 110), agg.cache_calls);
    try std.testing.expectEqual(@as(u64, 10), agg.cache_hit_calls);

    // 100 calls, 0.005001 hit ratio (5001 ppm) -> 0.5001 hits -> rounds to 1
    agg.addCache(100, 5001);
    try std.testing.expectEqual(@as(u64, 210), agg.cache_calls);
    try std.testing.expectEqual(@as(u64, 11), agg.cache_hit_calls);
}
