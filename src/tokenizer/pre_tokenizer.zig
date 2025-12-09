const std = @import("std");

pub const PreToken = struct {
    text: []const u8,
    is_special: bool = false,
};

/// Interface for splitting text into pre-tokens before BPE merging.
pub const PreTokenizer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        tokenize: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, text: []const u8) anyerror![]PreToken,
    };

    pub fn tokenize(self: PreTokenizer, alloc: std.mem.Allocator, text: []const u8) ![]PreToken {
        return self.vtable.tokenize(self.ptr, alloc, text);
    }
};

/// Placeholder pre-tokenizer that splits on whitespace (approximate behavior).
/// This implementation is considered "legacy" because it does not handle more complex tokenization rules.
/// In future versions, this will be replaced with a more robust pre-tokenizer supporting Unicode and custom rules.
pub const LegacyPreTokenizer = struct {
    pub fn tokenize(_: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]PreToken {
        var tokens = std.ArrayList(PreToken).init(alloc);
        errdefer tokens.deinit();

        var i: usize = 0;
        while (i < text.len) {
            const start = i;
            // Basic split by space
            while (i < text.len and text[i] != ' ') : (i += 1) {}

            if (i > start) {
                try tokens.append(.{ .text = text[start..i] });
            }
            // Consume spaces as individual tokens
            while (i < text.len and text[i] == ' ') {
                try tokens.append(.{ .text = text[i .. i + 1] });
                i += 1;
            }
        }

        return tokens.toOwnedSlice();
    }

    const DummyContext = struct {};
    var dummy_ctx: DummyContext = .{};

    pub fn interface() PreTokenizer {
        return .{
            .ptr = @ptrCast(&dummy_ctx),
            .vtable = &.{ .tokenize = tokenize },
        };
    }
};
