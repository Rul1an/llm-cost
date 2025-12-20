const std = @import("std");
const focus = @import("focus_import.zig");

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    tags_map: std.StringHashMap([]const u8), // Logical name -> "Tags.key" or "ColumnName"

    /// Initialize the resolver with configuration defaults and overrides.
    /// The map deep copies the keys and values.
    pub fn init(allocator: std.mem.Allocator, config_tags: ?std.StringHashMap([]const u8)) !Resolver {
        var map = std.StringHashMap([]const u8).init(allocator);

        // Add defaults (ADR-008 D2)
        try put(&map, allocator, "agent", "Tags.agent");
        try put(&map, allocator, "tool", "Tags.tool");
        try put(&map, allocator, "workflow", "Tags.workflow");
        try put(&map, allocator, "trace_id", "Tags.trace_id");
        try put(&map, allocator, "model", "ResourceId"); // Special focus column

        // Apply overrides from config
        if (config_tags) |t| {
            var it = t.iterator();
            while (it.next()) |entry| {
                try put(&map, allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        return Resolver{
            .allocator = allocator,
            .tags_map = map,
        };
    }

    pub fn deinit(self: *Resolver) void {
        var it = self.tags_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tags_map.deinit();
    }

    /// Resolve a logical key (e.g., "agent") to a value from the record.
    pub fn resolve(self: *const Resolver, record: *const focus.FocusRecord, logical_key: []const u8) ?[]const u8 {
        // 1. Lookup path in map, or use logical_key as path
        const path = self.tags_map.get(logical_key) orelse logical_key;

        // 2. Resolve based on path type
        if (std.mem.startsWith(u8, path, "Tags.")) {
            // E.g. "Tags.my_agent" -> lookup "my_agent" in record.tags
            if (path.len > 5) {
                const tag_key = path[5..];
                return record.tags.get(tag_key);
            } else {
                return null;
            }
        } else {
            // Direct column access
            return record.getColumn(path);
        }
    }
};

fn put(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator, key: []const u8, val: []const u8) !void {
    // 1. Check if key exists and remove it (to free old memory)
    // Note: Use 'key' for lookup (slice equality), no need to dupe yet for lookup.
    if (map.fetchRemove(key)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }

    // 2. Insert new
    const k = try allocator.dupe(u8, key);
    const v = try allocator.dupe(u8, val);
    try map.put(k, v);
}
