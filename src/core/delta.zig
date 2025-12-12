const std = @import("std");

pub const ChangeStatus = enum {
    increased, // Critical (Budget risk)
    added, // New cost
    decreased, // Savings
    removed, // Savings
    unchanged, // Neutral

    pub fn priority(self: ChangeStatus) u8 {
        return switch (self) {
            .increased => 1,
            .added => 2,
            .decreased => 3,
            .removed => 4,
            .unchanged => 5,
        };
    }
};

pub const CostDelta = struct {
    resource_id: []const u8,
    file_path: []const u8,
    base_cost: ?i128, // pico-USD, null = didn't exist
    head_cost: ?i128, // pico-USD, null = removed
    delta: i128, // head - base (treating null as 0)
    status: ChangeStatus,

    pub fn init(base: ?i128, head: ?i128, path: []const u8, resource_id: []const u8) CostDelta {
        const b = base orelse 0;
        const h = head orelse 0;
        const d = h - b;

        var s: ChangeStatus = .unchanged;
        if (base == null and head != null) {
            s = .added;
        } else if (head == null and base != null) {
            s = .removed;
        } else if (d > 0) {
            s = .increased;
        } else if (d < 0) {
            s = .decreased;
        }

        return .{
            .resource_id = resource_id,
            .file_path = path,
            .base_cost = base,
            .head_cost = head,
            .delta = d,
            .status = s,
        };
    }

    /// Sorts by: Importance (Status) ASC, Abs(Delta) DESC, ResourceId ASC
    pub fn lessThan(context: void, a: CostDelta, b: CostDelta) bool {
        _ = context;
        if (a.status != b.status) {
            return a.status.priority() < b.status.priority();
        }

        // Same status: check magnitude (absolute delta)
        const abs_a = if (a.delta < 0) -a.delta else a.delta;
        const abs_b = if (b.delta < 0) -b.delta else b.delta;

        if (abs_a != abs_b) {
            return abs_a > abs_b; // Descending magnitude
        }

        // Tie-break 1: Resource ID
        const rid_order = std.mem.order(u8, a.resource_id, b.resource_id);
        if (rid_order != .eq) return rid_order == .lt;

        // Tie-break 2: File Path (if resource IDs match, unlikely but possible with bad config)
        return std.mem.order(u8, a.file_path, b.file_path) == .lt;
    }
};

test "DeltaModel sorting" {
    const d1 = CostDelta.init(100, 200, "inc.txt", "a"); // Increased (+100)
    const d2 = CostDelta.init(null, 50, "add.txt", "b"); // Added (+50)
    const d3 = CostDelta.init(100, 50, "dec.txt", "c"); // Decreased (-50)
    const d4 = CostDelta.init(100, 100, "same.txt", "d"); // Unchanged (0)
    const d5 = CostDelta.init(100, 300, "big-inc.txt", "e"); // Increased (+200)

    var items = [_]CostDelta{ d4, d2, d1, d3, d5 };
    std.mem.sort(CostDelta, &items, {}, CostDelta.lessThan);

    try std.testing.expectEqualStrings("big-inc.txt", items[0].file_path);
    try std.testing.expectEqualStrings("inc.txt", items[1].file_path);
    try std.testing.expectEqualStrings("add.txt", items[2].file_path);
    try std.testing.expectEqualStrings("dec.txt", items[3].file_path);
    try std.testing.expectEqualStrings("same.txt", items[4].file_path);
}

test "DeltaModel zero vs null" {
    // Zero cost is NOT "Removed" if base was not null
    const d_zero = CostDelta.init(100, 0, "zero.txt", "z");
    try std.testing.expect(d_zero.status == .decreased);

    // Removed needs explicit null
    const d_removed = CostDelta.init(100, null, "gone.txt", "g");
    try std.testing.expect(d_removed.status == .removed);

    // Added needs explicit null base
    const d_added = CostDelta.init(null, 0, "new_free.txt", "n");
    // If added but cost is 0... technically added.
    try std.testing.expect(d_added.status == .added);
}
