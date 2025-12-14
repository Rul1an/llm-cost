const std = @import("std");
const agg = @import("aggregate.zig");
const focus = @import("focus_import.zig");

pub const EstimateMeta = struct {
    est_micro: i128,
    model: []const u8, // interned
    scenario: []const u8, // interned
    matched: bool = false,
    original_id: []const u8, // interned (for error reporting)
};

pub const EstimateIndex = std.StringHashMapUnmanaged(EstimateMeta);

pub const SampleBuffer = struct {
    buffer: [50][]const u8 = undefined,
    len: usize = 0,

    pub fn appendAssumeCapacity(self: *SampleBuffer, item: []const u8) void {
        self.buffer[self.len] = item;
        self.len += 1;
    }

    pub fn items(self: *const SampleBuffer) []const []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const JoinStats = struct {
    estimates_total: usize = 0,
    matched_rows: u64 = 0,
    unmatched_actuals: u64 = 0,
    unmatched_estimates: u64 = 0,

    // Bounded samples for error reporting
    unmatched_actual_samples: SampleBuffer = .{},
    unmatched_estimate_samples: SampleBuffer = .{},
};

pub const IdNormalization = enum {
    strict,
    fuzzy,
};

pub const JoinOptions = struct {
    max_groups: usize = 100_000,
    max_unmatched_samples: usize = 50,
    id_normalization: IdNormalization = .fuzzy,
};

pub const JoinResult = struct {
    stats: JoinStats,
    groups: agg.GroupMap,
    global: agg.Aggregate,
};

/// Runs the streaming join between estimates and actuals.
/// IteratorType must be focus.FocusIterator(Reader).
pub fn runJoin(
    comptime IteratorType: type,
    gpa: std.mem.Allocator,
    perm: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    estimates: *EstimateIndex,
    actuals_iter: *IteratorType,
    opts: JoinOptions,
) !JoinResult {
    var groups: agg.GroupMap = .{};
    errdefer groups.deinit(gpa);
    var global: agg.Aggregate = .{};
    var stats: JoinStats = .{};
    stats.estimates_total = estimates.count();

    // String interner for dynamic tags
    var interner = agg.StringInterner{};
    defer interner.deinit(gpa);

    while (true) {
        // Reset scratch arena for this row
        _ = scratch.reset(.retain_capacity);
        const scratch_alloc = scratch.allocator();

        const row_opt = actuals_iter.next(scratch_alloc) catch |err| {
            // EndOfStream handled by returning null loop?
            // FocusIterator.next returns !?RowView.
            // If error, propagate? Or break on EndOfStream if it were an error.
            // The iterator returns null on EOF.
            return err;
        };

        if (row_opt == null) break;
        const row = row_opt.?;

        // Normalize resource_id for matching
        const normalized_id = normalizeResourceId(row.resource_id, opts.id_normalization);

        // Lookup in estimate index
        // Note: normalized_id is a slice from scratch or row buffer.
        const meta_ptr = estimates.getPtr(normalized_id) orelse {
            stats.unmatched_actuals += 1;

            // Sample unmatched (bounded)
            if (stats.unmatched_actual_samples.len < opts.max_unmatched_samples) {
                // We must duplicate because row.resource_id is ephemeral
                // Storing in a bounded array inside stats which lives on stack/return?
                // These samples need to outlive the function if returned in JoinResult.
                // JoinResult has BoundedArray of slices? No, BoundedArray of u8?
                // Spec says BoundedArray([]const u8, 50).
                // So we need to allocate the strings in `perm` or use a specific arena for result strings?
                // `perm` is a good place.
                const duped = try perm.dupe(u8, row.resource_id);
                stats.unmatched_actual_samples.appendAssumeCapacity(duped);
            }
            continue;
        };

        meta_ptr.matched = true;

        // Determine group key (prefer actual tags, fall back to estimate)
        // IMPORTANT: We must INTERN the strings if they come from the row (scratch/buffer).
        // If they come from meta_ptr (estimates), they are already interned/perm.

        const model = if (row.model) |m| try interner.intern(gpa, perm, m) else meta_ptr.model;
        const scenario = if (row.scenario) |s| try interner.intern(gpa, perm, s) else meta_ptr.scenario;

        const key = agg.GroupKey{ .model = model, .scenario = scenario };

        // Guard against cardinality explosion
        if (groups.count() >= opts.max_groups and !groups.contains(key)) {
            return error.TooManyGroups;
        }

        // Get or create group aggregate
        const gop = groups.getOrPut(gpa, key) catch |err| {
            // If we fail here, groups map still holds memory but runJoin will return error.
            // But wait, runJoin moves `groups` to `JoinResult` on success.
            // On failure, `groups` inside runJoin is lost unless we deinit it there.
            // join.zig needs to handle cleanup on error if it owns `groups`.
            return err;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        // Extract values
        const est = meta_ptr.est_micro;
        const act = row.billed_cost; // MicroUSD from RowView
        const call_count = row.call_count orelse 1; // Default to 1 if missing

        // Update aggregates
        try gop.value_ptr.add(est, act, call_count);
        try global.add(est, act, call_count);

        if (row.cache_hit_ratio) |ppm| {
            gop.value_ptr.addCache(call_count, ppm);
            global.addCache(call_count, ppm);
        }

        stats.matched_rows += 1;
    }

    // Count unmatched estimates (single pass)
    var est_iter = estimates.iterator();
    while (est_iter.next()) |entry| {
        if (!entry.value_ptr.matched) {
            stats.unmatched_estimates += 1;

            if (stats.unmatched_estimate_samples.len < opts.max_unmatched_samples) {
                // key is already perm-allocated (estimate keys)
                // BUT we should verify if the key is safe to store directly.
                // Assuming EstimateIndex keys are permanent.
                stats.unmatched_estimate_samples.appendAssumeCapacity(entry.key_ptr.*);
            }
        }
    }

    return JoinResult{
        .stats = stats,
        .groups = groups,
        .global = global,
    };
}

pub fn normalizeResourceId(id: []const u8, mode: IdNormalization) []const u8 {
    if (mode == .strict) return id;

    // Strip known prefixes (longest first)
    const prefixes = [_][]const u8{
        "custom-llmcost/",
        "llm-cost/",
        "custom-",
    };

    var result = id;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, result, prefix)) {
            result = result[prefix.len..];
            break;
        }
    }

    return result;
}

test "Join - Basic Compilation Check" {
    // This test ensures that the file compiles and types are resolved correctly.
    // Full functional tests will be in Phase 5 (Verification).

    // Check struct existence
    const stats = JoinStats{};
    try std.testing.expect(stats.matched_rows == 0);

    // Check normalization basic
    const id = "custom-llmcost/foo";
    const norm = normalizeResourceId(id, .fuzzy);
    try std.testing.expectEqualStrings("foo", norm);
}
