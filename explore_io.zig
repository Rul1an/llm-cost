const std = @import("std");

pub fn main() !void {
    inline for (@typeInfo(std.fs.File.Reader).@"struct".decls) |decl| {
        std.debug.print("{s}\n", .{decl.name});
    }
}
