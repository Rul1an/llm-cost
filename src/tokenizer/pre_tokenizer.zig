const std = @import("std");

pub const PreToken = struct {
    text: []const u8,
    is_special: bool = false,
};

pub const BpeVersion = enum {
    legacy, // Not really used in V2 engine, but for context
    v2, // Current Heap BPE (Text-based)
    v2_1, // Optimized Index+Heap BPE (Token-based)
};

/// Function pointer type for consuming pre-tokens.
/// Returns error to allow early exit or propagation.
pub const TokenHandler = *const fn (ctx: *anyopaque, token: PreToken) anyerror!void;

/// Interface for splitting text into pre-tokens before BPE merging.
pub const PreTokenizer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Tokenize text and invoke handler for each chunk.
        /// Does not allocate for the chunks themselves (slices of text).
        tokenize: *const fn (ctx: *anyopaque, text: []const u8, handler_ctx: *anyopaque, handler: TokenHandler) anyerror!void,
    };

    pub fn tokenize(self: PreTokenizer, text: []const u8, handler_ctx: *anyopaque, handler: TokenHandler) !void {
        return self.vtable.tokenize(self.ptr, text, handler_ctx, handler);
    }
};

/// Placeholder pre-tokenizer that splits on whitespace (approximate behavior).
pub const LegacyPreTokenizer = struct {
    pub fn tokenize(_: *anyopaque, text: []const u8, handler_ctx: *anyopaque, handler: TokenHandler) !void {
        var i: usize = 0;
        while (i < text.len) {
            const start = i;
            // Basic split by space
            while (i < text.len and text[i] != ' ') : (i += 1) {}

            if (i > start) {
                try handler(handler_ctx, .{ .text = text[start..i] });
            }
            // Consume spaces as individual tokens
            while (i < text.len and text[i] == ' ') {
                const slice = text[i .. i + 1];
                try handler(handler_ctx, .{ .text = slice, .is_special = false });
                i += 1;
            }
        }
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
