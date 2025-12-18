const std = @import("std");

pub const TokenId = u32;
pub const Index = u32;
pub const SENTINEL: Index = std.math.maxInt(Index);

pub const MergeCandidate = struct {
    left_pos: Index,
    rank: u32,

    /// Comparator for PriorityQueue - Zig 0.14.0 requires std.math.Order return type
    pub fn lessThan(_: void, a: MergeCandidate, b: MergeCandidate) std.math.Order {
        // Lower rank = higher priority (min-heap)
        if (a.rank < b.rank) return .lt;
        if (a.rank > b.rank) return .gt;
        // Tie-breaker: lower position first (left-to-right)
        if (a.left_pos < b.left_pos) return .lt;
        if (a.left_pos > b.left_pos) return .gt;
        return .eq;
    }
};

/// Workspace for zero-allocation BPE encoding.
/// Reuses memory across specialized buffer arrays and the priority queue.
pub const BpeWorkspace = struct {
    // Buffers for index-based linked list (Structure of Arrays)
    tokens: std.ArrayList(TokenId),
    prev: std.ArrayList(Index),
    next: std.ArrayList(Index),
    valid: std.ArrayList(bool),

    // Custom Binary Heap (Min-Heap)
    // We manage the slice explicitly to allow O(1) clear.
    heap_items: std.ArrayList(MergeCandidate),
    heap_len: usize,

    pub fn init(allocator: std.mem.Allocator) BpeWorkspace {
        return .{
            .tokens = std.ArrayList(TokenId).init(allocator),
            .prev = std.ArrayList(Index).init(allocator),
            .next = std.ArrayList(Index).init(allocator),
            .valid = std.ArrayList(bool).init(allocator),
            .heap_items = std.ArrayList(MergeCandidate).init(allocator),
            .heap_len = 0,
        };
    }

    pub fn deinit(self: *BpeWorkspace) void {
        self.tokens.deinit();
        self.prev.deinit();
        self.next.deinit();
        self.valid.deinit();
        self.heap_items.deinit();
    }

    /// O(1) clear logic
    fn clear(self: *BpeWorkspace) void {
        self.tokens.clearRetainingCapacity();
        self.prev.clearRetainingCapacity();
        self.next.clearRetainingCapacity();
        self.valid.clearRetainingCapacity();
        self.heap_len = 0; // The crucial optimization
    }

    // Heap Helpers
    fn heapPush(self: *BpeWorkspace, item: MergeCandidate) !void {
        // Ensure capacity
        if (self.heap_len >= self.heap_items.items.len) {
            try self.heap_items.ensureTotalCapacity(self.heap_len + 1);
            self.heap_items.items.len = self.heap_items.capacity; // Unsafe? No, we own the memory.
            // Actually, simplest is just appendAssumeCapacity if we checked ensures.
            // But we want to reuse the slice size.
            // Let's use append logic but manage len.
        }
        // Expand logical slice if needed (ArrayList usually tracks items.len)
        // usage: heap_items is the storage. self.heap_len is the heap size.
        // We should keep heap_items.items.len high enough.
        if (self.heap_len == self.heap_items.items.len) {
            try self.heap_items.append(undefined);
        }

        self.heap_items.items[self.heap_len] = item;
        self.heapSiftUp(self.heap_len);
        self.heap_len += 1;
    }

    fn heapPop(self: *BpeWorkspace) ?MergeCandidate {
        if (self.heap_len == 0) return null;

        const top = self.heap_items.items[0];
        self.heap_len -= 1;

        if (self.heap_len > 0) {
            // Move last to top
            self.heap_items.items[0] = self.heap_items.items[self.heap_len];
            self.heapSiftDown(0);
        }

        return top;
    }

    fn heapSiftUp(self: *BpeWorkspace, start_index: usize) void {
        var index = start_index;
        const items = self.heap_items.items;
        while (index > 0) {
            const parent = (index - 1) / 2;
            if (compare(items[index], items[parent]) == .lt) {
                std.mem.swap(MergeCandidate, &items[index], &items[parent]);
                index = parent;
            } else {
                break;
            }
        }
    }

    fn heapSiftDown(self: *BpeWorkspace, start_index: usize) void {
        var index = start_index;
        const count = self.heap_len;
        const items = self.heap_items.items;

        while (true) {
            const left = 2 * index + 1;
            const right = 2 * index + 2;
            var smallest = index;

            if (left < count and compare(items[left], items[smallest]) == .lt) {
                smallest = left;
            }

            if (right < count and compare(items[right], items[smallest]) == .lt) {
                smallest = right;
            }

            if (smallest != index) {
                std.mem.swap(MergeCandidate, &items[index], &items[smallest]);
                index = smallest;
            } else {
                break;
            }
        }
    }

    fn compare(a: MergeCandidate, b: MergeCandidate) std.math.Order {
        return MergeCandidate.lessThan({}, a, b);
    }

    /// Encode a word (represented by initial tokens) using the providing merge table.
    /// Result is valid until next call to encode.
    /// Returns a slice of the internal tokens buffer.
    pub fn encode(self: *BpeWorkspace, initial_tokens: []const TokenId, merge_table: anytype) ![]const TokenId {
        // 1. Static interface check
        comptime {
            if (!@hasDecl(@TypeOf(merge_table.*), "lookup")) {
                @compileError("MergeTable must have a 'lookup(TokenId, TokenId)' method.");
            }
        }

        if (initial_tokens.len == 0) return &[_]TokenId{};

        // 2. Clear and ensure capacity
        self.clear();
        const n = initial_tokens.len;
        if (n >= SENTINEL) return error.InputTooLarge;

        try self.tokens.ensureTotalCapacity(n);
        try self.prev.ensureTotalCapacity(n);
        try self.next.ensureTotalCapacity(n);
        try self.valid.ensureTotalCapacity(n);

        // 3. Initialize buffers (append assumes capacity reserved)
        self.tokens.appendSliceAssumeCapacity(initial_tokens);

        for (0..n) |i| {
            self.prev.appendAssumeCapacity(if (i == 0) SENTINEL else @intCast(i - 1));
            self.next.appendAssumeCapacity(if (i == n - 1) SENTINEL else @intCast(i + 1));
            self.valid.appendAssumeCapacity(true);
        }

        var current_len = n;

        // 4. Seed Heap
        var curr: Index = 0;
        while (self.next.items[curr] != SENTINEL) {
            const next_idx = self.next.items[curr];
            if (merge_table.lookup(self.tokens.items[curr], self.tokens.items[next_idx])) |entry| {
                try self.heapPush(.{ .left_pos = curr, .rank = entry.rank });
            }
            curr = next_idx;
        }

        // 5. Merge Loop
        while (self.heapPop()) |cand| {
            const left = cand.left_pos;
            if (!self.valid.items[left]) continue;

            const right = self.next.items[left];
            if (right == SENTINEL) continue;
            if (!self.valid.items[right]) continue; // Should not happen if logic flows, but safe

            // Verify the pair is still the one that produced this rank
            const current_merge = merge_table.lookup(self.tokens.items[left], self.tokens.items[right]);
            if (current_merge == null or current_merge.?.rank != cand.rank) continue;

            // Apply Merge
            const merge_data = current_merge.?;
            self.tokens.items[left] = merge_data.id;

            // Unlink right
            const right_next = self.next.items[right];
            self.next.items[left] = right_next;
            if (right_next != SENTINEL) {
                self.prev.items[right_next] = left;
            }

            // Invalidate right
            self.valid.items[right] = false;
            // prev/next on invalidated node don't strictly matter if we valid check

            current_len -= 1;

            // Check neighbors for new merges
            const prev_idx = self.prev.items[left];
            if (prev_idx != SENTINEL) {
                if (merge_table.lookup(self.tokens.items[prev_idx], self.tokens.items[left])) |m| {
                    try self.heapPush(.{ .left_pos = prev_idx, .rank = m.rank });
                }
            }

            const next_idx = self.next.items[left];
            if (next_idx != SENTINEL) {
                if (merge_table.lookup(self.tokens.items[left], self.tokens.items[next_idx])) |m| {
                    try self.heapPush(.{ .left_pos = left, .rank = m.rank });
                }
            }
        }

        // 6. Compact result
        // Zero-alloc output extraction
        var write_idx: usize = 0;
        var walk: Index = SENTINEL;

        // Find head
        for (0..n) |i| {
            if (self.valid.items[i] and self.prev.items[i] == SENTINEL) {
                walk = @intCast(i);
                break;
            }
        }

        while (walk != SENTINEL) {
            self.tokens.items[write_idx] = self.tokens.items[walk];
            write_idx += 1;
            walk = self.next.items[walk];
        }

        self.tokens.items.len = write_idx;
        return self.tokens.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BpeWorkspace: basic encoding" {
    const allocator = std.testing.allocator;

    // Mock Merge Table
    const MockEntry = struct { id: TokenId, rank: u32 };
    const MockTable = struct {
        pub fn lookup(_: *const @This(), left: TokenId, right: TokenId) ?MockEntry {
            // A=10, B=11, C=12
            if (left == 10 and right == 11) return .{ .id = 20, .rank = 1 }; // A+B -> X
            if (left == 11 and right == 12) return .{ .id = 21, .rank = 2 }; // B+C -> Y
            if (left == 20 and right == 12) return .{ .id = 30, .rank = 3 }; // X+C -> Z
            return null;
        }
    };
    const table = MockTable{};

    var ws = BpeWorkspace.init(allocator);
    defer ws.deinit();

    // Case 1: A B C -> Z
    const input = [_]TokenId{ 10, 11, 12 };
    const output = try ws.encode(&input, &table);
    try std.testing.expectEqualSlices(TokenId, &[_]TokenId{30}, output);

    // Case 2: Reuse workspace
    // A B -> X (20)
    const input2 = [_]TokenId{ 10, 11 };
    const output2 = try ws.encode(&input2, &table);
    try std.testing.expectEqualSlices(TokenId, &[_]TokenId{20}, output2);
}
