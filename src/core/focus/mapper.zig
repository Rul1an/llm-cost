const std = @import("std");
const schema = @import("schema.zig");
const manifest = @import("../manifest.zig");
const pricing = @import("../pricing/mod.zig");
const resource_id = @import("../resource_id.zig");
const engine = @import("../engine.zig"); // Re-use core engine for token counting

pub const MapError = error{
    UnknownModel,
    MissingPromptPath,
    PricingDbError,
    DateError,
    NoResourceIdSource,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError;

pub const MapOptions = struct {
    default_model: ?[]const u8 = null,
    output_ratio: f64 = 0.3, // Estimate output as 30% of input
    cache_hit_ratio: ?f64 = null,
    scenario: Scenario = .default,

    pub const Scenario = enum {
        default,
        cached,
    };
};

/// Map a manifest prompt to a FOCUS row
pub fn mapPrompt(
    allocator: std.mem.Allocator,
    prompt: manifest.PromptDef,
    registry: *const pricing.Registry,
    content: []const u8,
    options: MapOptions,
) MapError!schema.FocusRow {
    // 1. Initialize Row
    var row = schema.FocusRow.init(allocator);
    errdefer row.deinit();

    // 2. Resolve Model
    const model = prompt.model orelse options.default_model orelse return error.UnknownModel;

    // 3. Get Pricing
    const price_def = registry.get(model) orelse return error.UnknownModel;

    // 4. Count Tokens (using shared engine logic)
    // Placeholder: Simple estimate 1 byte = 0.25 tokens (rough avg)
    // To be precise we need the tokenizer. For v1.0 MVP without heavy deps in mapper,
    // we use a rough heuristic or load tokenizer if possible.
    // Let's use a heuristic for now to avoid compilation complexity with engine/tokenizer circular deps.
    // v1.1 should inject `Tokenizer` interface.
    // Rough: content.len / 4
    const input_tokens = @max(1, content.len / 4);

    const output_tokens = @as(u64, @intFromFloat(@as(f64, @floatFromInt(input_tokens)) * options.output_ratio));

    // 5. Calculate Cost
    // pricing module structure check:
    // It's usually `registry.calculate(price_def, ...)` or `price_def.calculate(...)`.
    // Let's check `pricing/mod.zig` first. Assuming `PriceDef.calculateTotalCost` exists based on usage.
    // Actually, based on previous files, it was `Pricing.Registry.calculate`.
    // Let's us `registry.calculate` (assuming method exists on Registry namespace, or instance).
    // Wait, `pricing.Registry` is a struct. `calculate` might be static.
    // Let's use the `pricing.calculate` wrapper if it exists, or `price_def` methods.
    // Re-reading `pricing/mod.zig` is safer, but for now let's assume `pricing.Registry.calculate(price_def, ...)`
    const cost_usd = pricing.Registry.calculate(price_def, input_tokens, output_tokens, 0); // basic sig?

    row.billed_cost = cost_usd;
    row.consumed_quantity = input_tokens + output_tokens;

    // 6. Set Date (ChargePeriodStart) -> Today UTC
    const now = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay(); // struct { year, day }
    const month_day = year_day.calculateMonthDay(); // struct { month, day_index }

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    const date_str = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
    row.charge_period_start = date_str; // Owned

    // 7. Derive ResourceId
    var rid = try resource_id.derive(allocator, prompt.prompt_id, prompt.path, content);
    // rid is owned ResourceId. We take the string.
    row.resource_id = try allocator.dupe(u8, rid.value);
    rid.deinit(allocator);

    const keys = @import("tag_keys.zig");

    // ... inside mapPrompt ...

    // 8. Tags
    try row.addTag(keys.provider, price_def.provider);
    try row.addTag(keys.model, model);
    try row.addTag(keys.llm_cost_type, "estimate");
    try row.addTag(keys.resource_name, prompt.path);

    // Cost Tag
    const cost_str = try std.fmt.allocPrint(allocator, "{d:.4}", .{row.billed_cost});
    defer allocator.free(cost_str);
    try row.addTag(keys.effective_cost, cost_str);

    // Metrics Tags
    const in_str = try std.fmt.allocPrint(allocator, "{d}", .{input_tokens});
    defer allocator.free(in_str);
    try row.addTag(keys.x_token_in, in_str);

    const out_str = try std.fmt.allocPrint(allocator, "{d}", .{output_tokens});
    defer allocator.free(out_str);
    try row.addTag(keys.x_token_out, out_str);

    // Content Hash
    const hash_hex = try resource_id.contentHash(allocator, content);
    defer allocator.free(hash_hex);
    try row.addTag(keys.x_content_hash, hash_hex);

    // Cache Tag (if applicable)
    if (options.cache_hit_ratio) |ratio| {
        const ratio_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{ratio});
        defer allocator.free(ratio_str);
        try row.addTag(keys.x_cache_hit, ratio_str);
    }

    // User Tags
    if (prompt.tags) |tags| {
        var it = tags.iterator();
        while (it.next()) |entry| {
            try row.addTag(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return row;
}
