const std = @import("std");
const cli = @import("cli/commands.zig");

pub fn main() !void {
    // GeneralPurposeAllocator + Arena: één lifetime per run, geen micro-management.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const exit_code = try cli.main(arena.allocator());
    std.process.exit(exit_code);
}

test {
    _ = @import("test/scanner_whitespace.zig");
    _ = @import("test/cl100k_scanner_test.zig");
    // _ = @import("test/parity.zig"); // Run via 'zig build test-parity'
    // _ = @import("tokenizer/bpe.zig");
}
