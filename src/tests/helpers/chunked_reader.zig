const std = @import("std");

/// Reader that returns at most `chunk_size` bytes per read.
/// Useful for adversarial chunk-boundary testing.
///
/// Error set is empty: read never fails.
pub const ChunkedReader = struct {
    data: []const u8,
    pos: usize = 0,
    chunk_size: usize,

    pub fn init(data: []const u8, chunk_size: usize) ChunkedReader {
        return .{ .data = data, .pos = 0, .chunk_size = @max(@as(usize, 1), chunk_size) };
    }

    fn readFn(self: *ChunkedReader, dest: []u8) error{}!usize {
        if (self.pos >= self.data.len) return 0;

        const remaining = self.data.len - self.pos;
        const n = @min(@min(dest.len, remaining), self.chunk_size);

        @memcpy(dest[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    pub fn reader(self: *ChunkedReader) std.io.Reader(*ChunkedReader, error{}, readFn) {
        return .{ .context = self };
    }
};
