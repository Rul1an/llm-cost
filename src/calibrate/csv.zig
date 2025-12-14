const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Configuration for the CSV parser
pub const Config = struct {
    /// Maximum size of a single line in bytes.
    /// Default 64KB to support large JSON Tags columns.
    max_line_length: usize = 64 * 1024,

    /// Maximum size of a single field in bytes.
    /// Default 32KB.
    max_field_length: usize = 32 * 1024,

    /// Parsing mode
    mode: Mode = .strict,

    pub const Mode = enum {
        /// RFC 4180 compliant (mostly):
        /// - CRLF or LF line endings.
        /// - Double quotes for escaping.
        /// - No unescaped special chars inside fields.
        /// - LIMITATION: Does NOT support newlines inside quoted fields (record must be single line).
        strict,

        /// Lenient mode for Excel/Human quirks:
        /// - Skips empty lines.
        /// - (Future: Tolerates unescaped quotes inside fields - NOT YET IMPLEMENTED)
        /// - (Future: Trims trailing whitespace - NOT YET IMPLEMENTED)
        lenient,
    };
};

pub const Error = error{
    LineTooLong,
    FieldTooLong,
    UnquotedSpecialChar,
    UnexpectedQuote,
    UnclosedQuote,
    StreamReadError,
    StuckCursor,
    OutOfMemory, // If we ever need to allocate (we try to avoid it)
} || std.fs.File.ReadError || std.io.AnyReader.Error; // Inherit reader errors

/// A streaming CSV parser that reads from a generic reader.
/// Optimized for low allocation (reuses line buffer).
pub fn Parser(comptime ReaderType: type) type {
    return struct {
        reader: ReaderType,
        config: Config,
        allocator: Allocator, // Only used if specifically requested (mostly zero-copy)

        // Internal state
        line_buf: []u8,
        line_buffered_len: usize = 0,
        current_line_number: usize = 0,

        const Self = @This();

        pub fn init(allocator: Allocator, reader: ReaderType, config: Config) !Self {
            const buf = try allocator.alloc(u8, config.max_line_length);
            return Self{
                .reader = reader,
                .config = config,
                .allocator = allocator,
                .line_buf = buf,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.line_buf);
        }

        /// Reads the next line from the stream and returns a tokenizer for that line.
        /// Returns null if EOF.
        /// The returned line slice is valid until the next call to nextLine().
        pub fn nextLine(self: *Self) !?[]const u8 {
            while (true) {
                const result = self.reader.readUntilDelimiterOrEof(self.line_buf, '\n') catch |err| {
                    if (err == error.StreamTooLong) return error.LineTooLong;
                    return err;
                };

                if (result) |line| {
                    self.current_line_number += 1;

                    // Handle CRLF or just LF
                    var trimmed = line;
                    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                        trimmed = trimmed[0..trimmed.len - 1];
                    }

                    // In lenient mode, skip empty lines
                    if (self.config.mode == .lenient and trimmed.len == 0) {
                        continue;
                    }

                    return trimmed;
                }
                return null;
            }
        }

        /// Iterates fields in a line.
        /// Does NOT modify the underlying buffer (returns slices).
        pub fn tokenizer(self: *const Self, line: []const u8) Tokenizer {
            return Tokenizer.init(line, self.config);
        }
    };
}

pub const Tokenizer = struct {
    line: []const u8,
    config: Config,
    cursor: usize = 0,

    // Safety check for loops
    last_cursor: usize = 0,

    /// A field parsed from the CSV.
    pub const Field = struct {
        raw: []const u8,
        is_quoted: bool,
        has_escapes: bool, // If true, raw contains "" that need to become "

        /// Returns unescaped string, allocating if necessary.
        pub fn toOwned(self: Field, allocator: std.mem.Allocator) ![]u8 {
            if (!self.has_escapes) return allocator.dupe(u8, self.raw);

            // Unescape logic
            var result = try allocator.alloc(u8, self.raw.len);
            var i: usize = 0;
            var j: usize = 0;
            while (i < self.raw.len) : (i += 1) {
                result[j] = self.raw[i];
                j += 1;
                if (self.raw[i] == '"' and i + 1 < self.raw.len and self.raw[i+1] == '"') {
                    i += 1; // Skip escaped quote
                }
            }
            // Resize result
            return allocator.realloc(result, j);
        }

        /// Returns slice if no escapes, otherwise null.
        pub fn toSlice(self: Field) ?[]const u8 {
            if (self.has_escapes) return null;
            return self.raw;
        }
    };

    pub fn init(line: []const u8, config: Config) Tokenizer {
        return .{
            .line = line,
            .config = config,
        };
    }

    /// Returns the next field in the CSV line.
    pub fn next(self: *Tokenizer) !?Field {
        if (self.cursor == self.last_cursor and self.cursor != 0) return error.StuckCursor;
        self.last_cursor = self.cursor;

        if (self.cursor >= self.line.len) {
            // Check if we ended on a comma, implying an empty trailing field
            if (self.line.len > 0 and self.line[self.line.len - 1] == ',' and self.cursor == self.line.len) {
                self.cursor += 1; // Advance past "end" to prevent infinite loop
                return Field{ .raw = "", .is_quoted = false, .has_escapes = false };
            }
            return null;
        }

        const start = self.cursor;

        if (self.line[start] == '"') {
            return try self.readQuotedField(start);
        } else {
            return try self.readSimpleField(start);
        }
    }

    fn readSimpleField(self: *Tokenizer, start: usize) !Field {
        var i = start;
        while (i < self.line.len) : (i += 1) {
            // Check length
            if (i - start > self.config.max_field_length) return error.FieldTooLong;

            const c = self.line[i];
            if (c == ',') {
                const field = self.line[start..i];
                self.cursor = i + 1;
                return Field{ .raw = field, .is_quoted = false, .has_escapes = false };
            }

            if (self.config.mode == .strict) {
                if (c == '"') return error.UnexpectedQuote;
            }
        }

        // End of line
        // Final length check
        if (self.line.len - start > self.config.max_field_length) return error.FieldTooLong;

        const field = self.line[start..];
        self.cursor = self.line.len;

        return Field{ .raw = field, .is_quoted = false, .has_escapes = false };
    }

    fn readQuotedField(self: *Tokenizer, start: usize) !Field {
        // start points to opening quote "
        var i = start + 1;
        var has_escapes = false;

        while (i < self.line.len) : (i += 1) {
            // Content length check (approximation: strict length is i - (start+1), roughly)
            // We verify strict content length at return.
            if ((i - (start + 1)) > self.config.max_field_length) return error.FieldTooLong;

            if (self.line[i] == '"') {
                // Check if escaped ""
                if (i + 1 < self.line.len and self.line[i+1] == '"') {
                    has_escapes = true;
                    i += 1; // Skip next quote
                    if ((i - (start + 1)) > self.config.max_field_length) return error.FieldTooLong;
                    continue;
                }

                // End of quote
                // Must be followed by comma or EOF
                if (i + 1 < self.line.len) {
                    if (self.line[i+1] == ',') {
                        const content = self.line[start+1..i];
                        self.cursor = i + 2;
                        return Field{ .raw = content, .is_quoted = true, .has_escapes = has_escapes };
                    }
                    if (self.config.mode == .strict) return error.UnexpectedQuote;
                    // Lenient: strict error for now.
                    return error.UnexpectedQuote;
                }

                // EOF right after quote
                const content = self.line[start+1..i];
                self.cursor = self.line.len;
                return Field{ .raw = content, .is_quoted = true, .has_escapes = has_escapes };
            }
        }

        return error.UnclosedQuote;
    }
};

test "CSV Parser - Basic" {
    const raw = "id,cost,date\nsearch-v1,1.00,2025-01-01";
    var fbs = std.io.fixedBufferStream(raw);
    var parser = try Parser(std.io.FixedBufferStream([]const u8).Reader).init(std.testing.allocator, fbs.reader(), .{});
    defer parser.deinit();

    const h = (try parser.nextLine()).?;
    var t = parser.tokenizer(h);
    try std.testing.expectEqualStrings("id", (try t.next()).?.raw);
    try std.testing.expectEqualStrings("cost", (try t.next()).?.raw);
    try std.testing.expectEqualStrings("date", (try t.next()).?.raw);

    const r = (try parser.nextLine()).?;
    var t2 = parser.tokenizer(r);
    try std.testing.expectEqualStrings("search-v1", (try t2.next()).?.raw);
}

test "CSV Parser - Quoted & Escaped" {
    const raw = "\"id,1\",\"foo\"\"bar\",simple";
    var fbs = std.io.fixedBufferStream(raw);
    var parser = try Parser(std.io.FixedBufferStream([]const u8).Reader).init(std.testing.allocator, fbs.reader(), .{});
    defer parser.deinit();

    const line = (try parser.nextLine()).?;
    var t = parser.tokenizer(line);

    const f1 = (try t.next()).?;
    try std.testing.expectEqualStrings("id,1", f1.raw);
    try std.testing.expect(f1.is_quoted);

    const f2 = (try t.next()).?;
    try std.testing.expectEqualStrings("foo\"\"bar", f2.raw);
    try std.testing.expect(f2.has_escapes);

    const owned = try f2.toOwned(std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("foo\"bar", owned); // Internal "" becomes "

    const f3 = (try t.next()).?;
    try std.testing.expectEqualStrings("simple", f3.raw);
    try std.testing.expect(f3.toSlice() != null);
}

test "CSV Parser - Trailing Comma" {
    const raw = "a,b,";
    var fbs = std.io.fixedBufferStream(raw);
    var parser = try Parser(std.io.FixedBufferStream([]const u8).Reader).init(std.testing.allocator, fbs.reader(), .{});
    defer parser.deinit();

    const line = (try parser.nextLine()).?;
    var t = parser.tokenizer(line);

    try std.testing.expectEqualStrings("a", (try t.next()).?.raw);
    try std.testing.expectEqualStrings("b", (try t.next()).?.raw);
    const f3 = (try t.next()).?;
    try std.testing.expectEqualStrings("", f3.raw);
    try std.testing.expect((try t.next()) == null);
}

test "CSV Parser - Max Field Limit" {
    const raw = "short,this_is_too_long";
    var fbs = std.io.fixedBufferStream(raw);
    const config = Config{ .max_field_length = 5 }; // Very short limit
    var parser = try Parser(std.io.FixedBufferStream([]const u8).Reader).init(std.testing.allocator, fbs.reader(), config);
    defer parser.deinit();

    const line = (try parser.nextLine()).?;
    var t = parser.tokenizer(line);

    // First field ok
    try std.testing.expect((try t.next()) != null);

    // Second field fails
    try std.testing.expectError(error.FieldTooLong, t.next());
}

test "CSV Parser - Lenient Empty Lines" {
    const raw = "a,b\n\n\nc,d";
    var fbs = std.io.fixedBufferStream(raw);
    const config = Config{ .mode = .lenient };
    var parser = try Parser(std.io.FixedBufferStream([]const u8).Reader).init(std.testing.allocator, fbs.reader(), config);
    defer parser.deinit();

    const l1 = (try parser.nextLine()).?; // "a,b"
    try std.testing.expectEqualStrings("a,b", l1);

    const l2 = (try parser.nextLine()).?; // Should skip \n\n and get "c,d"
    try std.testing.expectEqualStrings("c,d", l2);
}

