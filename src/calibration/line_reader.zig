const std = @import("std");

pub const LineReaderError = error{
    LineTooLong,
    IoError,
    OutOfMemory,
};

/// Streaming line reader:
/// - Reads from AnyReader in chunks.
/// - Preserves unread bytes after '\n' in an internal carry buffer.
/// - Returns slices backed by `line_buf` (valid until next call).
/// - Grows `line_buf` up to max_line_bytes.
pub const LineReader = struct {
    allocator: std.mem.Allocator,
    r: std.io.AnyReader,

    // Carry buffer for bytes read beyond newline
    carry: []u8,
    carry_len: usize,

    // Read chunk buffer
    chunk: []u8,

    // Output line buffer (grown as needed)
    line_buf: []u8,
    max_line_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: anytype,
        max_line_bytes: usize,
    ) !LineReader {
        return .{
            .allocator = allocator,
            .r = reader.any(),
            .carry = try allocator.alloc(u8, 8 * 1024),
            .carry_len = 0,
            .chunk = try allocator.alloc(u8, 16 * 1024),
            .line_buf = try allocator.alloc(u8, 64 * 1024),
            .max_line_bytes = max_line_bytes,
        };
    }

    pub fn deinit(self: *LineReader) void {
        self.allocator.free(self.carry);
        self.allocator.free(self.chunk);
        self.allocator.free(self.line_buf);
    }

    /// Returns next line excluding '\n' and optional trailing '\r'.
    /// Returns null on EOF (no more bytes).
    pub fn nextLine(self: *LineReader) LineReaderError!?[]const u8 {
        var out_len: usize = 0;

        // 1) First consume carry (if any)
        if (self.carry_len != 0) {
            if (indexOfNewline(self.carry[0..self.carry_len])) |nl_pos| {
                // Entire line is in carry
                try self.ensureLineCap(nl_pos);
                @memcpy(self.line_buf[0..nl_pos], self.carry[0..nl_pos]);
                out_len = nl_pos;

                // Save remainder after '\n'
                const rem_start = nl_pos + 1;
                const rem_len = self.carry_len - rem_start;
                if (rem_len != 0) {
                    std.mem.copyForwards(u8, self.carry[0..rem_len], self.carry[rem_start .. rem_start + rem_len]);
                }
                self.carry_len = rem_len;

                return stripCR(self.line_buf[0..out_len]);
            } else {
                // No newline in carry: append all carry to output buffer
                try self.ensureLineCap(self.carry_len);
                @memcpy(self.line_buf[0..self.carry_len], self.carry[0..self.carry_len]);
                out_len = self.carry_len;
                self.carry_len = 0;
            }
        }

        // 2) Read chunks until newline or EOF
        while (true) {
            const n = self.r.read(self.chunk) catch {
                return error.IoError;
            };

            if (n == 0) {
                // EOF
                if (out_len == 0) return null;
                return stripCR(self.line_buf[0..out_len]);
            }

            const data = self.chunk[0..n];
            if (indexOfNewline(data)) |nl_pos| {
                // Append bytes up to nl_pos
                const needed = out_len + nl_pos;
                try self.ensureLineCap(needed);
                @memcpy(self.line_buf[out_len .. out_len + nl_pos], data[0..nl_pos]);
                out_len += nl_pos;

                // Store remainder after '\n' into carry
                const rem_start = nl_pos + 1;
                const rem_len = n - rem_start;
                if (rem_len != 0) {
                    try self.ensureCarryCap(rem_len);
                    @memcpy(self.carry[0..rem_len], data[rem_start .. rem_start + rem_len]);
                    self.carry_len = rem_len;
                } else {
                    self.carry_len = 0;
                }

                return stripCR(self.line_buf[0..out_len]);
            } else {
                // No newline: append entire chunk
                const needed = out_len + n;
                try self.ensureLineCap(needed);
                @memcpy(self.line_buf[out_len .. out_len + n], data);
                out_len += n;

                if (out_len >= self.max_line_bytes) return error.LineTooLong;
            }
        }
    }

    fn ensureLineCap(self: *LineReader, needed_len: usize) !void {
        if (needed_len <= self.line_buf.len) return;
        var new_len = self.line_buf.len;
        while (new_len < needed_len) {
            new_len = new_len * 2;
            if (new_len > self.max_line_bytes) new_len = self.max_line_bytes;
            if (new_len == self.line_buf.len) return error.LineTooLong;
        }
        self.line_buf = try self.allocator.realloc(self.line_buf, new_len);
    }

    fn ensureCarryCap(self: *LineReader, needed_len: usize) !void {
        if (needed_len <= self.carry.len) return;
        var new_len = self.carry.len;
        while (new_len < needed_len) new_len *= 2;
        self.carry = try self.allocator.realloc(self.carry, new_len);
    }

    fn indexOfNewline(buf: []const u8) ?usize {
        return std.mem.indexOfScalar(u8, buf, '\n');
    }

    fn stripCR(line: []const u8) []const u8 {
        if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }
};
