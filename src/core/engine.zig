const std = @import("std");
const pricing = @import("../pricing.zig");
const openai_tok = @import("../tokenizer/openai.zig");

pub const EngineError = error{
    ModelNotFound,
    InvalidPricing,
    TokenizerNotSupported,
    TokenizerInternalError,
};

pub const TokenizerKind = enum {
    generic_whitespace,
    openai_cl100k,
    openai_o200k,
    // future: llama, mistral, etc.
};

pub const TokenizerConfig = struct {
    kind: TokenizerKind,
    /// Logical model name (e.g. "gpt-4o").
    /// Tokenizer impl maps this to internal details.
    model_name: []const u8,
};

pub const TokenResult = struct {
    tokens: usize,
};

pub const CostResult = struct {
    model_name: []const u8,

    input_tokens: usize,
    output_tokens: usize,
    reasoning_tokens: usize = 0,

    cost_input: f64,
    cost_output: f64,
    cost_reasoning: f64 = 0.0,

    cost_total: f64,
    currency: []const u8 = "USD",

    /// Round to nearest cent (useful for logging/CI).
    pub fn roundedCents(self: CostResult) i64 {
        return @intFromFloat(@round(self.cost_total * 100.0));
    }
};

/// Core API: calculate token count for text using specified tokenizer.
pub fn estimateTokens(
    alloc: std.mem.Allocator,
    cfg: TokenizerConfig,
    text: []const u8,
) EngineError!TokenResult {
    switch (cfg.kind) {
        .generic_whitespace => {
            const count = simpleWordLikeCount(text);
            return .{ .tokens = count };
        },
        .openai_cl100k, .openai_o200k => {
            // Stub call; openai_tok.estimateTokens becomes real BPE later.
            const token_count = openai_tok.estimateTokens(
                alloc,
                cfg.model_name,
                text,
            ) catch |err| switch (err) {
                error.UnsupportedModel => return EngineError.TokenizerNotSupported,
                else => return EngineError.TokenizerInternalError,
            };

            return .{ .tokens = token_count };
        },
    }
}

/// Simple whitespace-word counter as fallback.
fn simpleWordLikeCount(text: []const u8) usize {
    var in_word = false;
    var count: usize = 0;

    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (!is_space and !in_word) {
            in_word = true;
            count += 1;
        } else if (is_space) {
            in_word = false;
        }
    }
    return count;
}

/// Cost calculation based on pricing database.
/// Price fields interpreted as "per million tokens".
pub fn estimateCost(
    db: *pricing.PricingDB,
    model_name: []const u8,
    input_tokens: usize,
    output_tokens: usize,
    reasoning_tokens: usize,
) EngineError!CostResult {
    const maybe_model = db.resolveModel(model_name);
    if (maybe_model == null) {
        return EngineError.ModelNotFound;
    }

    const model = maybe_model.?;

    // Basic sanity: prices cannot be negative.
    if (model.input_price_per_million < 0.0 or model.output_price_per_million < 0.0) {
        return EngineError.InvalidPricing;
    }

    const cost_in =
        @as(f64, @floatFromInt(input_tokens)) * (model.input_price_per_million / 1_000_000.0);
    const cost_out =
        @as(f64, @floatFromInt(output_tokens)) * (model.output_price_per_million / 1_000_000.0);

    var cost_reasoning: f64 = 0.0;
    if (model.reasoning_price_per_million) |p| {
        if (p < 0.0) {
            return EngineError.InvalidPricing;
        }
        cost_reasoning = @as(f64, @floatFromInt(reasoning_tokens)) * (p / 1_000_000.0);
    }

    // Explicitly use tokenizer from model metadata inside cost result if available,
    // or keep it generic. Actually engine doesn't decide tokenizer kind here,
    // but we return cost result. The user asked for clean engine.

    return CostResult{
        .model_name = model.name, // normalized name
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .reasoning_tokens = reasoning_tokens,

        .cost_input = cost_in,
        .cost_output = cost_out,
        .cost_reasoning = cost_reasoning,
        .cost_total = cost_in + cost_out + cost_reasoning,
    };
}
