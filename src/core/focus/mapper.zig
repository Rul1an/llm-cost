const std = @import("std");
const Schema = @import("schema.zig");
const Manifest = @import("../manifest.zig");
const Pricing = @import("../pricing/mod.zig");

pub fn mapContext(
    allocator: std.mem.Allocator,
    prompt: Manifest.PromptDef,
    price_def: Pricing.PriceDef,
    resource_id: []const u8,
    model_name: []const u8,
    cost: f64,
    tokens_in: u64,
    tokens_out: u64,
    cache_hit_ratio: ?f64,
    test_date: ?[]const u8,
) !Schema.FocusRow {
    // 1. ChargePeriodStart (YYYY-MM-DD)
    const today = if (test_date) |td| try allocator.dupe(u8, td) else try getTodayISO(allocator);

    // 2. User Tags Processing
    var user_tags = std.StringHashMap([]const u8).init(allocator);
    if (prompt.tags) |tags| {
        var it = tags.iterator();
        while (it.next()) |entry| {
            const k = try allocator.dupe(u8, entry.key_ptr.*);
            const v = try allocator.dupe(u8, entry.value_ptr.*);
            try user_tags.put(k, v);
        }
    }

    // 3. Content Hash (Placeholder for now, or derived from prompt content if we had it here)
    // For now, we don't have content passed in easily aside from what caller might provide.
    // Let's assume empty or "calculated" if we added content hashing to pipeline.
    // The previous implementation didn't have content hash in the mapper args.
    // We'll use a placeholder "TODO" or passed arg.
    // Wait, the user's snippet showed "x-content-hash".
    // I will add a placeholder for now to satisfy the struct.
    const content_hash = try allocator.dupe(u8, "todo-hash");

    return Schema.FocusRow{
        .allocator = allocator,
        .charge_period_start = today,
        .charge_category = try allocator.dupe(u8, "Usage"),
        .billed_cost = cost,
        .resource_id = try allocator.dupe(u8, resource_id),
        .resource_type = try allocator.dupe(u8, "LLM"),
        .region_id = try allocator.dupe(u8, ""),
        .service_category = try allocator.dupe(u8, "AI and Machine Learning"),
        .service_name = try allocator.dupe(u8, "LLM Inference"),
        .consumed_quantity = tokens_in + tokens_out,
        .consumed_unit = try allocator.dupe(u8, "Tokens"),
        .resource_name = try allocator.dupe(u8, prompt.path),
        .tags = .{
            .provider = try allocator.dupe(u8, price_def.provider),
            .model = try allocator.dupe(u8, model_name),
            .token_count_input = tokens_in,
            .token_count_output = tokens_out,
            .cache_hit_ratio = cache_hit_ratio,
            .content_hash = content_hash,
            .user_tags = user_tags,
        },
    };
}

fn getTodayISO(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds = @as(u64, @intCast(ts));
    const epoch_day = epoch_seconds / 86400;

    // Simple calendar logic for YYYY-MM-DD
    const z = epoch_day + 719468;
    const era = (if (z >= 0) z else z - 146096) / 146097;
    const doe = @as(u64, @intCast(z - era * 146097));
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = @as(u64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;

    const mp_u64 = @as(u64, mp);
    const m = if (mp_u64 < 10) mp_u64 + 3 else mp_u64 - 9;
    const year = y + (if (m <= 2) @as(u64, 1) else @as(u64, 0));

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, m, d });
}
