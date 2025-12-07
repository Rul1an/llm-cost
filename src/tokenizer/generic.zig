const std = @import("std");

pub const WhitespaceTokenizer = struct {
    pub fn count(_: WhitespaceTokenizer, text: []const u8) usize {
        var iter = std.mem.tokenizeAny(u8, text, " \t\n\r");
        var c: usize = 0;
        while (iter.next()) |_| {
            c += 1;
        }
        return c;
    }
};
