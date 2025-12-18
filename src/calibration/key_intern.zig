const std = @import("std");

/// Interns strings into an Arena so HashMap keys remain stable forever (per run).
pub const StringInterner = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    set: std.StringHashMapUnmanaged(void),

    pub fn init(gpa: std.mem.Allocator) StringInterner {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .set = .{},
        };
    }

    pub fn deinit(self: *StringInterner) void {
        self.set.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Returns a stable slice (arena-owned) that is pointer-equal for identical strings.
    pub fn intern(self: *StringInterner, s: []const u8) ![]const u8 {
        // Fast path: already interned
        if (self.set.getKey(s)) |existing| {
            return existing;
        }

        const dup = try self.arena.allocator().dupe(u8, s);
        try self.set.put(self.gpa, dup, {});
        return dup;
    }
};
