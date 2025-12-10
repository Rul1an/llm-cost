const std = @import("std");

/// Model pricing information
pub const ModelPricing = struct {
    /// Canonical model name
    name: []const u8,

    /// Aliases that map to this model
    aliases: []const []const u8 = &.{},

    /// Price per million input tokens (USD)
    input_price_per_million: f64,

    /// Price per million output tokens (USD)
    output_price_per_million: f64,

    /// Price per million reasoning tokens (USD), if applicable
    reasoning_price_per_million: ?f64 = null,

    /// Associated encoding name
    encoding: []const u8,

    /// Context window size (tokens)
    context_window: u32 = 128_000,

    /// Maximum output tokens
    max_output: u32 = 16_384,
};

/// Pricing database with model lookup
pub const PricingDB = struct {
    models: []const ModelPricing,

    /// Resolve model name (including aliases) to pricing info
    pub fn resolveModel(self: *const PricingDB, name: []const u8) ?ModelPricing {
        for (self.models) |model| {
            // Check exact name match
            if (std.mem.eql(u8, model.name, name)) return model;

            // Check aliases
            for (model.aliases) |alias| {
                if (std.mem.eql(u8, alias, name)) return model;
            }
        }
        return null;
    }

    /// List all model names (excluding aliases)
    pub fn listModels(self: *const PricingDB) []const []const u8 {
        var names: [64][]const u8 = undefined;
        var count: usize = 0;
        for (self.models) |model| {
            if (count < names.len) {
                names[count] = model.name;
                count += 1;
            }
        }
        return names[0..count];
    }
};

/// Default pricing database (December 2025 prices)
pub const DEFAULT_PRICING = PricingDB{
    .models = &DEFAULT_MODELS,
};

const DEFAULT_MODELS = [_]ModelPricing{
    // === OpenAI GPT-4o family ===
    .{
        .name = "gpt-4o",
        .aliases = &.{ "gpt-4o-2024-11-20", "gpt-4o-2024-08-06" },
        .input_price_per_million = 2.50,
        .output_price_per_million = 10.00,
        .encoding = "o200k_base",
        .context_window = 128_000,
        .max_output = 16_384,
    },
    .{
        .name = "gpt-4o-mini",
        .aliases = &.{"gpt-4o-mini-2024-07-18"},
        .input_price_per_million = 0.15,
        .output_price_per_million = 0.60,
        .encoding = "o200k_base",
        .context_window = 128_000,
        .max_output = 16_384,
    },
    .{
        .name = "gpt-4o-audio-preview",
        .input_price_per_million = 2.50,
        .output_price_per_million = 10.00,
        .encoding = "o200k_base",
    },

    // === OpenAI GPT-4 family ===
    .{
        .name = "gpt-4-turbo",
        .aliases = &.{ "gpt-4-turbo-2024-04-09", "gpt-4-turbo-preview" },
        .input_price_per_million = 10.00,
        .output_price_per_million = 30.00,
        .encoding = "cl100k_base",
        .context_window = 128_000,
        .max_output = 4_096,
    },
    .{
        .name = "gpt-4",
        .aliases = &.{ "gpt-4-0613", "gpt-4-0314" },
        .input_price_per_million = 30.00,
        .output_price_per_million = 60.00,
        .encoding = "cl100k_base",
        .context_window = 8_192,
        .max_output = 8_192,
    },
    .{
        .name = "gpt-4-32k",
        .aliases = &.{"gpt-4-32k-0613"},
        .input_price_per_million = 60.00,
        .output_price_per_million = 120.00,
        .encoding = "cl100k_base",
        .context_window = 32_768,
        .max_output = 32_768,
    },

    // === OpenAI GPT-3.5 ===
    .{
        .name = "gpt-3.5-turbo",
        .aliases = &.{ "gpt-3.5-turbo-0125", "gpt-35-turbo" },
        .input_price_per_million = 0.50,
        .output_price_per_million = 1.50,
        .encoding = "cl100k_base",
        .context_window = 16_385,
        .max_output = 4_096,
    },

    // === OpenAI o1 reasoning models ===
    .{
        .name = "o1",
        .aliases = &.{"o1-2024-12-17"},
        .input_price_per_million = 15.00,
        .output_price_per_million = 60.00,
        .reasoning_price_per_million = 60.00,
        .encoding = "o200k_base",
        .context_window = 200_000,
        .max_output = 100_000,
    },
    .{
        .name = "o1-mini",
        .aliases = &.{"o1-mini-2024-09-12"},
        .input_price_per_million = 3.00,
        .output_price_per_million = 12.00,
        .reasoning_price_per_million = 12.00,
        .encoding = "o200k_base",
        .context_window = 128_000,
        .max_output = 65_536,
    },
    .{
        .name = "o1-preview",
        .input_price_per_million = 15.00,
        .output_price_per_million = 60.00,
        .reasoning_price_per_million = 60.00,
        .encoding = "o200k_base",
    },
    .{
        .name = "o3-mini",
        .input_price_per_million = 1.10,
        .output_price_per_million = 4.40,
        .reasoning_price_per_million = 4.40,
        .encoding = "o200k_base",
        .context_window = 200_000,
        .max_output = 100_000,
    },

    // === OpenAI Embeddings ===
    .{
        .name = "text-embedding-3-small",
        .input_price_per_million = 0.02,
        .output_price_per_million = 0.0,
        .encoding = "cl100k_base",
        .context_window = 8_191,
        .max_output = 0,
    },
    .{
        .name = "text-embedding-3-large",
        .input_price_per_million = 0.13,
        .output_price_per_million = 0.0,
        .encoding = "cl100k_base",
        .context_window = 8_191,
        .max_output = 0,
    },
    .{
        .name = "text-embedding-ada-002",
        .input_price_per_million = 0.10,
        .output_price_per_million = 0.0,
        .encoding = "cl100k_base",
        .context_window = 8_191,
        .max_output = 0,
    },

    // === Anthropic Claude (estimated encoding) ===
    .{
        .name = "claude-3-5-sonnet",
        .aliases = &.{ "claude-3-5-sonnet-20241022", "claude-3.5-sonnet" },
        .input_price_per_million = 3.00,
        .output_price_per_million = 15.00,
        .encoding = "cl100k_base", // Approximation
        .context_window = 200_000,
        .max_output = 8_192,
    },
    .{
        .name = "claude-3-opus",
        .aliases = &.{"claude-3-opus-20240229"},
        .input_price_per_million = 15.00,
        .output_price_per_million = 75.00,
        .encoding = "cl100k_base",
        .context_window = 200_000,
        .max_output = 4_096,
    },
    .{
        .name = "claude-3-sonnet",
        .aliases = &.{"claude-3-sonnet-20240229"},
        .input_price_per_million = 3.00,
        .output_price_per_million = 15.00,
        .encoding = "cl100k_base",
        .context_window = 200_000,
        .max_output = 4_096,
    },
    .{
        .name = "claude-3-haiku",
        .aliases = &.{"claude-3-haiku-20240307"},
        .input_price_per_million = 0.25,
        .output_price_per_million = 1.25,
        .encoding = "cl100k_base",
        .context_window = 200_000,
        .max_output = 4_096,
    },
};

// =============================================================================
// Tests
// =============================================================================

test "PricingDB: resolve exact name" {
    const db = DEFAULT_PRICING;
    const gpt4o = db.resolveModel("gpt-4o").?;
    try std.testing.expectEqualStrings("gpt-4o", gpt4o.name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.50), gpt4o.input_price_per_million, 0.01);
}

test "PricingDB: resolve alias" {
    const db = DEFAULT_PRICING;
    const model = db.resolveModel("gpt-4o-2024-11-20").?;
    try std.testing.expectEqualStrings("gpt-4o", model.name);
}

test "PricingDB: unknown model" {
    const db = DEFAULT_PRICING;
    try std.testing.expectEqual(@as(?ModelPricing, null), db.resolveModel("nonexistent-model"));
}

test "PricingDB: reasoning model pricing" {
    const db = DEFAULT_PRICING;
    const o1 = db.resolveModel("o1").?;
    try std.testing.expect(o1.reasoning_price_per_million != null);
    try std.testing.expectApproxEqAbs(@as(f64, 60.00), o1.reasoning_price_per_million.?, 0.01);
}
