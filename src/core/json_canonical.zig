const std = @import("std");

/// A canonical JSON writer implementing a subset of RFC 8785 (JCS).
/// - Objects: keys are sorted lexicographically (UTF-16 code units / byte order).
/// - Whitespace: None.
/// - Strings: Standard JSON escaping.
pub const CanonicalJsonWriter = struct {
    allocator: std.mem.Allocator,
    fields: std.ArrayList(Field),

    const Field = struct {
        key: []const u8,
        value: []const u8,

        fn lessThan(_: void, a: Field, b: Field) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }

        fn deinit(self: Field, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            allocator.free(self.value);
        }
    };

    pub fn init(allocator: std.mem.Allocator) CanonicalJsonWriter {
        return .{
            .allocator = allocator,
            .fields = std.ArrayList(Field).init(allocator),
        };
    }

    pub fn deinit(self: *CanonicalJsonWriter) void {
        for (self.fields.items) |f| f.deinit(self.allocator);
        self.fields.deinit();
    }

    /// Add a pre-encoded JSON value for a key.
    /// If key exists, it is OVERWRITTEN (last write wins).
    pub fn put(self: *CanonicalJsonWriter, key: []const u8, json_value: []const u8) !void {
        // Check for existing key
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.key, key)) {
                // Overwrite
                self.allocator.free(f.value);
                f.value = try self.allocator.dupe(u8, json_value);
                return;
            }
        }

        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);

        const v = try self.allocator.dupe(u8, json_value);
        errdefer self.allocator.free(v);

        try self.fields.append(.{ .key = k, .value = v });
    }

    /// Helper to add a string value (handles escaping).
    pub fn putString(self: *CanonicalJsonWriter, key: []const u8, value: []const u8) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try std.json.stringify(value, .{}, buf.writer());
        try self.put(key, buf.items);
    }

    /// Helper to add an integer.
    pub fn putInt(self: *CanonicalJsonWriter, key: []const u8, value: anytype) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try std.json.stringify(value, .{}, buf.writer());
        try self.put(key, buf.items);
    }

    /// Writes the sorted object to the writer.
    /// Format: `{"k1":v1,"k2":v2}`
    pub fn write(self: *CanonicalJsonWriter, writer: anytype) !void {
        // Sort fields
        std.mem.sort(Field, self.fields.items, {}, Field.lessThan);

        try writer.writeByte('{');
        for (self.fields.items, 0..) |f, i| {
            if (i > 0) try writer.writeByte(',');

            // Key (escaped)
            try std.json.stringify(f.key, .{}, writer);
            try writer.writeByte(':');

            // Value (pre-encoded)
            try writer.writeAll(f.value);
        }
        try writer.writeByte('}');
    }
};

test "CanonicalJsonWriter sorts keys" {
    const a = std.testing.allocator;
    var w = CanonicalJsonWriter.init(a);
    defer w.deinit();

    try w.put("c", "\"valC\"");
    try w.put("a", "\"valA\"");
    try w.put("b", "123");

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();

    try w.write(buf.writer());

    try std.testing.expectEqualStrings("{\"a\":\"valA\",\"b\":123,\"c\":\"valC\"}", buf.items);
}

test "CanonicalJsonWriter putString escapes content" {
    const a = std.testing.allocator;
    var w = CanonicalJsonWriter.init(a);
    defer w.deinit();

    try w.putString("key", "line\nbreak");

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();

    try w.write(buf.writer());

    try std.testing.expectEqualStrings("{\"key\":\"line\\nbreak\"}", buf.items);
}

test "CanonicalJsonWriter handles empty object" {
    const a = std.testing.allocator;
    var w = CanonicalJsonWriter.init(a);
    defer w.deinit();

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();

    try w.write(buf.writer());

    try std.testing.expectEqualStrings("{}", buf.items);
}

test "CanonicalJsonWriter mixes system and user keys correctly" {
    const a = std.testing.allocator;
    var w = CanonicalJsonWriter.init(a);
    defer w.deinit();

    // System key (provider)
    try w.putString("provider", "openai");

    // User key (app) - should come BEFORE provider
    try w.putString("app", "chatbot");

    // System key (model) - should come between app and provider
    try w.putString("model", "gpt-4");

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();

    try w.write(buf.writer());

    try std.testing.expectEqualStrings("{\"app\":\"chatbot\",\"model\":\"gpt-4\",\"provider\":\"openai\"}", buf.items);
}

test "CanonicalJsonWriter overwrites duplicates" {
    const a = std.testing.allocator;
    var w = CanonicalJsonWriter.init(a);
    defer w.deinit();

    try w.putString("key", "value1");
    try w.putString("key", "value2");

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();

    try w.write(buf.writer());

    try std.testing.expectEqualStrings("{\"key\":\"value2\"}", buf.items);
}
