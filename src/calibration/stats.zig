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

    // Guardrail Config
    max_unique_resources: u32,
    policy: types.CardinalityPolicy,

    // Observability
    unique_resources_seen: u64 = 0,
    cardinality_truncated: bool = false,

    // Internal: cached key for aggregation
    other_key_interned: ?[]const u8 = null,

    // Interned keys -> Aggregated Stats
    by_model: std.StringHashMapUnmanaged(ModelAgg) = .{},

    pub const ModelAgg = struct {
        count: u64 = 0,
        cost_micro: types.MicroUSD = 0,
        tokens: u64 = 0,
    };

    pub fn init(a: std.mem.Allocator, i: *intern.StringInterner, max_res: u32, pol: types.CardinalityPolicy) !CalibrationStats {
        // Guard: Ensure max is at least 1 to allow logic to work consistently
        const effective_max = if (max_res == 0) 1 else max_res;

        var self = CalibrationStats{
            .allocator = a,
            .interner = i,
            .max_unique_resources = effective_max,
            .policy = pol,
        };

        if (pol == .degrade) {
            // Option A: Pre-allocate __other__ as a valid slot.
            // This ensures max_unique_resources matches map.count() semantics accurately.
            const k = try i.intern("__other__");
            self.other_key_interned = k;

            // Insert immediately so it counts towards the limit
            try self.by_model.put(a, k, .{});
        }

        return self;
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
            // Intern key first? Or check existence?
            // Checking existence requires key.
            // Interning places it in arena.

            // Strategy: Check if we have it. If not, check capacity.
            // We need a lookup without full intern for efficiency? `interner` doesn't expose `get` easily without access.
            // But `intern` is fast.

            // Wait, we need to know if it's NEW to the *stats map*, not just the interner.
            // But to check the map we need the key.
            // If we intern every time, we fill the Arena. Valid concern for high cardinality denial of service?
            // "Prevent llm-cost ... from exhausting memory".
            // If we blindly intern 1M unique strings, we OOM the Arena.
            // So we should check `by_model` using a transient key if possible, OR rely on `makeUniqueName` logic?
            // `StringHashMap` uses string slice keys. We can lookup with `m` (slice) directly if we cast?
            // `StringHashMapUnmanaged` keys are `[]const u8`. `m` is `[]const u8`.
            // Yes, we can lookup using the raw slice `m` BEFORE interning!

            // BUT: `by_model` keys are *interned pointers*. The hash map compares *string content*?
            // `StringHashMap` hashes contents. So yes, look up by value is fine.

            var key_to_use: []const u8 = undefined;

            // 1. Check existing (no alloc)
            if (self.by_model.getEntry(m)) |entry| {
                // Exists (could be a normal key OR __other__ if m == "__other__")
                key_to_use = entry.key_ptr.*;
            } else {
                // New entry. Check limits.
                self.unique_resources_seen += 1;

                if (self.by_model.count() >= self.max_unique_resources) {
                    // Limit exceeded.
                    switch (self.policy) {
                        .@"error" => return error.CardinalityExceeded,
                        .degrade => {
                            self.cardinality_truncated = true;
                            // Safe: init guarantees this is set if policy == .degrade
                            key_to_use = self.other_key_interned.?;
                        },
                    }
                } else {
                    // Safe to add
                    key_to_use = try self.interner.intern(m);
                }
            }

            // Now update the map
            var gop = try self.by_model.getOrPut(self.allocator, key_to_use);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
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
