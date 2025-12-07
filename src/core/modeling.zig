const std = @import("std");

pub const PricingTier = struct {
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cached_input_cost_per_million: ?f64 = null,
    tokenizer: []const u8,
};

pub const ProviderData = struct {
    models: std.StringHashMap(PricingTier),
};

pub const PricingDatabase = struct {
    schema_version: []const u8,
    generated_at: []const u8,
    providers: std.StringHashMap(std.StringHashMap(PricingTier)),
};

// JSON-compatible struct for parsing
pub const JsonPricingTier = struct {
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cached_input_cost_per_million: ?f64 = null,
    tokenizer: []const u8,
};

pub const JsonPricingDatabase = struct {
    schema_version: []const u8,
    generated_at: []const u8,
    providers: std.StringHashMap(std.StringHashMap(JsonPricingTier)),
};
