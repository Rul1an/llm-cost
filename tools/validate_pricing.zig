// tools/validate_pricing.zig
const std = @import("std");

const MAX_DB_BYTES: usize = 256 * 1024 * 1024;

fn isHttps(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://");
}

fn isDateISO8601(s: []const u8) bool {
    // Supports "YYYY-MM-DD" (10) or "YYYY-MM-DDTHH:MM:SSZ" (20)
    if (s.len != 10 and s.len != 20) return false;

    // Check YYYY-MM-DD part
    if (s[4] != '-' or s[7] != '-') return false;
    inline for (.{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (s[i] < '0' or s[i] > '9') return false;

    const y = std.fmt.parseInt(u32, s[0..4], 10) catch return false;
    const m = std.fmt.parseInt(u32, s[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return false;

    if (y < 2000 or y > 2100) return false;
    if (m < 1 or m > 12) return false;

    // Calendar check
    const is_leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
    const days_in_month = [_]u8{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var max_days = days_in_month[m];
    if (m == 2 and is_leap) max_days = 29;

    if (d < 1 or d > max_days) return false;

    // If full timestamp, check Time part
    if (s.len == 20) {
        if (s[10] != 'T' or s[19] != 'Z') return false; // Strict Z required
        if (s[13] != ':' or s[16] != ':') return false;
        inline for (.{ 11, 12, 14, 15, 17, 18 }) |i| if (s[i] < '0' or s[i] > '9') return false;

        const hh = std.fmt.parseInt(u32, s[11..13], 10) catch return false;
        const mm = std.fmt.parseInt(u32, s[14..16], 10) catch return false;
        const ss = std.fmt.parseInt(u32, s[17..19], 10) catch return false;

        if (hh > 23) return false;
        if (mm > 59) return false;
        if (ss > 59) return false;
    }

    return true;
}

fn getObjectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

fn numberNonNegative(v: std.json.Value) bool {
    return switch (v) {
        .integer => |i| i >= 0,
        .float => |f| f >= 0.0,
        else => false,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    const args = try std.process.argsAlloc(A);
    defer std.process.argsFree(A, args);

    // usage checking
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--")) {
        // Support direct invocation too (e.g. ./validate-pricing file)
        if (args.len == 2 and !std.mem.startsWith(u8, args[1], "-")) {
            // OK, args[1] is path
        } else {
            std.debug.print("Usage: validate-pricing -- <path/to/pricing_db.json>\n", .{});
            return error.InvalidArgs;
        }
    }

    const path = args[args.len - 1];

    const bytes = try std.fs.cwd().readFileAlloc(A, path, MAX_DB_BYTES);
    defer A.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, A, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidFormat;

    const root = parsed.value.object;

    // Verify unknown root keys
    const known_root_keys = [_][]const u8{ "version", "updated_at", "generated_at", "valid_until", "models", "aliases", "sources", "changes" };
    var root_it = root.iterator();
    while (root_it.next()) |entry| {
        const key = entry.key_ptr.*;
        var known = false;
        for (known_root_keys) |k| {
            if (std.mem.eql(u8, key, k)) {
                known = true;
                break;
            }
        }
        if (!known) {
            std.debug.print("ERROR: unknown top-level key '{s}'\n", .{key});
            return error.UnknownKey;
        }
    }

    // generated_at (optional int) or updated_at (string)
    // We prefer updated_at (ISO8601) for human readability, but legacy uses generated_at (int).
    // Support both for drift detection.
    var timestamp_seconds: ?i64 = null;

    if (getObjectField(root, "generated_at")) |v| {
        if (v == .integer) {
            timestamp_seconds = v.integer;
        }
    } else if (getObjectField(root, "updated_at")) |v| {
        // Simple check if it looks like a date, we don't parse full ISO to epoch here easily without deps
        // But we can warn if formats are wrong.
        if (v != .string) return error.InvalidFormat;
        if (!isDateISO8601(v.string)) return error.InvalidFormat;
        // Parsing to epoch left as todo or we can rely on manual review for now?
        // Let's rely on validated format.
    } else {
        std.debug.print("WARN: db missing 'updated_at' or 'generated_at'\n", .{});
    }

    // Drift check only if we have unix timestamp (generated_at)
    if (timestamp_seconds) |ts| {
        const now = std.time.timestamp();
        const drift = if (now >= ts) (now - ts) else (ts - now);
        // 7 days
        if (drift > 7 * 24 * 60 * 60) {
            std.debug.print("WARN: data drift > 7d (generated_at={d}, now={d})\n", .{ ts, now });
        }
    }

    // models (required)
    const models_val = getObjectField(root, "models") orelse return error.MissingModels;
    if (models_val != .object) return error.InvalidModels;

    // Track unique IDs (JSON object keys are unique by definition in zig std parser, but good to be aware)

    var model_count: usize = 0;
    var it = models_val.object.iterator();
    while (it.next()) |entry| {
        model_count += 1;
        const model_id = entry.key_ptr.*;
        const def = entry.value_ptr.*;

        if (def != .object) {
            std.debug.print("ERROR: model {s} must be an object\n", .{model_id});
            return error.InvalidModelDef;
        }

        const o = def.object;

        // Check for unknown keys in model definition
        const known_model_keys = [_][]const u8{ "provider", "input_price_per_mtok", "output_price_per_mtok", "output_reasoning_price_per_mtok", "cache_read_price_per_mtok", "cache_write_price_per_mtok", "context_window", "input_cost_per_mtok", "output_cost_per_mtok", "description" };
        var m_it = o.iterator();
        while (m_it.next()) |m_entry| {
            const m_key = m_entry.key_ptr.*;
            var m_known = false;
            for (known_model_keys) |k| {
                if (std.mem.eql(u8, m_key, k)) {
                    m_known = true;
                    break;
                }
            }
            if (!m_known) {
                std.debug.print("ERROR: model {s} has unknown key '{s}'\n", .{ model_id, m_key });
                return error.UnknownKey;
            }
        }

        // Validate Provider
        if (getObjectField(o, "provider")) |pv| {
            if (pv != .string or pv.string.len == 0) return error.InvalidModelDef;
        } else {
            std.debug.print("ERROR: model {s} missing provider\n", .{model_id});
            return error.InvalidModelDef;
        }

        // Helper to get number as float
        const getNumber = struct {
            fn get(val: std.json.Value) ?f64 {
                return switch (val) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => null,
                };
            }
        }.get;

        var in_price: ?f64 = null;
        var out_price: ?f64 = null;

        // Sanity: any present price fields must be non-negative numbers
        const fields = [_][]const u8{
            "input_price_per_mtok",
            "output_price_per_mtok",
            "output_reasoning_price_per_mtok",
            "cache_read_price_per_mtok",
            "cache_write_price_per_mtok",
            // legacy aliases tolerated:
            "input_cost_per_mtok",
            "output_cost_per_mtok",
        };

        inline for (fields) |f| {
            if (getObjectField(o, f)) |pv| {
                if (!numberNonNegative(pv)) {
                    std.debug.print("ERROR: model {s} field {s} must be >= 0 number\n", .{ model_id, f });
                    return error.InvalidPrice;
                }

                // Capture input/output for logic check
                if (std.mem.eql(u8, f, "input_price_per_mtok")) in_price = getNumber(pv);
                if (std.mem.eql(u8, f, "output_price_per_mtok")) out_price = getNumber(pv);
            }
        }

        // Logic Check: Output should generally be >= Input
        // Exception: Embedding models where output is 0? Or specific providers.
        // Warn for now.
        if (in_price) |in| {
            if (out_price) |out| {
                if (out < in) {
                    std.debug.print("WARN: model {s} output price ({d}) < input price ({d})\n", .{ model_id, out, in });
                }
            }
        }
    }

    // Audit trail: warn if absent, validate if present
    var has_audit = false;

    if (getObjectField(root, "sources")) |sv| {
        if (sv != .array) return error.InvalidSources;
        if (sv.array.items.len == 0) {
            std.debug.print("WARN: sources[] is empty\n", .{});
        } else {
            has_audit = true;
        }
        for (sv.array.items) |item| {
            if (item != .object) return error.InvalidSources;
            const so = item.object;
            const urlv = getObjectField(so, "url") orelse return error.InvalidSources;
            const datev = getObjectField(so, "observed_at") orelse return error.InvalidSources;
            if (urlv != .string or !isHttps(urlv.string)) {
                std.debug.print("ERROR: source url invalid (must be https://...)\n", .{});
                return error.InvalidSources;
            }
            if (datev != .string or !isDateISO8601(datev.string)) return error.InvalidSources;
        }
    } else {
        std.debug.print("WARN: missing sources[] audit trail\n", .{});
    }

    if (getObjectField(root, "changes")) |cv| {
        if (cv != .array) return error.InvalidChanges;
        if (cv.array.items.len > 0) has_audit = true;

        for (cv.array.items) |item| {
            if (item != .object) return error.InvalidChanges;
            const co = item.object;
            const typev = getObjectField(co, "type") orelse return error.InvalidChanges;
            const notev = getObjectField(co, "note") orelse return error.InvalidChanges;

            if (typev != .string or typev.string.len == 0) return error.InvalidChanges;

            // Enum check for type
            const allowed_types = [_][]const u8{ "price_update", "new_model", "deprecation", "fix", "schema_update" };
            var type_valid = false;
            for (allowed_types) |t| {
                if (std.mem.eql(u8, typev.string, t)) {
                    type_valid = true;
                    break;
                }
            }
            if (!type_valid) {
                std.debug.print("ERROR: unsafe change type '{s}'. Allowed: {s}\n", .{ typev.string, allowed_types });
                return error.InvalidChanges;
            }

            if (notev != .string or notev.string.len == 0) return error.InvalidChanges;
        }
    } else {
        std.debug.print("WARN: missing changes[] audit trail\n", .{});
    }

    std.debug.print("OK: pricing_db.json valid. models={d}\n", .{model_count});
}
