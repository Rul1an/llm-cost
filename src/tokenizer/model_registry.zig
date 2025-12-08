const std = @import("std");
const tokenizer_registry = @import("registry.zig");

pub const AccuracyTier = enum {
    exact,      // bit-identical to reference tokenizer
    family,     // same family, but not strictly proven exact parity
    heuristic,  // generic fallback
};

pub const Provider = enum {
    openai,
    meta,
    mistral,
    generic,
};

pub const ModelFamily = enum {
    gpt4, // o200k/cl100k
    gpt3, // cl100k/p50k?
    llama3, // tiktoken-based
    mistral, // Tekken-family (Mistral) tokenizer
    // TODO: Revisit if Mistral publishes formal specs different from Tekken.
    unknown,
};

pub const ModelId = struct {
    provider: Provider,
    name: []const u8,
};

pub const ModelSpec = struct {
    id: ModelId,
    canonical_name: []const u8,
    display_name: []const u8,
    encoding: ?tokenizer_registry.EncodingSpec,
    family: ModelFamily,
    accuracy: AccuracyTier,
    has_pricing: bool,
};

const CanonicalModel = struct {
    canonical_name: []const u8,
    provider: Provider,
    short_name: []const u8,
    encoding_name: ?[]const u8,
    family: ModelFamily,
    accuracy: AccuracyTier,
    has_pricing: bool,
};

// Static database of known/supported models
const canonical_models = [_]CanonicalModel{
    .{
        .canonical_name = "openai/gpt-4o",
        .provider = .openai,
        .short_name = "gpt-4o",
        .encoding_name = "o200k_base",
        .family = .gpt4,
        .accuracy = .exact,
        .has_pricing = true,
    },
    .{
        .canonical_name = "openai/gpt-4o-mini",
        .provider = .openai,
        .short_name = "gpt-4o-mini",
        .encoding_name = "o200k_base",
        .family = .gpt4,
        .accuracy = .exact,
        .has_pricing = true,
    },
    .{
        .canonical_name = "openai/gpt-4-turbo",
        .provider = .openai,
        .short_name = "gpt-4-turbo",
        .encoding_name = "cl100k_base",
        .family = .gpt4,
        .accuracy = .exact,
        .has_pricing = true,
    },
    .{
        .canonical_name = "openai/gpt-3.5-turbo",
        .provider = .openai,
        .short_name = "gpt-3.5-turbo",
        .encoding_name = "cl100k_base",
        .family = .gpt3,
        .accuracy = .exact,
        .has_pricing = true,
    },
    // Future: Meta Llama 3 models (family tier)
};

const Alias = struct {
    alias: []const u8,
    canonical_name: []const u8,
};

const aliases = [_]Alias{
    .{ .alias = "gpt-4o", .canonical_name = "openai/gpt-4o" },
    .{ .alias = "gpt-4o-mini", .canonical_name = "openai/gpt-4o-mini" },
    .{ .alias = "gpt-4-turbo", .canonical_name = "openai/gpt-4-turbo" },
    .{ .alias = "gpt-3.5-turbo", .canonical_name = "openai/gpt-3.5-turbo" },
};

pub const ModelRegistry = struct {
    /// Resolve user-provided model string (namespaced or short) to ModelSpec.
    pub fn resolve(name: []const u8) ModelSpec {
        // 1. Namespaced? "openai/gpt-4o"
        if (std.mem.indexOfScalar(u8, name, '/')) |slash_index| {
            const provider_str = name[0..slash_index];
            const model_str = name[slash_index+1..];
            // Note: model_str isn't actively used for lookup if we match full canonical string below,
            // but conceptually useful if we had per-provider dynamic lookup.
            _ = provider_str;
            _ = model_str;

            if (resolveCanonical(name)) |spec| return spec;

            // If namespaced but not in our table, treat as unknown/heuristic with that namespace
            return genericHeuristicSpec(name);
        }

        // 2. Non-namespaced → alias lookup
        if (resolveAlias(name)) |spec| return spec;

        // 3. Fallback: generic heuristic model
        return genericHeuristicSpec(name);
    }

    /// Return all built-in specs (for --help / docs / tests).
    pub fn list() []const CanonicalModel {
        return canonical_models[0..];
    }
};

fn resolveCanonical(full_name: []const u8) ?ModelSpec {
    for (canonical_models) |cm| {
        if (std.mem.eql(u8, cm.canonical_name, full_name)) {
            return buildModelSpec(cm);
        }
    }
    return null;
}

fn resolveAlias(alias_name: []const u8) ?ModelSpec {
    for (aliases) |a| {
        if (std.mem.eql(u8, a.alias, alias_name)) {
            // Find corresponding CanonicalModel
            for (canonical_models) |cm| {
                if (std.mem.eql(u8, cm.canonical_name, a.canonical_name)) {
                    return buildModelSpec(cm);
                }
            }
        }
    }
    return null;
}

fn buildModelSpec(cm: CanonicalModel) ModelSpec {
    var encoding: ?tokenizer_registry.EncodingSpec = null;
    if (cm.encoding_name) |enc_name| {
        // NOTE: For now we map canonical encodings via simple string comparision.
        // If tokenizer_registry gets a dynamic `get()` method later, we can switch to that.
        if (std.mem.eql(u8, enc_name, "o200k_base")) {
            encoding = tokenizer_registry.Registry.o200k_base;
        } else if (std.mem.eql(u8, enc_name, "cl100k_base")) {
            encoding = tokenizer_registry.Registry.cl100k_base;
        }
    }

    return .{
        .id = .{
            .provider = cm.provider,
            .name = cm.short_name,
        },
        .canonical_name = cm.canonical_name,
        .display_name = cm.canonical_name,
        .encoding = encoding,
        .family = cm.family,
        .accuracy = cm.accuracy,
        .has_pricing = cm.has_pricing,
    };
}

fn genericHeuristicSpec(name: []const u8) ModelSpec {
    // Try to guess provider from string if present, else generic
    var provider: Provider = .generic;
    var family: ModelFamily = .unknown;
    var short_name = name;

    if (std.mem.indexOfScalar(u8, name, '/')) |idx| {
         const p_str = name[0..idx];
         short_name = name[idx+1..];

        // Heuristics: try to guess family from provider string
        if (std.mem.eql(u8, p_str, "openai")) {
            provider = .openai;
            family = .gpt4;
        } else if (std.mem.eql(u8, p_str, "meta")) {
            provider = .meta;
            family = .llama3;
        } else if (std.mem.eql(u8, p_str, "mistral")) {
            provider = .mistral;
            family = .mistral; // Changed from .tekken to .mistral
        }
    }

    return .{
        .id = .{
            .provider = provider,
            .name = short_name,
        },
        .canonical_name = name,
        .display_name = name,
        .encoding = null,            // whitespace fallback
        .family = family,
        .accuracy = .heuristic,
        .has_pricing = false,
    };
}
