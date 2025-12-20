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

    @"x-llm-model": ?[]const u8 = null,
    @"x-llm-input-tokens": ?u32 = null,
    @"x-llm-output-tokens": ?u32 = null,
    @"x-llm-cache-hit": ?bool = null,

    // v1.2 Optional
    InvoiceIssuerName: ?[]const u8 = null,

    // Optional timestamp (if you add support)
    timestamp: ?i64 = null,

    // Dynamic Tags (PR8.1)
    tags: std.StringHashMap([]const u8),

    // Helper to get column value by name (used by TagResolver)
    pub fn getColumn(self: FocusRecord, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "ResourceId")) return self.ResourceId;
        if (std.mem.eql(u8, name, "UsageUnit")) return self.UsageUnit;
        if (std.mem.eql(u8, name, "ChargeCategory")) return self.ChargeCategory;
        if (std.mem.eql(u8, name, "InvoiceIssuerName")) return self.InvoiceIssuerName;
        if (std.mem.eql(u8, name, "x-llm-model")) return self.@"x-llm-model";
        // ... (add others if needed, typically we resolve Tags.* or ResourceId)
        return null;
    }
};

fn stripBom(s: []const u8) []const u8 {
    // UTF-8 BOM: EF BB BF
    if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) return s[3..];
    return s;
}

fn headerEq(name: []const u8, expected: []const u8) bool {
    const cleaned = std.mem.trim(u8, stripBom(name), " \t\r\n");
    return std.mem.eql(u8, cleaned, expected);
}

pub const FocusVersion = enum {
    unknown,
    v1_0,
    v1_2,
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

    // Per-line arena for string fields
    arena: std.heap.ArenaAllocator,

    // Scratch buffer for unescaped quoted fields (reused)
    scratch: std.ArrayList(u8),

    col: ColumnIndices,
    tag_map: std.AutoHashMap(usize, []const u8), // idx -> key (owned by parser)

    version: FocusVersion = .unknown,
    line_no: u64 = 0,

    const ColumnIndices = struct {
        BilledCost: ?usize = null,
        EffectiveCost: ?usize = null,
        UsageQuantity: ?usize = null,
        UsageUnit: ?usize = null,
        ChargeCategory: ?usize = null,
        ResourceId: ?usize = null,
        InvoiceIssuerName: ?usize = null,

        // v1.2 signals
        InvoiceId: ?usize = null,
        CapacityReservationId: ?usize = null,

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
        const lr = try LineReader.init(allocator, reader, max_line_bytes);

        var p = FocusParser{
            .allocator = allocator,
            .lr = lr,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .scratch = std.ArrayList(u8).init(allocator),
            .col = .{},
            .tag_map = std.AutoHashMap(usize, []const u8).init(allocator),
        };
        errdefer p.deinit();

        try p.parseHeader();
        try p.validateRequired();
        return p;
    }

    pub fn deinit(self: *FocusParser) void {
        var it = self.tag_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.tag_map.deinit();
        self.lr.deinit();
        self.arena.deinit();
        self.scratch.deinit();
    }

    fn validateRequired(self: *const FocusParser) !void {
        if (self.col.BilledCost == null and self.col.EffectiveCost == null) return error.MissingRequiredColumn;
        // Relaxed others: UsageQuantity/Unit might be missing in simple files.
    }

    fn parseHeader(self: *FocusParser) !void {
        const line = (try self.readLineOrNull()) orelse return error.InvalidCsv;
        var it = CsvFieldIter.init(line, &self.scratch);

        var idx: usize = 0;
        var saw_v1_2_signal = false;

        while (try it.next()) |field_raw| : (idx += 1) {
            // Note: raw field might contain BOM if it's the first one.
            // headerEq handles BOM + trimming.

            const clean_name = std.mem.trim(u8, stripBom(field_raw), " \t\r\n");

            if (std.mem.eql(u8, clean_name, "BilledCost")) self.col.BilledCost = idx else if (std.mem.eql(u8, clean_name, "EffectiveCost")) self.col.EffectiveCost = idx else if (std.mem.eql(u8, clean_name, "UsageQuantity")) self.col.UsageQuantity = idx else if (std.mem.eql(u8, clean_name, "UsageUnit")) self.col.UsageUnit = idx else if (std.mem.eql(u8, clean_name, "ChargeCategory")) self.col.ChargeCategory = idx else if (std.mem.eql(u8, clean_name, "ResourceId")) self.col.ResourceId = idx else if (std.mem.eql(u8, clean_name, "x-llm-model")) self.col.@"x-llm-model" = idx else if (std.mem.eql(u8, clean_name, "x-llm-input-tokens")) self.col.@"x-llm-input-tokens" = idx else if (std.mem.eql(u8, clean_name, "x-llm-output-tokens")) self.col.@"x-llm-output-tokens" = idx else if (std.mem.eql(u8, clean_name, "x-llm-cache-hit")) self.col.@"x-llm-cache-hit" = idx

                // v1.2 signals
            else if (std.mem.eql(u8, clean_name, "InvoiceIssuerName")) {
                self.col.InvoiceIssuerName = idx;
                saw_v1_2_signal = true;
            } else if (std.mem.eql(u8, clean_name, "InvoiceId")) {
                self.col.InvoiceId = idx;
                saw_v1_2_signal = true;
            } else if (std.mem.eql(u8, clean_name, "CapacityReservationId")) {
                self.col.CapacityReservationId = idx;
                saw_v1_2_signal = true;
            }
            // Dynamic Tags parsing
            else if (std.mem.startsWith(u8, clean_name, "Tags.")) {
                const key = clean_name["Tags.".len..];
                if (key.len > 0) {
                    try self.tag_map.put(idx, try self.allocator.dupe(u8, key));
                }
            }
        }

        // Detect Version
        if (saw_v1_2_signal) {
            self.version = .v1_2;
        } else {
            self.version = .v1_0;
        }
    }

    /// Read next record. Returns null on EOF.
    /// Strings in FocusRecord are allocated in internally managed Arena, valid until next call.
    pub fn next(self: *FocusParser) !?FocusRecord {
        // Reset arena for new line
        _ = self.arena.reset(.retain_capacity);

        const line = (try self.readLineOrNull()) orelse return null;
        self.line_no += 1;

        const ally = self.arena.allocator();

        var rec = FocusRecord{
            .BilledCost = 0,
            .EffectiveCost = 0,
            .UsageQuantity = 0,
            .UsageUnit = "",
            .ChargeCategory = "",
            .ResourceId = "",
            .tags = std.StringHashMap([]const u8).init(ally),
        };

        var it = CsvFieldIter.init(line, &self.scratch);
        var idx: usize = 0;

        while (try it.next()) |field_raw| : (idx += 1) {
            const field = trimField(field_raw);

            if (self.col.BilledCost != null and self.col.BilledCost.? == idx) {
                rec.BilledCost = types.parseMicroUSDDecimal(field) catch return error.InvalidNumber;
            } else if (self.col.EffectiveCost != null and self.col.EffectiveCost.? == idx) {
                rec.EffectiveCost = types.parseMicroUSDDecimal(field) catch return error.InvalidNumber;
            } else if (self.col.UsageQuantity != null and self.col.UsageQuantity.? == idx) {
                rec.UsageQuantity = std.fmt.parseInt(u64, field, 10) catch return error.InvalidNumber;
            } else if (self.col.UsageUnit != null and self.col.UsageUnit.? == idx) {
                rec.UsageUnit = try ally.dupe(u8, field);
            } else if (self.col.ChargeCategory != null and self.col.ChargeCategory.? == idx) {
                rec.ChargeCategory = try ally.dupe(u8, field);
            } else if (self.col.ResourceId != null and self.col.ResourceId.? == idx) {
                rec.ResourceId = try ally.dupe(u8, field);
            } else if (self.col.@"x-llm-model" != null and self.col.@"x-llm-model".? == idx) {
                if (field.len != 0) rec.@"x-llm-model" = try ally.dupe(u8, field);
            } else if (self.col.@"x-llm-input-tokens" != null and self.col.@"x-llm-input-tokens".? == idx) {
                if (field.len != 0) rec.@"x-llm-input-tokens" = std.fmt.parseInt(u32, field, 10) catch return error.InvalidNumber;
            } else if (self.col.@"x-llm-output-tokens" != null and self.col.@"x-llm-output-tokens".? == idx) {
                if (field.len != 0) rec.@"x-llm-output-tokens" = std.fmt.parseInt(u32, field, 10) catch return error.InvalidNumber;
            } else if (self.col.@"x-llm-cache-hit" != null and self.col.@"x-llm-cache-hit".? == idx) {
                if (field.len != 0) rec.@"x-llm-cache-hit" = parseBool(field) catch return error.InvalidBoolean;
            } else if (self.col.InvoiceIssuerName != null and self.col.InvoiceIssuerName.? == idx) {
                if (field.len != 0) rec.InvoiceIssuerName = try ally.dupe(u8, field);
            }

            // Dynamic Tags populated in pass-through loop?
            // Optimization: check against tag_cols list? Linear search might be ok for small number of tags.
            // A better way is to iterate headers once and build a sparse map?
            // But here we are iterating fields.
            // Let's optimize: Check bounds of tags

            // To avoid linear scan of tag_cols for every field:
            // We can precompute: do we have any tag at this idx?
            // But for PR8.1 MVP, simple iteration is acceptable if < 100 columns.
            // Optimization: Use sparse lookup array/map if we precompute.
            // But since we are iterating fields by index, we can just check if `tag_map` has this index.
            if (self.tag_map.get(idx)) |key| {
                const val_dupe = try ally.dupe(u8, field);
                try rec.tags.put(key, val_dupe);
            }
        }

        // Apply fallbacks
        if (self.col.EffectiveCost == null) rec.EffectiveCost = rec.BilledCost;

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
            return ""; // trailing empty field
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
