const std = @import("std");
const unicode = @import("unicode_tables.zig");

/// A robust UTF-8 iterator that never panics and never returns error.
/// Invalid sequences are replaced by replacement character (U+FFFD).
/// This is crucial for fuzzing and processing arbitrary untrusted input.
pub const SafeUtf8Iterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn nextCodepoint(self: *SafeUtf8Iterator) ?u21 {
        if (self.i >= self.bytes.len) return null;

        const n = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            // Invalid start byte
            self.i += 1;
            return 0xFFFD;
        };

        if (self.i + n > self.bytes.len) {
            // Truncated sequence
            self.i += 1; // Consume 1 byte to make progress
            return 0xFFFD;
        }

        const slice = self.bytes[self.i .. self.i + n];
        const cp = std.unicode.utf8Decode(slice) catch {
            // Invalid sequence content
            self.i += 1;
            return 0xFFFD;
        };

        self.i += n;
        return cp;
    }

    pub fn peek(self: *SafeUtf8Iterator) ?u21 {
         const old_i = self.i;
         const cp = self.nextCodepoint();
         self.i = old_i;
         return cp;
    }
};
