const std = @import("std");
const types = @import("types.zig");
const focus = @import("focus_import.zig");
const intern = @import("key_intern.zig");

pub const CalibrationStats = struct {
    allocator: std.mem.Allocator,
    interner: *intern.StringInterner,

    sample_count: u64 = 0,
    total_cost_micro: types.MicroUSD = 0,

    // optional counters
    earliest_ts: ?i64 = null,
    latest_ts: ?i64 = null,

    // Example: per-model spend (interned keys)
    by_model: std.StringHashMapUnmanaged(ModelAgg) = .{},

    pub const ModelAgg = struct {
        count: u64 = 0,
        cost_micro: types.MicroUSD = 0,
        tokens: u64 = 0,
    };

    pub fn init(a: std.mem.Allocator, i: *intern.StringInterner) CalibrationStats {
        return .{ .allocator = a, .interner = i };
    }

    pub fn deinit(self: *CalibrationStats) void {
        self.by_model.deinit(self.allocator);
    }

    pub fn update(self: *CalibrationStats, r: focus.FocusRecord) !void {
        self.sample_count += 1;
        self.total_cost_micro += r.BilledCost;

        if (r.timestamp) |ts| {
            if (self.earliest_ts == null or ts < self.earliest_ts.?) self.earliest_ts = ts;
            if (self.latest_ts == null or ts > self.latest_ts.?) self.latest_ts = ts;
        }

        if (r.@"x-llm-model") |m| {
            const key = try self.interner.intern(m);
            var gop = try self.by_model.getOrPut(self.allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.count += 1;
            gop.value_ptr.cost_micro += r.BilledCost;
        }
    }

    pub fn daysCovered(self: *const CalibrationStats) u32 {
        if (self.earliest_ts == null or self.latest_ts == null) return 0;
        const delta = self.latest_ts.? - self.earliest_ts.?;
        return @intCast(@divTrunc(delta, 86400) + 1);
    }
};
