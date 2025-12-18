const std = @import("std");
const types = @import("types.zig");
const LineReader = @import("line_reader.zig").LineReader;

pub const FocusRecord = struct {
    // Required-ish for calibration (subset; validate header accordingly)
    BilledCost: types.MicroUSD,
    EffectiveCost: types.MicroUSD,
    UsageQuantity: u64,
    UsageUnit: []const u8,
    ChargeCategory: []const u8,
    ResourceId: []const u8,

    // Extensions
    @"x-llm-model": ?[]const u8 = null,
    @"x-llm-input-tokens": ?u32 = null,
    @"x-llm-output-tokens": ?u32 = null,
    @"x-llm-cache-hit": ?bool = null,

    // Optional timestamp (if you add support)
    timestamp: ?i64 = null,
};

pub const ParseError = error{
    InvalidCsv,
    MissingRequiredColumn,
    InvalidNumber,
    InvalidBoolean,
    LineTooLong,
    IoError,
    OutOfMemory,
};

pub const FocusParser = struct {
    allocator: std.mem.Allocator,
    lr: LineReader,

    // Scratch buffer for unescaped quoted fields (reused)
    scratch: std.ArrayList(u8),

    col: ColumnIndices,
    line_no: u64 = 0,

    const ColumnIndices = struct {
        BilledCost: ?usize = null,
        EffectiveCost: ?usize = null,
        UsageQuantity: ?usize = null,
        UsageUnit: ?usize = null,
        ChargeCategory: ?usize = null,
        ResourceId: ?usize = null,

        @"x-llm-model": ?usize = null,
        @"x-llm-input-tokens": ?usize = null,
        @"x-llm-output-tokens": ?usize = null,
        @"x-llm-cache-hit": ?usize = null,
    };

    pub fn initFromReader(
        allocator: std.mem.Allocator,
        reader: anytype,
        max_line_bytes: usize,
    ) !FocusParser {
        var lr = try LineReader.init(allocator, reader, max_line_bytes);
        errdefer lr.deinit();

        var p = FocusParser{
            .allocator = allocator,
            .lr = lr,
            .scratch = std.ArrayList(u8).init(allocator),
            .col = .{},
        };
        errdefer p.deinit();

        try p.parseHeader();
        try p.validateRequired();
        return p;
    }

    pub fn initFile(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        max_line_bytes: usize,
    ) !FocusParser {
        return initFromReader(allocator, file.reader(), max_line_bytes);
    }

    pub fn deinit(self: *FocusParser) void {
        self.lr.deinit();
        self.scratch.deinit();
    }

    fn validateRequired(self: *const FocusParser) !void {
        if (self.col.BilledCost == null) return error.MissingRequiredColumn;
        if (self.col.EffectiveCost == null) return error.MissingRequiredColumn;
        if (self.col.UsageQuantity == null) return error.MissingRequiredColumn;
        if (self.col.UsageUnit == null) return error.MissingRequiredColumn;
        if (self.col.ChargeCategory == null) return error.MissingRequiredColumn;
        if (self.col.ResourceId == null) return error.MissingRequiredColumn;
    }

    fn parseHeader(self: *FocusParser) !void {
        const line = (try self.readLineOrNull()) orelse return error.InvalidCsv;
        var it = CsvFieldIter.init(line, &self.scratch);

        var idx: usize = 0;
        while (try it.next()) |field_raw| : (idx += 1) {
            const name = trimField(field_raw);

            if (std.mem.eql(u8, name, "BilledCost")) self.col.BilledCost = idx
            else if (std.mem.eql(u8, name, "EffectiveCost")) self.col.EffectiveCost = idx
            else if (std.mem.eql(u8, name, "UsageQuantity")) self.col.UsageQuantity = idx
            else if (std.mem.eql(u8, name, "UsageUnit")) self.col.UsageUnit = idx
            else if (std.mem.eql(u8, name, "ChargeCategory")) self.col.ChargeCategory = idx
            else if (std.mem.eql(u8, name, "ResourceId")) self.col.ResourceId = idx
            else if (std.mem.eql(u8, name, "x-llm-model")) self.col.@"x-llm-model" = idx
            else if (std.mem.eql(u8, name, "x-llm-input-tokens")) self.col.@"x-llm-input-tokens" = idx
            else if (std.mem.eql(u8, name, "x-llm-output-tokens")) self.col.@"x-llm-output-tokens" = idx
            else if (std.mem.eql(u8, name, "x-llm-cache-hit")) self.col.@"x-llm-cache-hit" = idx;
        }
    }

    /// Read next record. Returns null on EOF.
    pub fn next(self: *FocusParser) !?FocusRecord {
        const line = (try self.readLineOrNull()) orelse return null;
        self.line_no += 1;

        var rec = FocusRecord{
            .BilledCost = 0,
            .EffectiveCost = 0,
            .UsageQuantity = 0,
            .UsageUnit = "",
            .ChargeCategory = "",
            .ResourceId = "",
        };

        var it = CsvFieldIter.init(line, &self.scratch);
        var idx: usize = 0;
        while (try it.next()) |field_raw| : (idx += 1) {
            const field = trimField(field_raw);

            if (self.col.BilledCost == idx) {
                rec.BilledCost = types.parseMicroUSDDecimal(field) catch return error.InvalidNumber;
            } else if (self.col.EffectiveCost == idx) {
                rec.EffectiveCost = types.parseMicroUSDDecimal(field) catch return error.InvalidNumber;
            } else if (self.col.UsageQuantity == idx) {
                rec.UsageQuantity = std.fmt.parseInt(u64, field, 10) catch return error.InvalidNumber;
            } else if (self.col.UsageUnit == idx) {
                rec.UsageUnit = field;
            } else if (self.col.ChargeCategory == idx) {
                rec.ChargeCategory = field;
            } else if (self.col.ResourceId == idx) {
                rec.ResourceId = field;
            } else if (self.col.@"x-llm-model" != null and self.col.@"x-llm-model".? == idx) {
                if (field.len != 0) rec.@"x-llm-model" = field;
            } else if (self.col.@"x-llm-input-tokens" != null and self.col.@"x-llm-input-tokens".? == idx) {
                if (field.len != 0) rec.@"x-llm-input-tokens" = std.fmt.parseInt(u32, field, 10) catch return error.InvalidNumber;
            } else if (self.col.@"x-llm-output-tokens" != null and self.col.@"x-llm-output-tokens".? == idx) {
                if (field.len != 0) rec.@"x-llm-output-tokens" = std.fmt.parseInt(u32, field, 10) catch return error.InvalidNumber;
            } else if (self.col.@"x-llm-cache-hit" != null and self.col.@"x-llm-cache-hit".? == idx) {
                if (field.len != 0) rec.@"x-llm-cache-hit" = parseBool(field) catch return error.InvalidBoolean;
            }
        }

        return rec;
    }

    fn parseBool(s: []const u8) !bool {
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "1")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "0")) return false;
        return error.InvalidBoolean;
    }

    fn trimField(s: []const u8) []const u8 {
        // NOTE: CSV iter already strips outer quotes by unescaping into scratch.
        return std.mem.trim(u8, s, " \t\r\n");
    }

    fn readLineOrNull(self: *FocusParser) !?[]const u8 {
        return self.lr.nextLine() catch |e| switch (e) {
            error.LineTooLong => return error.LineTooLong,
            error.IoError => return error.IoError,
            else => return error.OutOfMemory,
        };
    }
};

/// CSV field iterator with RFC4180-ish quotes:
const CsvFieldIter = struct {
    line: []const u8,
    i: usize,
    scratch: *std.ArrayList(u8),

    pub fn init(line: []const u8, scratch: *std.ArrayList(u8)) CsvFieldIter {
        return .{ .line = line, .i = 0, .scratch = scratch };
    }

    pub fn next(self: *CsvFieldIter) !?[]const u8 {
        if (self.i > self.line.len) return null;
        if (self.i == self.line.len) {
            self.i += 1; // move past end
            return "";   // trailing empty field
        }

        // reset scratch each field
        self.scratch.clearRetainingCapacity();

        var in_quotes = false;
        var started = false;

        const start_i = self.i;

        while (self.i < self.line.len) : (self.i += 1) {
            const c = self.line[self.i];

            if (!started) {
                started = true;
                if (c == '"') {
                    in_quotes = true;
                    continue;
                }
            }

            if (in_quotes) {
                if (c == '"') {
                    // escaped quote?
                    if (self.i + 1 < self.line.len and self.line[self.i + 1] == '"') {
                        try self.scratch.append('"');
                        self.i += 1; // consume second quote
                        continue;
                    } else {
                        // end quotes
                        in_quotes = false;
                        continue;
                    }
                } else {
                    try self.scratch.append(c);
                    continue;
                }
            } else {
                if (c == ',') {
                    const field = try self.finishField(start_i, true);
                    self.i += 1; // skip comma
                    return field;
                }
            }
        }

        // end of line
        const field = try self.finishField(start_i, true);
        self.i = self.line.len + 1;
        return field;
    }

    fn finishField(self: *CsvFieldIter, start_i: usize, maybe_quoted: bool) ![]const u8 {
        // If scratch has data OR field started with quote, return scratch.
        // Otherwise return raw slice (unquoted).
        if (self.scratch.items.len != 0 or (maybe_quoted and start_i < self.line.len and self.line[start_i] == '"')) {
            return self.scratch.items;
        }

        // Unquoted: return slice from start_i..current i
        const end_i = self.i;
        return self.line[start_i..end_i];
    }
};
