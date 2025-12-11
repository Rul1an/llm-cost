// src/pricing/parser.zig
// JSON parser for pricing database
//
// Handles loading from:
// 1. Embedded snapshot (@embedFile)
// 2. External file (user override or cached)

const std = @import("std");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;

const PriceDef = schema.PriceDef;
const PricingDb = schema.PricingDb;
const Provider = schema.Provider;
const ProviderInfo = schema.ProviderInfo;

pub const ParseError = error{
    InvalidJson,
    MissingRequiredField,
    InvalidVersion,
    InvalidProvider,
    InvalidTimestamp,
} || std.json.ParseError(std.json.Scanner) || Allocator.Error;

/// Parse ISO8601 timestamp to Unix timestamp
fn parseTimestamp(iso: []const u8) !i64 {
    // Simple ISO8601 parser for "YYYY-MM-DDTHH:MM:SSZ" format
    if (iso.len < 19) return ParseError.InvalidTimestamp;

    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return ParseError.InvalidTimestamp;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return ParseError.InvalidTimestamp;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return ParseError.InvalidTimestamp;
    const hour = std.fmt.parseInt(u8, iso[11..13], 10) catch return ParseError.InvalidTimestamp;
    const minute = std.fmt.parseInt(u8, iso[14..16], 10) catch return ParseError.InvalidTimestamp;
    const second = std.fmt.parseInt(u8, iso[17..19], 10) catch return ParseError.InvalidTimestamp;

    // Convert to epoch seconds (simplified, ignoring leap seconds)
    const epoch_day = epochDaysFromDate(year, month, day) catch return ParseError.InvalidTimestamp;
    const epoch_seconds: i64 = epoch_day * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return epoch_seconds;
}

/// Calculate days since Unix epoch for a given date
fn epochDaysFromDate(year: i32, month: u8, day: u8) !i64 {
    // Days in each month (non-leap year)
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    if (month < 1 or month > 12) return error.InvalidTimestamp;
    if (day < 1 or day > 31) return error.InvalidTimestamp;

    var days: i64 = 0;

    // Years since 1970
    var y = @as(i64, 1970);
    while (y < year) : (y += 1) {
        days += if (isLeapYear(@intCast(y))) 366 else 365;
    }
    while (y > year) : (y -= 1) {
        days -= if (isLeapYear(@intCast(y - 1))) 366 else 365;
    }

    // Months
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += days_in_month[m - 1];
        if (m == 2 and isLeapYear(year)) {
            days += 1;
        }
    }

    // Days
    days += day - 1;

    return days;
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

/// Parse pricing database from JSON string
pub fn parseJson(allocator: Allocator, json_str: []const u8) ParseError!PricingDb {
    var db = PricingDb.init(allocator);
    errdefer db.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return ParseError.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ParseError.InvalidJson;

    // Parse metadata
    db.version = @intCast(root.object.get("version").?.integer);
    db.source = try allocator.dupe(u8, root.object.get("source").?.string);

    // Parse timestamps
    const updated_at_str = root.object.get("updated_at").?.string;
    const valid_until_str = root.object.get("valid_until").?.string;
    db.updated_at = try parseTimestamp(updated_at_str);
    db.valid_until = try parseTimestamp(valid_until_str);

    // Parse models
    const models_obj = root.object.get("models") orelse return ParseError.MissingRequiredField;
    if (models_obj != .object) return ParseError.InvalidJson;

    var models_iter = models_obj.object.iterator();
    while (models_iter.next()) |entry| {
        const model_name = try allocator.dupe(u8, entry.key_ptr.*);
        const model_data = entry.value_ptr.*;

        if (model_data != .object) continue;

        const provider_str = model_data.object.get("provider").?.string;
        const provider = Provider.fromString(provider_str);
        if (provider == .Unknown) {
            std.log.warn("Unknown provider '{s}' for model '{s}'", .{ provider_str, model_name });
        }

        const price_def = PriceDef{
            .provider = provider,
            .display_name = try allocator.dupe(u8, model_data.object.get("display_name").?.string),
            .input_price_per_mtok = getFloat(model_data.object, "input_price_per_mtok") orelse 0.0,
            .output_price_per_mtok = getFloat(model_data.object, "output_price_per_mtok") orelse 0.0,
            .cache_read_price_per_mtok = getFloat(model_data.object, "cache_read_price_per_mtok"),
            .cache_write_price_per_mtok = getFloat(model_data.object, "cache_write_price_per_mtok"),
            .context_window = getInt(u32, model_data.object, "context_window") orelse 0,
            .max_output_tokens = getInt(u32, model_data.object, "max_output_tokens") orelse 0,
            .supports_vision = getBool(model_data.object, "supports_vision") orelse false,
            .supports_function_calling = getBool(model_data.object, "supports_function_calling") orelse false,
            .notes = if (model_data.object.get("notes")) |n| blk: {
                if (n == .string) break :blk try allocator.dupe(u8, n.string);
                break :blk null;
            } else null,
        };

        try db.models.put(model_name, price_def);
    }

    // Parse aliases
    if (root.object.get("aliases")) |aliases_obj| {
        if (aliases_obj == .object) {
            var aliases_iter = aliases_obj.object.iterator();
            while (aliases_iter.next()) |entry| {
                const alias = try allocator.dupe(u8, entry.key_ptr.*);
                const target = try allocator.dupe(u8, entry.value_ptr.*.string);
                try db.aliases.put(alias, target);
            }
        }
    }

    // Parse providers
    if (root.object.get("providers")) |providers_obj| {
        if (providers_obj == .object) {
            var providers_iter = providers_obj.object.iterator();
            while (providers_iter.next()) |entry| {
                const provider_name = try allocator.dupe(u8, entry.key_ptr.*);
                const provider_data = entry.value_ptr.*;

                if (provider_data != .object) continue;

                const info = ProviderInfo{
                    .display_name = try allocator.dupe(u8, provider_data.object.get("display_name").?.string),
                    .pricing_url = try allocator.dupe(u8, provider_data.object.get("pricing_url").?.string),
                    .api_base = try allocator.dupe(u8, provider_data.object.get("api_base").?.string),
                };

                try db.providers.put(provider_name, info);
            }
        }
    }

    return db;
}

// Helper functions to safely extract values from JSON
fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    if (obj.get(key)) |val| {
        return switch (val) {
            .float => val.float,
            .integer => @floatFromInt(val.integer),
            else => null,
        };
    }
    return null;
}

fn getInt(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    if (obj.get(key)) |val| {
        if (val == .integer) {
            return @intCast(val.integer);
        }
    }
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |val| {
        if (val == .bool) {
            return val.bool;
        }
    }
    return null;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "parseTimestamp basic" {
    // 2025-12-11T00:00:00Z
    const ts = try parseTimestamp("2025-12-11T00:00:00Z");
    // Should be a reasonable timestamp (after 2020, before 2030)
    try std.testing.expect(ts > 1577836800); // 2020-01-01
    try std.testing.expect(ts < 1893456000); // 2030-01-01
}

test "parseTimestamp known value" {
    // 1970-01-01T00:00:00Z = epoch 0
    const ts = try parseTimestamp("1970-01-01T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 0), ts);
}

test "parseTimestamp Y2K" {
    // 2000-01-01T00:00:00Z = 946684800
    const ts = try parseTimestamp("2000-01-01T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 946684800), ts);
}

test "isLeapYear" {
    try std.testing.expect(isLeapYear(2000)); // Divisible by 400
    try std.testing.expect(!isLeapYear(1900)); // Divisible by 100 but not 400
    try std.testing.expect(isLeapYear(2024)); // Divisible by 4
    try std.testing.expect(!isLeapYear(2023)); // Not divisible by 4
}

test "parseJson minimal" {
    const json =
        \\{
        \\  "version": 1,
        \\  "updated_at": "2025-12-11T00:00:00Z",
        \\  "valid_until": "2026-01-15T00:00:00Z",
        \\  "source": "test",
        \\  "models": {
        \\    "test-model": {
        \\      "provider": "OpenAI",
        \\      "display_name": "Test Model",
        \\      "input_price_per_mtok": 2.50,
        \\      "output_price_per_mtok": 10.00
        \\    }
        \\  }
        \\}
    ;

    var db = try parseJson(std.testing.allocator, json);
    defer db.deinit();

    try std.testing.expectEqual(@as(u32, 1), db.version);

    const model = db.lookup("test-model");
    try std.testing.expect(model != null);
    try std.testing.expectEqual(Provider.OpenAI, model.?.provider);
    try std.testing.expectApproxEqAbs(@as(f64, 2.50), model.?.input_price_per_mtok, 0.001);
}

test "parseJson with aliases" {
    const json =
        \\{
        \\  "version": 1,
        \\  "updated_at": "2025-12-11T00:00:00Z",
        \\  "valid_until": "2026-01-15T00:00:00Z",
        \\  "source": "test",
        \\  "models": {
        \\    "gpt-4o-2024-11-20": {
        \\      "provider": "OpenAI",
        \\      "display_name": "GPT-4o",
        \\      "input_price_per_mtok": 2.50,
        \\      "output_price_per_mtok": 10.00
        \\    }
        \\  },
        \\  "aliases": {
        \\    "gpt-4o": "gpt-4o-2024-11-20"
        \\  }
        \\}
    ;

    var db = try parseJson(std.testing.allocator, json);
    defer db.deinit();

    // Direct lookup
    try std.testing.expect(db.lookup("gpt-4o-2024-11-20") != null);

    // Alias lookup
    try std.testing.expect(db.lookup("gpt-4o") != null);

    // Provider from alias
    try std.testing.expectEqualStrings("OpenAI", db.getProvider("gpt-4o").?);
}

test "parseJson with cache pricing" {
    const json =
        \\{
        \\  "version": 1,
        \\  "updated_at": "2025-12-11T00:00:00Z",
        \\  "valid_until": "2026-01-15T00:00:00Z",
        \\  "source": "test",
        \\  "models": {
        \\    "claude-3-5-sonnet": {
        \\      "provider": "Anthropic",
        \\      "display_name": "Claude 3.5 Sonnet",
        \\      "input_price_per_mtok": 3.00,
        \\      "output_price_per_mtok": 15.00,
        \\      "cache_read_price_per_mtok": 0.30,
        \\      "cache_write_price_per_mtok": 3.75
        \\    }
        \\  }
        \\}
    ;

    var db = try parseJson(std.testing.allocator, json);
    defer db.deinit();

    const model = db.lookup("claude-3-5-sonnet").?;
    try std.testing.expectEqual(Provider.Anthropic, model.provider);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), model.cache_read_price_per_mtok.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75), model.cache_write_price_per_mtok.?, 0.001);
}
