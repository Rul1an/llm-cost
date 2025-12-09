const std = @import("std");

pub const TokenId = u32;
pub const Index = u32;
pub const SENTINEL: Index = std.math.maxInt(Index);

/// Index-based linked list for efficient token merging.
/// Using Structure of Arrays (SoA) for better cache locality.
pub const TokenBuffer = struct {
    tokens: []TokenId,
    prev: []Index,
    next: []Index,
    valid: []bool,
    len: usize, // Current number of valid tokens

    pub fn init(allocator: std.mem.Allocator, initial_tokens: []const TokenId) !TokenBuffer {
        const n = initial_tokens.len;
        if (n >= SENTINEL) return error.InputTooLarge;

        const tokens = try allocator.alloc(TokenId, n);
        const prev = try allocator.alloc(Index, n);
        const next = try allocator.alloc(Index, n);
        const valid = try allocator.alloc(bool, n);

        @memcpy(tokens, initial_tokens);

        // Initialize linked list structure
        for (0..n) |i| {
            prev[i] = if (i == 0) SENTINEL else @intCast(i - 1);
            next[i] = if (i == n - 1) SENTINEL else @intCast(i + 1);
            valid[i] = true;
        }

        return .{
            .tokens = tokens,
            .prev = prev,
            .next = next,
            .valid = valid,
            .len = n,
        };
    }

    pub fn deinit(self: *TokenBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        allocator.free(self.prev);
        allocator.free(self.next);
        allocator.free(self.valid);
    }

    pub inline fn isValid(self: *const TokenBuffer, pos: Index) bool {
        return self.valid[pos];
    }

    pub fn merge(self: *TokenBuffer, left: Index, merged_token: TokenId) void {
        const right = self.next[left];
        // Invariant: right != SENTINEL and valid[left] and valid[right] checked by caller

        // Update left token
        self.tokens[left] = merged_token;

        // Unlink right
        const right_next = self.next[right];
        self.next[left] = right_next;
        if (right_next != SENTINEL) {
            self.prev[right_next] = left;
        }

        // Mark right as invalid
        self.valid[right] = false;
        self.prev[right] = SENTINEL;
        self.next[right] = SENTINEL;

        self.len -= 1;
    }

    /// Convert valid tokens back to a slice.
    /// Returns a slice allocated from `allocator`. Caller owns the memory.
    pub fn toSlice(self: *const TokenBuffer, allocator: std.mem.Allocator) ![]TokenId {
        const result = try allocator.alloc(TokenId, self.len);
        var res_idx: usize = 0;
        var curr: Index = 0; // Assuming 0 is always start if valid, loop below handles skip

        // Find first valid
        var i: usize = 0;
        while (i < self.valid.len) : (i += 1) {
            if (self.valid[i] and self.prev[i] == SENTINEL) {
                curr = @intCast(i);
                break;
            }
        }

        // If empty or all invalid (edge case, shouldn't happen with valid logic)
        if (res_idx >= self.len and self.len > 0) {
             // Fallback linear scan if head logic fails (sanity)
             i = 0;
             while(i < self.valid.len) : (i+=1) {
                 if(self.valid[i]) {
                     result[res_idx] = self.tokens[i];
                     res_idx += 1;
                 }
             }
             return result;
        }

        // Traverse list
        while (curr != SENTINEL) {
            result[res_idx] = self.tokens[curr];
            res_idx += 1;
            curr = self.next[curr];
        }

        return result;
    }
};


pub const MergeCandidate = struct {
    left_pos: Index,
    rank: u32,

    pub fn lessThan(context: void, a: MergeCandidate, b: MergeCandidate) bool {
        _ = context;
        if (a.rank < b.rank) return true;
        if (a.rank > b.rank) return false;
        if (a.left_pos < b.left_pos) return true;
        return false;
    }
};

pub const MergeQueue = struct {
    pq: std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan),

    pub fn init(allocator: std.mem.Allocator) MergeQueue {
        return .{
            .pq = std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan).init(allocator, {}),
        };
    }

    pub fn deinit(self: *MergeQueue) void {
        self.pq.deinit();
    }

    pub fn add(self: *MergeQueue, candidate: MergeCandidate) !void {
        try self.pq.add(candidate);
    }

    pub fn pop(self: *MergeQueue) ?MergeCandidate {
        return self.pq.removeOrNull();
    }
};


pub fn encodeLinear(
    allocator: std.mem.Allocator,
    initial_tokens: []const TokenId,
    merge_table: anytype,
) ![]TokenId {
    // 1. Static interface check for merge_table
    comptime {
         if (!@hasDecl(@TypeOf(merge_table.*), "lookup")) {
             @compileError("MergeTable must have a 'lookup(TokenId, TokenId)' method.");
         }
    }

    if (initial_tokens.len == 0) {
        return allocator.alloc(TokenId, 0); // Empty result
    }

    // 2. Init Buffer
    var buffer = try TokenBuffer.init(allocator, initial_tokens);
    defer buffer.deinit(allocator);

    // 3. Init Queue
    var queue = MergeQueue.init(allocator);
    defer queue.deinit();

    // 4. Seed initial candidates
    // Iterate 0..n-1 pairs
    var curr: Index = 0;
    while (buffer.next[curr] != SENTINEL) {
        const next = buffer.next[curr];
        if (merge_table.lookup(buffer.tokens[curr], buffer.tokens[next])) |entry| {
            try queue.add(.{ .left_pos = curr, .rank = entry.rank });
        }
        curr = next;
    }

    // 5. Merge Loop
    while (queue.pop()) |cand| {
        const left = cand.left_pos;

        // 4-point validation
        // (1) Left valid?
        if (!buffer.isValid(left)) continue;

        // (2) Right exists?
        const right = buffer.next[left];
        if (right == SENTINEL) continue;

        // (3) Right valid? (Should be implied by invariants, but check for safety)
        if (!buffer.isValid(right)) continue;

        // (4) Still same merge/rank?
        const current_merge = merge_table.lookup(buffer.tokens[left], buffer.tokens[right]);
        if (current_merge == null or current_merge.?.rank != cand.rank) continue;

        // Perform Merge
        const merge_data = current_merge.?;
        buffer.merge(left, merge_data.id);

        // Re-evaluate neighbors
        // Check new (prev, left) data
        const prev = buffer.prev[left];
        if (prev != SENTINEL and buffer.isValid(prev)) {
            if (merge_table.lookup(buffer.tokens[prev], buffer.tokens[left])) |m| {
                try queue.add(.{ .left_pos = prev, .rank = m.rank });
            }
        }

        // Check new (left, next) data
        const next = buffer.next[left];
        if (next != SENTINEL and buffer.isValid(next)) {
             if (merge_table.lookup(buffer.tokens[left], buffer.tokens[next])) |m| {
                try queue.add(.{ .left_pos = left, .rank = m.rank });
            }
        }
    }

    return buffer.toSlice(allocator);
}

// --- Tests ---

test "TokenBuffer: basic operations" {
    const allocator = std.testing.allocator;
    const input = [_]TokenId{ 1, 2, 3, 4, 5 };
    var buf = try TokenBuffer.init(allocator, &input);
    defer buf.deinit(allocator);

    try std.testing.expectEqual(buf.len, 5);
    try std.testing.expect(buf.isValid(0));
    try std.testing.expectEqual(buf.next[0], 1);

    // Merge (2,3) at index 1 -> new token 99
    // Input: 1, 2, 3, 4, 5
    // Index: 0, 1, 2, 3, 4
    // 2 is at index 1, 3 is at index 2.
    // merge(1, 99)
    buf.merge(1, 99);

    // State: 1, 99, 4, 5
    // buffer array: [1, 99, 3, 4, 5]
    // valid:        [T,  T, F, T, T]
    // next:         [1,  3, X, 4, S] (3 is index of '4')
    // prev:         [S,  0, X, 1, 3]

    try std.testing.expectEqual(buf.len, 4);
    try std.testing.expect(buf.isValid(1));
    try std.testing.expect(!buf.isValid(2)); // consumed
    try std.testing.expectEqual(buf.tokens[1], 99);
    try std.testing.expectEqual(buf.next[1], 3); // skips 2
    try std.testing.expectEqual(buf.prev[3], 1);

    const slice = try buf.toSlice(allocator);
    defer allocator.free(slice);

    try std.testing.expectEqualSlices(TokenId, &[_]TokenId{ 1, 99, 4, 5 }, slice);
}

test "BPE v2.1: manual merge logic" {
    const allocator = std.testing.allocator;

    // Mock Merge Table
    const MockEntry = struct { id: TokenId, rank: u32 };
    const MockTable = struct {
        pub fn lookup(_: *const @This(), left: TokenId, right: TokenId) ?MockEntry {
            // A=10, B=11, C=12
            // Merges:
            if (left == 10 and right == 11) return .{ .id = 20, .rank = 1 }; // A+B -> X (rank 1)
            if (left == 11 and right == 12) return .{ .id = 21, .rank = 2 }; // B+C -> Y (rank 2)
            if (left == 20 and right == 12) return .{ .id = 30, .rank = 3 }; // X+C -> Z (rank 3)
            return null;
        }
    };
    const table = MockTable{};

    // Case 1: A B C -> merges A+B first (rank 1) -> X C -> then X+C (rank 3) -> Z
    // result: Z (id 30)
    // If we did B+C first (rank 2), we'd get A Y. But A+B is rank 1 (better).
    const input = [_]TokenId{ 10, 11, 12 };

    const output = try encodeLinear(allocator, &input, &table);
    defer allocator.free(output);

    try std.testing.expectEqualSlices(TokenId, &[_]TokenId{30}, output);
}
