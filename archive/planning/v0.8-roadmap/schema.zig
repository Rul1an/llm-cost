// src/pricing/schema.zig
// Pricing Database Schema Types for llm-cost v0.7
//
// Design decisions:
// - Prices in "per million tokens" (_mtok) to avoid floating point drift
// - Provider names match FOCUS spec exactly (case-sensitive)
// - Stale threshold: 30 days (financial data requirement)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Token type for cost calculation
pub const TokenKind = enum {
    Input,
    Output,
    CacheRead,
    CacheWrite,
};

/// Normalized provider names for FOCUS compliance
/// These MUST match FOCUS spec exactly (case-sensitive)
pub const Provider = enum {
    OpenAI,
    Anthropic,
    Google,
    Azure,
    AWS,
    Mistral,
    Cohere,
    Unknown,

    pub fn fromString(s: []const u8) Provider {
        const map = std.ComptimeStringMap(Provider, .{
            .{ "OpenAI", .OpenAI },
            .{ "Anthropic", .Anthropic },
            .{ "Google", .Google },
            .{ "Azure", .Azure },
            .{ "AWS", .AWS },
            .{ "Mistral", .Mistral },
            .{ "Cohere", .Cohere },
        });
        return map.get(s) orelse .Unknown;
    }

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .OpenAI => "OpenAI",
            .Anthropic => "Anthropic",
            .Google => "Google",
            .Azure => "Azure",
            .AWS => "AWS",
            .Mistral => "Mistral",
            .Cohere => "Cohere",
            .Unknown => "Unknown",
        };
    }
};

/// Model pricing definition
/// All prices are in USD per million tokens (_mtok)
pub const PriceDef = struct {
    provider: Provider,
    display_name: []const u8,

    // Core pricing (USD per million tokens)
    input_price_per_mtok: f64,
    output_price_per_mtok: f64,

    // Cache pricing (optional, null if not supported)
    cache_read_price_per_mtok: ?f64 = null,
    cache_write_price_per_mtok: ?f64 = null,

    // Model capabilities
    context_window: u32 = 0,
    max_output_tokens: u32 = 0,
    supports_vision: bool = false,
    supports_function_calling: bool = false,

    // Lifecycle
    deprecation_date: ?i64 = null, // Unix timestamp
    notes: ?[]const u8 = null,

    /// Calculate cost for a given number of tokens
    /// Returns cost in USD
    pub fn calculateCost(self: PriceDef, tokens: u64, kind: TokenKind) f64 {
        const rate: f64 = switch (kind) {
            .Input => self.input_price_per_mtok,
            .Output => self.output_price_per_mtok,
            .CacheRead => self.cache_read_price_per_mtok orelse self.input_price_per_mtok,
            .CacheWrite => self.cache_write_price_per_mtok orelse 0.0,
        };

        // Multiply first, then divide for precision
        // Using constant for potential compiler optimization
        const per_mtok: f64 = 1_000_000.0;
        return @as(f64, @floatFromInt(tokens)) * rate / per_mtok;
    }

    /// Calculate total cost with optional caching scenario
    pub fn calculateTotalCost(
        self: PriceDef,
        input_tokens: u64,
        output_tokens: u64,
        options: CostOptions,
    ) CostResult {
        var input_cost: f64 = 0.0;
        var cache_read_cost: f64 = 0.0;
        var cache_write_cost: f64 = 0.0;

        if (options.cache_hit_ratio) |ratio| {
            // Split input between cached and uncached
            const cached_tokens: u64 = @intFromFloat(@as(f64, @floatFromInt(input_tokens)) * ratio);
            const uncached_tokens = input_tokens - cached_tokens;

            cache_read_cost = self.calculateCost(cached_tokens, .CacheRead);
            input_cost = self.calculateCost(uncached_tokens, .Input);

            // Cache write cost (first request only, amortized)
            if (options.include_cache_write) {
                cache_write_cost = self.calculateCost(input_tokens, .CacheWrite);
            }
        } else {
            input_cost = self.calculateCost(input_tokens, .Input);
        }

        const output_cost = self.calculateCost(output_tokens, .Output);
        const total_cost = input_cost + output_cost + cache_read_cost + cache_write_cost;

        return CostResult{
            .input_cost = input_cost,
            .output_cost = output_cost,
            .cache_read_cost = cache_read_cost,
            .cache_write_cost = cache_write_cost,
            .total_cost = total_cost,
            .provider = self.provider.toString(),
        };
    }
};

/// Options for cost calculation
pub const CostOptions = struct {
    cache_hit_ratio: ?f64 = null, // 0.0 to 1.0
    include_cache_write: bool = false,
};

/// Result of cost calculation
pub const CostResult = struct {
    input_cost: f64,
    output_cost: f64,
    cache_read_cost: f64 = 0.0,
    cache_write_cost: f64 = 0.0,
    total_cost: f64,
    currency: []const u8 = "USD",
    provider: []const u8,
};

/// Stale status for pricing data
pub const StaleStatus = enum {
    Fresh, // valid_until in future
    Stale, // expired < 30 days
    Critical, // expired > 30 days

    pub fn fromValidUntil(valid_until: i64) StaleStatus {
        const now = std.time.timestamp();
        const thirty_days: i64 = 30 * 24 * 60 * 60;

        if (now < valid_until) {
            return .Fresh;
        } else if (now < valid_until + thirty_days) {
            return .Stale;
        } else {
            return .Critical;
        }
    }
};

/// Provider metadata for FOCUS export
pub const ProviderInfo = struct {
    display_name: []const u8,
    pricing_url: []const u8,
    api_base: []const u8,
};

/// Complete pricing database
pub const PricingDb = struct {
    allocator: Allocator,

    // Metadata
    version: u32,
    updated_at: i64, // Unix timestamp
    valid_until: i64, // Unix timestamp
    source: []const u8,

    // Data
    models: std.StringHashMap(PriceDef),
    aliases: std.StringHashMap([]const u8),
    providers: std.StringHashMap(ProviderInfo),

    pub fn init(allocator: Allocator) PricingDb {
        return .{
            .allocator = allocator,
            .version = 0,
            .updated_at = 0,
            .valid_until = 0,
            .source = "",
            .models = std.StringHashMap(PriceDef).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .providers = std.StringHashMap(ProviderInfo).init(allocator),
        };
    }

    pub fn deinit(self: *PricingDb) void {
        self.models.deinit();
        self.aliases.deinit();
        self.providers.deinit();
    }

    /// Lookup model, resolving aliases
    pub fn lookup(self: *const PricingDb, model_name: []const u8) ?PriceDef {
        // Direct lookup first
        if (self.models.get(model_name)) |def| {
            return def;
        }

        // Try alias resolution
        if (self.aliases.get(model_name)) |canonical| {
            return self.models.get(canonical);
        }

        return null;
    }

    /// Get provider for model (for FOCUS export)
    pub fn getProvider(self: *const PricingDb, model_name: []const u8) ?[]const u8 {
        if (self.lookup(model_name)) |def| {
            return def.provider.toString();
        }
        return null;
    }

    /// Check if pricing data is stale
    pub fn getStaleStatus(self: *const PricingDb) StaleStatus {
        return StaleStatus.fromValidUntil(self.valid_until);
    }

    /// Check if stale and return appropriate error/warning
    pub fn checkStale(self: *const PricingDb, force_stale: bool) StaleError!void {
        const status = self.getStaleStatus();

        switch (status) {
            .Fresh => {},
            .Stale => {
                // Warning only, don't fail
                std.log.warn(
                    "Pricing data expired. Estimates may be inaccurate. Run: llm-cost update-db",
                    .{},
                );
            },
            .Critical => {
                if (!force_stale) {
                    return StaleError.CriticallyStale;
                }
                std.log.err(
                    "Pricing data critically out of date (>30 days). Using --force-stale.",
                    .{},
                );
            },
        }
    }

    /// Calculate cost for a model
    pub fn calculateCost(
        self: *const PricingDb,
        model_name: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        options: CostOptions,
    ) ModelError!CostResult {
        const def = self.lookup(model_name) orelse return ModelError.UnknownModel;
        return def.calculateTotalCost(input_tokens, output_tokens, options);
    }
};

pub const StaleError = error{
    CriticallyStale,
};

pub const ModelError = error{
    UnknownModel,
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Provider.fromString parses correctly" {
    try std.testing.expectEqual(Provider.OpenAI, Provider.fromString("OpenAI"));
    try std.testing.expectEqual(Provider.Anthropic, Provider.fromString("Anthropic"));
    try std.testing.expectEqual(Provider.Google, Provider.fromString("Google"));
    try std.testing.expectEqual(Provider.Unknown, Provider.fromString("openai")); // Case sensitive!
    try std.testing.expectEqual(Provider.Unknown, Provider.fromString("InvalidProvider"));
}

test "Provider.toString roundtrips" {
    try std.testing.expectEqualStrings("OpenAI", Provider.OpenAI.toString());
    try std.testing.expectEqualStrings("Anthropic", Provider.Anthropic.toString());
}

test "PriceDef.calculateCost basic" {
    const def = PriceDef{
        .provider = .OpenAI,
        .display_name = "GPT-4o",
        .input_price_per_mtok = 2.50,
        .output_price_per_mtok = 10.00,
    };

    // 1M tokens should cost exactly the rate
    try std.testing.expectApproxEqAbs(@as(f64, 2.50), def.calculateCost(1_000_000, .Input), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.00), def.calculateCost(1_000_000, .Output), 0.0001);

    // 1K tokens
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), def.calculateCost(1_000, .Input), 0.000001);

    // 0 tokens
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), def.calculateCost(0, .Input), 0.0001);
}

test "PriceDef.calculateCost with cache pricing" {
    const def = PriceDef{
        .provider = .Anthropic,
        .display_name = "Claude 3.5 Sonnet",
        .input_price_per_mtok = 3.00,
        .output_price_per_mtok = 15.00,
        .cache_read_price_per_mtok = 0.30,
        .cache_write_price_per_mtok = 3.75,
    };

    // Cache read should use cache price
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), def.calculateCost(1_000_000, .CacheRead), 0.0001);

    // If cache_read is null, should fall back to input price
    const def_no_cache = PriceDef{
        .provider = .OpenAI,
        .display_name = "GPT-4",
        .input_price_per_mtok = 10.00,
        .output_price_per_mtok = 30.00,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 10.00), def_no_cache.calculateCost(1_000_000, .CacheRead), 0.0001);
}

test "PriceDef.calculateTotalCost without caching" {
    const def = PriceDef{
        .provider = .OpenAI,
        .display_name = "GPT-4o",
        .input_price_per_mtok = 2.50,
        .output_price_per_mtok = 10.00,
    };

    const result = def.calculateTotalCost(1000, 500, .{});

    // 1000 input tokens at $2.50/M = $0.0025
    // 500 output tokens at $10.00/M = $0.005
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), result.input_cost, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), result.output_cost, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0075), result.total_cost, 0.000001);
    try std.testing.expectEqualStrings("OpenAI", result.provider);
}

test "PriceDef.calculateTotalCost with caching" {
    const def = PriceDef{
        .provider = .Anthropic,
        .display_name = "Claude 3.5 Sonnet",
        .input_price_per_mtok = 3.00,
        .output_price_per_mtok = 15.00,
        .cache_read_price_per_mtok = 0.30,
    };

    const result = def.calculateTotalCost(10000, 1000, .{ .cache_hit_ratio = 0.8 });

    // 10000 input, 80% cached = 8000 cache read, 2000 uncached
    // Cache read: 8000 * 0.30 / 1M = 0.0024
    // Uncached: 2000 * 3.00 / 1M = 0.006
    // Output: 1000 * 15.00 / 1M = 0.015
    try std.testing.expectApproxEqAbs(@as(f64, 0.006), result.input_cost, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0024), result.cache_read_cost, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.015), result.output_cost, 0.000001);
}

test "StaleStatus.fromValidUntil" {
    const now = std.time.timestamp();
    const day: i64 = 24 * 60 * 60;

    // Fresh: valid_until in future
    try std.testing.expectEqual(StaleStatus.Fresh, StaleStatus.fromValidUntil(now + day));

    // Stale: expired < 30 days ago
    try std.testing.expectEqual(StaleStatus.Stale, StaleStatus.fromValidUntil(now - (15 * day)));

    // Critical: expired > 30 days ago
    try std.testing.expectEqual(StaleStatus.Critical, StaleStatus.fromValidUntil(now - (45 * day)));
}

test "PricingDb lookup with aliases" {
    var db = PricingDb.init(std.testing.allocator);
    defer db.deinit();

    // Add a model
    try db.models.put("gpt-4o-2024-11-20", PriceDef{
        .provider = .OpenAI,
        .display_name = "GPT-4o",
        .input_price_per_mtok = 2.50,
        .output_price_per_mtok = 10.00,
    });

    // Add alias
    try db.aliases.put("gpt-4o", "gpt-4o-2024-11-20");

    // Direct lookup
    const direct = db.lookup("gpt-4o-2024-11-20");
    try std.testing.expect(direct != null);
    try std.testing.expectEqual(Provider.OpenAI, direct.?.provider);

    // Alias lookup
    const via_alias = db.lookup("gpt-4o");
    try std.testing.expect(via_alias != null);
    try std.testing.expectEqual(Provider.OpenAI, via_alias.?.provider);

    // Unknown model
    const unknown = db.lookup("gpt-5-ultra");
    try std.testing.expect(unknown == null);
}

test "PricingDb.getProvider for FOCUS export" {
    var db = PricingDb.init(std.testing.allocator);
    defer db.deinit();

    try db.models.put("claude-3-5-sonnet", PriceDef{
        .provider = .Anthropic,
        .display_name = "Claude 3.5 Sonnet",
        .input_price_per_mtok = 3.00,
        .output_price_per_mtok = 15.00,
    });

    const provider = db.getProvider("claude-3-5-sonnet");
    try std.testing.expect(provider != null);
    try std.testing.expectEqualStrings("Anthropic", provider.?);
}
