const std = @import("std");

pub const ResourceId = struct {
    value: []const u8,
    source: Source,

    pub const Source = enum {
        manifest, // prompt_id from [[prompts]]
        path_slug, // derived from relative path
        content_hash, // Blake2b of content (stdin fallback)
    };

    pub fn deinit(self: *ResourceId, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

/// Derive ResourceId with fallback hierarchy
pub fn derive(
    allocator: std.mem.Allocator,
    prompt_id: ?[]const u8,
    rel_path: ?[]const u8,
    content: ?[]const u8,
) !ResourceId {
    // Priority 1: Explicit prompt_id from manifest
    if (prompt_id) |id| {
        return ResourceId{
            .value = try allocator.dupe(u8, id),
            .source = .manifest,
        };
    }

    // Priority 2: Slugified relative path
    if (rel_path) |path| {
        return ResourceId{
            .value = try slugify(allocator, path),
            .source = .path_slug,
        };
    }

    // Priority 3: Content hash (stdin fallback)
    if (content) |bytes| {
        return ResourceId{
            .value = try contentHash(allocator, bytes),
            .source = .content_hash,
        };
    }

    return error.NoResourceIdSource;
}

/// Slugify path: prompts/login/v2.txt -> prompts-login-v2-txt
/// Rules:
/// 1. Lowercase
/// 2. / \ . _ space -> -
/// 3. remove other non-alphanumeric
/// 4. collapse dashes
/// 5. trim dashes
pub fn slugify(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var last_was_dash = true; // Start true to trim leading dashes efficiently

    for (path) |c| {
        const out: ?u8 = switch (c) {
            'a'...'z', '0'...'9' => c,
            'A'...'Z' => c + 32, // to lower
            '/', '\\', '.', '_', ' ' => '-',
            else => null,
        };

        if (out) |ch| {
            if (ch == '-') {
                if (!last_was_dash) {
                    try result.append(ch);
                    last_was_dash = true;
                }
            } else {
                try result.append(ch);
                last_was_dash = false;
            }
        }
    }

    // Trim trailing dash
    if (result.items.len > 0 and result.items[result.items.len - 1] == '-') {
        _ = result.pop();
    }

    return result.toOwnedSlice();
}

/// Blake2b hash, first 8 hex chars
pub fn contentHash(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    hasher.update(content);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // First 8 hex chars (4 bytes) -> need 8 bytes buffer
    const hex = try allocator.alloc(u8, 8);
    errdefer allocator.free(hex);

    // digest[0..4] is the u32 we want represented as hex
    const val = std.mem.readInt(u32, digest[0..4], .big);
    _ = std.fmt.bufPrint(hex, "{x:0>8}", .{val}) catch unreachable;

    return hex;
}

// Tests
const testing = std.testing;

test "resource_id: slugify" {
    const alloc = testing.allocator;

    const s1 = try slugify(alloc, "prompts/search.txt");
    defer alloc.free(s1);
    try testing.expectEqualStrings("prompts-search-txt", s1);

    const s2 = try slugify(alloc, "Src/Auth/Login V2.txt");
    defer alloc.free(s2);
    try testing.expectEqualStrings("src-auth-login-v2-txt", s2);

    const s3 = try slugify(alloc, "___crazy___name___");
    defer alloc.free(s3);
    try testing.expectEqualStrings("crazy-name", s3);
}

test "resource_id: derive hierarchy" {
    const alloc = testing.allocator;

    // 1. Manifest ID
    var r1 = try derive(alloc, "my-id", "some/path", null);
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("my-id", r1.value);
    try testing.expectEqual(ResourceId.Source.manifest, r1.source);

    // 2. Path Slug
    var r2 = try derive(alloc, null, "foo/bar.txt", null);
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("foo-bar-txt", r2.value);
    try testing.expectEqual(ResourceId.Source.path_slug, r2.source);

    // 3. Content Hash
    var r3 = try derive(alloc, null, null, "Hello World");
    defer r3.deinit(alloc);
    try testing.expectEqual(ResourceId.Source.content_hash, r3.source);
    try testing.expectEqual(8, r3.value.len);
}
