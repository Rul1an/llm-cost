const std = @import("std");
const import_pricing = @import("../pricing.zig");

pub const OutputFormat = enum {
    text,
    json,
    ndjson,
};

pub const GlobalOptions = struct {
    model: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    format: OutputFormat = .text,
    config_path: ?[]const u8 = null,
};

pub const TokenResult = struct {
    tokens: usize,
};

/// Kern-API: bereken tokens voor een stuk tekst.
/// Later komt hier de echte tokenizer (OpenAI BPE, etc.) in.
pub fn estimateTokens(
    alloc: std.mem.Allocator,
    opts: GlobalOptions,
    text: []const u8,
) !TokenResult {
    _ = alloc;
    _ = opts;

    // TODO: vervang door echte BPE/tokenizer logica.
    const count = simpleWordLikeCount(text);
    return TokenResult{ .tokens = count };
}

/// Placeholder: whitespace-gescheiden "woorden" tellen.
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

pub const CostResult = struct {
    model_name: []const u8,
    input_tokens: usize,
    output_tokens: usize,
    cost_total: f64,
    tokenizer: []const u8 = "unknown",
    currency: []const u8 = "USD",
};

pub fn estimateCost(
    db: *import_pricing.PricingDB,
    model_name: []const u8,
    input_tokens: usize,
    output_tokens: usize,
) !CostResult {
    if (db.resolveModel(model_name)) |model| {
        // Price is per million tokens
        const input_cost = @as(f64, @floatFromInt(input_tokens)) * (model.input_price_per_million / 1_000_000.0);
        const output_cost = @as(f64, @floatFromInt(output_tokens)) * (model.output_price_per_million / 1_000_000.0);

        return CostResult{
            .model_name = model.name, // Use resolved name
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cost_total = input_cost + output_cost,
            .tokenizer = model.tokenizer,
        };
    }
    return error.ModelNotFound;
}
