const std = @import("std");
const types = @import("types.zig");
const focus = @import("focus_import.zig");
const Resolver = @import("tag_resolver.zig").Resolver;

/// Result of a breakdown aggregation.
/// Maps "group key" -> Stats.
/// Group key is comma-separated if multiple dimensions.
pub const BreakdownResult = struct {
    by_key: std.StringHashMap(GroupStats),

    // Also support convenience views?
    // ADR-008 says:
    // breakdown: {
    //   by_agent: { ... },
    //   by_tool: { ... },
    //   by_key: { ... } (composite)
    // }
    //
    // For MVP, we calculate `by_key` based on the requested group-by columns.
    // If user asks for `--group-by agent,tool`, we produce one map where keys are "agent=X,tool=Y" (or just "X,Y"? ADR says "agent=researcher|tool=web_search").
    // Let's stick to a robust canonical key format.
    // Or if asked for single dimension, key is just the value.

    allocator: std.mem.Allocator,

    pub fn deinit(self: *BreakdownResult) void {
        var it = self.by_key.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.by_key.deinit();
    }
};

pub const GroupStats = struct {
    cost_micro: i128 = 0,
    count: u64 = 0,
    tokens: u64 = 0,
};

pub const Aggregator = struct {
    allocator: std.mem.Allocator,
    resolver: Resolver,
    dimensions: [][]const u8,

    // Internal storage
    stats: std.StringHashMap(GroupStats),

    // Cardinality guard
    max_keys: u32,
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator, resolver: Resolver, dimensions: [][]const u8, max_keys: u32) Aggregator {
        return .{
            .allocator = allocator,
            .resolver = resolver, // Copy of struct (lightweight refs)
            .dimensions = dimensions,
            .stats = std.StringHashMap(GroupStats).init(allocator),
            .max_keys = max_keys,
        };
    }

    pub fn deinit(self: *Aggregator) void {
        var it = self.stats.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.stats.deinit();
    }

    pub fn update(self: *Aggregator, record: *const focus.FocusRecord) !void {
        // 1. Build Key
        var key_buf = std.ArrayList(u8).init(self.allocator);
        defer key_buf.deinit();

        // Strategy: if 1 dim, key = "value".
        // If >1 dim, key = "dim1=val1|dim2=val2" (ADR-008 recommendation).
        const multi_dim = self.dimensions.len > 1;

        for (self.dimensions, 0..) |dim, i| {
            if (i > 0) try key_buf.append('|');

            const val = self.resolver.resolve(record, dim) orelse "unknown"; // "unknown" or empty string? ADR D3 says defaults matter. unknown is safer.

            if (multi_dim) {
                try key_buf.writer().print("{s}={s}", .{ dim, val });
            } else {
                try key_buf.writer().print("{s}", .{val});
            }
        }

        // 2. Aggregate
        const key_slice = key_buf.items;

        // Check cardinality
        if (self.stats.count() >= self.max_keys) {
            // Already full? Check if key exists
            if (!self.stats.contains(key_slice)) {
                // New key, but full. Bucket to __other__.
                self.truncated = true;
                try self.addToKey("__other__", record);
                return;
            }
        }

        try self.addToKey(key_slice, record);
    }

    fn addToKey(self: *Aggregator, key: []const u8, record: *const focus.FocusRecord) !void {
        const result = try self.stats.getOrPut(key);
        if (!result.found_existing) {
            // Intern key
            result.key_ptr.* = try self.allocator.dupe(u8, key);
            result.value_ptr.* = GroupStats{};
        }

        var s = &result.value_ptr.*;
        s.cost_micro += record.BilledCost; // Consistency: use BilledCost (actuals)

        var t: u64 = 0;
        if (record.@"x-llm-input-tokens") |v| t += v;
        if (record.@"x-llm-output-tokens") |v| t += v;
        if (t == 0) t = record.UsageQuantity;

        s.tokens += t;
        s.count += 1;
    }

    pub fn finish(self: *Aggregator) BreakdownResult {
        // Move stats to result.
        // We rely on move semantics. StringHashMap doesn't have a clear move?
        // Actually, we can just return a struct wrapping the map, and invalidating self.
        // Or duplicate logic.
        // Better: BreakdownResult takes ownership of the map content.

        // We'll just clone keys/values or reuse the map if we deinit the aggregator without freeing keys.
        // But Aggregator.deinit frees keys.
        // Let's make Aggregator produce a Result and nullify its own map.

        const res = BreakdownResult{
            .by_key = self.stats,
            .allocator = self.allocator,
        };

        // Prevent double free
        self.stats = std.StringHashMap(GroupStats).init(self.allocator);
        return res;
    }
};
