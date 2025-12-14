const std = @import("std");
const Allocator = std.mem.Allocator;
const csv = @import("csv.zig");

/// A zero-copy view of a parsed CSV row.
/// Slices are valid only until the next call to nextLine() on the CSV parser.
pub const RowView = struct {
    resource_id: []const u8,
    billed_cost: i128, // MicroUSD
    period_start: []const u8, // ISO8601
    call_count: ?u64 = null,
    cache_hit_ratio: ?u64 = null, // Parts-Per-Million (0..1_000_000)

    // Tags (optional, extracted if indices.tags is set)
    model: ?[]const u8 = null,
    scenario: ?[]const u8 = null,

    // We don't need an arena if we borrow everything from the line buffer!
    // Except for JSON string unescaping.
    // If JSON tags are unescaped, they are in a new buffer (from field.toOwned or similar).
    // User requested "scratch buffer resetting per row".
    // For now, we assume the caller handles the scratch arena for `parseRow`.
};

// Maps CSV header name to internal column index
pub const ImportOptions = struct {};

pub const ColumnIndex = struct {
    resource_id: ?usize = null,
    billed_cost: ?usize = null,
    period_start: ?usize = null,
    tags: ?usize = null,

    // Extended columns (direct x- columns)
    x_call_count: ?usize = null,
    x_cache_hit_ratio: ?usize = null,

    pub fn isReady(self: ColumnIndex) bool {
        return self.resource_id != null and self.billed_cost != null and self.period_start != null;
    }
};

/// Resolves column indices from the header row
pub fn resolveColumns(header: csv.Tokenizer) !ColumnIndex {
    var idx: ColumnIndex = .{};
    var t = header;
    var i: usize = 0;

    while (try t.next()) |field| : (i += 1) {
        // Case-sensitive match per FOCUS spec (headers are case-sensitive usually?
        // Spec 1.0 says Capitalized CamelCase e.g. BilledCost)
        // We will be strict but maybe case-insensitive if needed later.
        // For now, Strict.

        if (std.mem.eql(u8, field.raw, "ResourceId")) {
            idx.resource_id = i;
        } else if (std.mem.eql(u8, field.raw, "BilledCost")) {
            idx.billed_cost = i;
        } else if (std.mem.eql(u8, field.raw, "ChargePeriodStart")) {
            idx.period_start = i;
        } else if (std.mem.eql(u8, field.raw, "Tags")) {
            idx.tags = i;
        } else if (std.mem.eql(u8, field.raw, "x-call-count")) {
            idx.x_call_count = i;
        } else if (std.mem.eql(u8, field.raw, "x-cache-hit-ratio")) {
            idx.x_cache_hit_ratio = i;
        }
    }

    return idx;
}

/// Parses a row into a RowView using a scratch allocator for temporary unescaping.
/// The returned RowView contains slices that are either:
/// 1. Direct pointers into the CSV line buffer (if no escaping needed).
/// 2. Pointers into `scratch_allocator` (if unescaping was needed).
pub fn parseRow(scratch_allocator: Allocator, row_tokenizer: csv.Tokenizer, indices: ColumnIndex) !RowView {
    var t = row_tokenizer;
    var current_idx: usize = 0;

    var rec = RowView{
        .resource_id = "",
        .billed_cost = 0,
        .period_start = "",
    };

    // Validate indices are ready
    if (indices.resource_id == null or indices.billed_cost == null or indices.period_start == null) {
        return error.InvalidColumnMapping;
    }
    const idx_rid = indices.resource_id.?;
    const idx_cost = indices.billed_cost.?;
    const idx_start = indices.period_start.?;

    // We iterate through fields
    while (try t.next()) |field| : (current_idx += 1) {
        if (current_idx == idx_rid) {
            // ResourceId usually simple, likely zero-copy
            if (field.has_escapes) {
                rec.resource_id = try field.toOwned(scratch_allocator);
            } else {
                rec.resource_id = field.raw;
            }
        } else if (current_idx == idx_cost) {
            rec.billed_cost = try parseCostMicroUsd(field.raw);
        } else if (current_idx == idx_start) {
            if (field.has_escapes) {
                rec.period_start = try field.toOwned(scratch_allocator);
            } else {
                rec.period_start = field.raw;
            }
        } else if (indices.tags != null and current_idx == indices.tags.?) {
            // Tags is a JSON string. Likely quoted -> field.has_escapes = true.
            // We need the unescaped JSON content to parse it.
            const json_body = if (field.has_escapes)
                try field.toOwned(scratch_allocator)
            else
                field.raw;

            extractTagsAllowlist(scratch_allocator, json_body, &rec);
        } else if (indices.x_call_count != null and current_idx == indices.x_call_count.?) {
            rec.call_count = std.fmt.parseInt(u64, field.raw, 10) catch null;
        } else if (indices.x_cache_hit_ratio != null and current_idx == indices.x_cache_hit_ratio.?) {
            rec.cache_hit_ratio = parseRatioPpm(field.raw) catch null;
        }
    }

    if (rec.resource_id.len == 0) return error.MissingResourceId;
    return rec;
}

/// Parses "1.25" or "0.0005" to MicroUSD (i128) without floats.
/// Handles sign, absolute value parsing, and 6-decimal rounding (half-up).
fn parseCostMicroUsd(raw_in: []const u8) !i128 {
    var raw = std.mem.trim(u8, raw_in, " \t\r\n");
    if (raw.len == 0) return error.InvalidCost;

    var sign: i128 = 1;
    if (raw[0] == '-') {
        sign = -1;
        raw = raw[1..];
    } else if (raw[0] == '+') {
        raw = raw[1..];
    }

    // split on '.'
    const dot_opt = std.mem.indexOfScalar(u8, raw, '.');
    const int_str = if (dot_opt) |d| raw[0..d] else raw;
    const frac_str = if (dot_opt) |d| raw[d + 1 ..] else "";

    var int_part: i128 = 0;
    if (int_str.len != 0) {
        // validate digits (no commas)
        for (int_str) |c| if (c < '0' or c > '9') return error.InvalidCost;
        int_part = try std.fmt.parseInt(i128, int_str, 10);
    }

    // int_part * 1_000_000 (checked)
    var micro = try std.math.mul(i128, int_part, 1_000_000);

    // parse up to 7 fractional digits (6 kept, 7th for rounding)
    var frac_micro: i128 = 0;
    var i: usize = 0;
    var place: i128 = 100_000; // first frac digit => 10^-1 => 100_000 micro
    while (i < frac_str.len and i < 6) : (i += 1) {
        const c = frac_str[i];
        if (c < '0' or c > '9') return error.InvalidCost;
        frac_micro += @as(i128, c - '0') * place;
        place = @divTrunc(place, 10);
    }
    micro = try std.math.add(i128, micro, frac_micro);

    // rounding digit (7th)
    if (frac_str.len > 6) {
        const c7 = frac_str[6];
        if (c7 < '0' or c7 > '9') return error.InvalidCost;
        if (c7 >= '5') micro = try std.math.add(i128, micro, 1); // round half up
    }

    return micro * sign;
}

/// Parses "0.95", "1.0", "0.5" to PPM (0..1_000_000).
/// Deterministic. Clamps to [0, 1_000_000].
fn parseRatioPpm(raw_in: []const u8) !u64 {
    var raw = std.mem.trim(u8, raw_in, " \t\r\n");
    if (raw.len == 0) return error.InvalidRatio;

    // Handle integer 0 or 1 edge cases quickly or generally
    const dot_opt = std.mem.indexOfScalar(u8, raw, '.');
    const int_str = if (dot_opt) |d| raw[0..d] else raw;
    const frac_str = if (dot_opt) |d| raw[d + 1 ..] else "";

    var int_val: u64 = 0;
    if (int_str.len > 0) {
        int_val = std.fmt.parseInt(u64, int_str, 10) catch return error.InvalidRatio;
    }

    // Base ppm from integer part
    var ppm = int_val * 1_000_000;

    // Add fraction part
    if (frac_str.len > 0) {
        var place: u64 = 100_000;
        var i: usize = 0;
        while (i < frac_str.len and i < 6) : (i += 1) {
            const c = frac_str[i];
            if (c < '0' or c > '9') return error.InvalidRatio;
            ppm += (c - '0') * place;
            place /= 10;
        }
        // Rounding logic for 7th digit (half up)
        if (frac_str.len > 6) {
            const c7 = frac_str[6];
            if (c7 >= '5') ppm += 1;
        }
    }

    if (ppm > 1_000_000) return 1_000_000;
    return ppm;
}

/// Streaming extractor for Allow-listed tags.
/// Scans the JSON string for specific keys without building a DOM.
fn extractTagsAllowlist(scratch: Allocator, json_in: []const u8, rec: *RowView) void {
    const json = std.mem.trim(u8, json_in, " \t\r\n");
    if (json.len == 0 or json[0] != '{') return;

    var i: usize = 1;

    var need_model = true;
    var need_scenario = true;
    var need_count = true;
    var need_hit = true;

    while (i < json.len) {
        skipWs(json, &i);
        if (i >= json.len) return;
        if (json[i] == '}') return;

        if (json[i] != '"') return;
        const key = parseJsonString(scratch, json, &i) catch return;

        skipWs(json, &i);
        if (i >= json.len or json[i] != ':') return;
        i += 1;
        skipWs(json, &i);
        if (i >= json.len) return;

        // parse value
        if (json[i] == '"') {
            const val = parseJsonString(scratch, json, &i) catch return;
            if (need_model and std.mem.eql(u8, key, "model")) {
                rec.model = val;
                need_model = false;
            } else if (need_scenario and std.mem.eql(u8, key, "scenario")) {
                rec.scenario = val;
                need_scenario = false;
            } else if (need_count and std.mem.eql(u8, key, "x-call-count")) {
                rec.call_count = std.fmt.parseInt(u64, val, 10) catch null;
                need_count = false;
            } else if (need_hit and std.mem.eql(u8, key, "x-cache-hit-ratio")) {
                rec.cache_hit_ratio = parseRatioPpm(val) catch null;
                need_hit = false;
            }
        } else {
            const tok = parseJsonToken(json, &i);
            if (need_count and std.mem.eql(u8, key, "x-call-count")) {
                rec.call_count = std.fmt.parseInt(u64, tok, 10) catch null;
                need_count = false;
            } else if (need_hit and std.mem.eql(u8, key, "x-cache-hit-ratio")) {
                rec.cache_hit_ratio = parseRatioPpm(tok) catch null;
                need_hit = false;
            }
        }

        if (!need_model and !need_scenario and !need_count and !need_hit) return;

        skipWs(json, &i);
        if (i < json.len and json[i] == ',') {
            i += 1;
            continue;
        }
        if (i < json.len and json[i] == '}') return;
    }
}

fn skipWs(s: []const u8, i: *usize) void {
    while (i.* < s.len and std.ascii.isWhitespace(s[i.*])) i.* += 1;
}

fn parseJsonToken(s: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        if (c == ',' or c == '}' or std.ascii.isWhitespace(c)) break;
    }
    return s[start..i.*];
}

fn parseJsonString(scratch: Allocator, s: []const u8, i: *usize) ![]const u8 {
    // expects s[i] == '"'
    i.* += 1;
    const start = i.*;
    var has_esc = false;

    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        if (c == '\\') {
            has_esc = true;
            i.* += 1;
            continue;
        }
        if (c == '"') break;
    }
    if (i.* >= s.len) return error.InvalidJson;

    const raw = s[start..i.*];
    i.* += 1; // consume closing quote

    if (!has_esc) return raw;
    return try unescapeJsonString(scratch, raw);
}

fn unescapeJsonString(alloc: Allocator, raw: []const u8) ![]const u8 {
    // SOTA JSON unescape (handles \uXXXX and surrogate pairs)
    // We'll operate on a fixed buffer if possible, but emojis might expand.
    // Let's use ArrayList for simplicity and correctness.
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit(); // wait, we return list.toOwnedSlice?
    // allocator must match `alloc`.

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c != '\\') {
            try list.append(c);
            continue;
        }

        i += 1;
        if (i >= raw.len) return error.InvalidJson;

        const e = raw[i];
        switch (e) {
            '"', '\\', '/' => try list.append(e),
            'b' => try list.append(0x08),
            'f' => try list.append(0x0c),
            'n' => try list.append('\n'),
            'r' => try list.append('\r'),
            't' => try list.append('\t'),
            'u' => {
                // Decode \uXXXX
                const cp1 = try parseHex4(raw, &i);

                var codepoint: u21 = cp1;

                // Check for surrogate pairs (High Surrogate followed by Low Surrogate)
                if (cp1 >= 0xD800 and cp1 <= 0xDBFF) {
                    // Expect next to be \uXXXX representing low surrogate
                    if (i + 2 < raw.len and raw[i + 1] == '\\' and raw[i + 2] == 'u') {
                        // Peek safe? parseHex4 increments i.
                        // We must first verify and consume \u
                        // i is currently at last digit of first escape.
                        // check i+1, i+2.

                        var j = i + 1;
                        if (j < raw.len and raw[j] == '\\') {
                            j += 1;
                            if (j < raw.len and raw[j] == 'u') {
                                i = j; // Advance main iterator to 'u'
                                const cp2 = try parseHex4(raw, &i);

                                if (cp2 >= 0xDC00 and cp2 <= 0xDFFF) {
                                    // Valid surrogate pair
                                    const high = @as(u32, cp1);
                                    const low = @as(u32, cp2);
                                    const combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
                                    codepoint = @intCast(combined);
                                } else {
                                    // Invalid low surrogate.
                                    // Treat strict? JSON spec says we must pair?
                                    // Or just emit replacement?
                                    // We'll error for now or emit separated?
                                    // Let's assume strict JSON.
                                    return error.InvalidJson;
                                }
                            }
                        }
                    }
                }

                // Encode UTF-8
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &buf);
                try list.appendSlice(buf[0..len]);
            },
            else => return error.InvalidJson,
        }
    }

    // Clone result to caller's allocator to match return type expectation (slice)
    // list.toOwnedSlice() uses `alloc` passed to init.
    return list.toOwnedSlice();
}

fn parseHex4(raw: []const u8, i: *usize) !u16 {
    // i is currently at 'u' (or last char).
    // wait, caller consumed 'u', i is at 'u'.
    // check bounds
    // caller loop increments i at end. so if we consume here we must be careful.
    // My Unescape loop:
    // case 'u':
    //    parseHex4(raw, &i)

    // Check we have 4 chars ahead: i+1 .. i+4
    if (i.* + 4 >= raw.len) return error.InvalidJson;

    // chars at i+1, i+2, i+3, i+4
    const s = raw[i.* + 1 .. i.* + 5];
    i.* += 4; // Advance iterator to last digit

    return std.fmt.parseInt(u16, s, 16);
}

pub fn FocusIterator(comptime ReaderType: type) type {
    return struct {
        parser: csv.Parser(ReaderType),
        cols: ColumnIndex,
        header_done: bool = false,

        const Self = @This();

        pub fn init(alloc: Allocator, reader: ReaderType, cfg: csv.Config) !Self {
            var p = try csv.Parser(ReaderType).init(alloc, reader, cfg);

            const header_line = (try p.nextLine()) orelse return error.EmptyFile;
            const cols = try resolveColumns(p.tokenizer(header_line));
            if (!cols.isReady()) return error.InvalidColumnMapping;

            return .{ .parser = p, .cols = cols, .header_done = true };
        }

        pub fn deinit(self: *Self) void {
            self.parser.deinit();
        }

        pub fn next(self: *Self, scratch: Allocator) !?RowView {
            const line = (try self.parser.nextLine()) orelse return null;
            return try parseRow(scratch, self.parser.tokenizer(line), self.cols);
        }
    };
}

test "Focus Import - Basic" {
    const header_raw = "ResourceId,BilledCost,ChargePeriodStart,Tags";
    const h_parser = csv.Tokenizer.init(header_raw, .{});
    const indices = try resolveColumns(h_parser);

    try std.testing.expect(indices.resource_id != null);
    try std.testing.expect(indices.tags != null);

    const row_raw = "gpt-4,0.05,2025-01-01,\"{\"\"model\"\": \"\"gpt-4-turbo\"\", \"\"x-call-count\"\": 10}\"";
    const t = csv.Tokenizer.init(row_raw, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rec = try parseRow(alloc, t, indices);

    try std.testing.expectEqualStrings("gpt-4", rec.resource_id);
    try std.testing.expectEqual(50000, rec.billed_cost); // 0.05 * 1M
    try std.testing.expectEqualStrings("gpt-4-turbo", rec.model.?);
    try std.testing.expectEqual(10, rec.call_count.?);
}

test "Focus Import - Cache Hit Ppm" {
    const raw = "gpt-4,0.05,2025-01-01,\"{\"\"x-cache-hit-ratio\"\": \"\"0.95\"\"}\"";
    const t = csv.Tokenizer.init(raw, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var idx = ColumnIndex{};
    idx.resource_id = 0;
    idx.billed_cost = 1;
    idx.period_start = 2;
    idx.tags = 3;

    const rec = try parseRow(arena.allocator(), t, idx);
    try std.testing.expectEqual(@as(u64, 950_000), rec.cache_hit_ratio.?);
}

test "Focus Import - Unicode Handled Correctly" {
    // "model" is first (ok). "bad" has unicode, which we now handle.
    // "copy": "\u00A9" -> "copy": "©"
    const raw = "gpt-4,0.05,2025-01-01,\"{\"\"model\"\": \"\"gpt-4\"\", \"\"copy\"\": \"\"\\u00A9\"\", \"\"scenario\"\": \"\"chat\"\"}\"";
    const t = csv.Tokenizer.init(raw, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const h_p = csv.Tokenizer.init("ResourceId,BilledCost,ChargePeriodStart,Tags", .{});
    const idx = try resolveColumns(h_p);

    const rec = try parseRow(arena.allocator(), t, idx);

    // Row valid
    try std.testing.expectEqualStrings("gpt-4", rec.resource_id);
    try std.testing.expectEqualStrings("gpt-4", rec.model.?);
    // scenario captured (no longer missed)
    try std.testing.expectEqualStrings("chat", rec.scenario.?);
}

test "Focus Import - Unicode Surrogate Pairs" {
    // "model": "gpt-\u0034o" -> "gpt-4o"
    // "scenario": "\uD83D\uDE80" -> "🚀"
    const raw = "gpt-4,0.05,2025-01-01,\"{\"\"model\"\": \"\"gpt-\\u0034o\"\", \"\"scenario\"\": \"\"\\uD83D\\uDE80\"\"}\"";
    const t = csv.Tokenizer.init(raw, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const h_p = csv.Tokenizer.init("ResourceId,BilledCost,ChargePeriodStart,Tags", .{});
    const idx = try resolveColumns(h_p);

    const rec = try parseRow(arena.allocator(), t, idx);

    try std.testing.expectEqualStrings("gpt-4", rec.resource_id);
    try std.testing.expectEqualStrings("gpt-4o", rec.model.?);
    try std.testing.expectEqualStrings("🚀", rec.scenario.?);
}
