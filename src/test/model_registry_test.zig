const std = @import("std");
const testing = std.testing;
const llm_cost = @import("llm_cost");
const model_registry = llm_cost.tokenizer.model_registry;
const AccuracyTier = model_registry.AccuracyTier;
const Provider = model_registry.Provider;

test "ModelRegistry: resolves namespaced openai/gpt-4o" {
    const spec = model_registry.ModelRegistry.resolve("openai/gpt-4o");

    try testing.expectEqual(Provider.openai, spec.id.provider);
    try testing.expectEqualStrings("gpt-4o", spec.id.name);
    try testing.expectEqualStrings("openai/gpt-4o", spec.canonical_name);

    try testing.expectEqual(AccuracyTier.exact, spec.accuracy);
    try testing.expect(spec.encoding != null);
    try testing.expectEqualStrings("o200k_base", spec.encoding.?.name);
    try testing.expectEqual(true, spec.has_pricing);
}

test "ModelRegistry: resolves alias gpt-4o to canonical" {
    const spec = model_registry.ModelRegistry.resolve("gpt-4o");

    try testing.expectEqual(Provider.openai, spec.id.provider);
    try testing.expectEqualStrings("openai/gpt-4o", spec.canonical_name);
    try testing.expectEqual(AccuracyTier.exact, spec.accuracy);
}

test "ModelRegistry: resolves legacy gpt-4-turbo" {
    const spec = model_registry.ModelRegistry.resolve("gpt-4-turbo");

    try testing.expectEqualStrings("openai/gpt-4-turbo", spec.canonical_name);
    try testing.expectEqualStrings("cl100k_base", spec.encoding.?.name);
}

test "ModelRegistry: fallback for unknown model" {
    const spec = model_registry.ModelRegistry.resolve("unknown-model-123");

    try testing.expectEqual(Provider.generic, spec.id.provider);
    try testing.expectEqualStrings("unknown-model-123", spec.canonical_name);
    try testing.expectEqual(AccuracyTier.heuristic, spec.accuracy);
    try testing.expect(spec.encoding == null);
}

test "ModelRegistry: fallback for unknown provider namespace" {
    const spec = model_registry.ModelRegistry.resolve("foo/bar");

    try testing.expectEqual(Provider.generic, spec.id.provider);
    try testing.expectEqualStrings("foo/bar", spec.canonical_name);
    try testing.expectEqualStrings("bar", spec.id.name);
    try testing.expectEqual(AccuracyTier.heuristic, spec.accuracy);
}

test "ModelRegistry: heuristic provider detection" {
    // We don't have meta config yet, so it should be heuristic but Provider.meta
    const spec = model_registry.ModelRegistry.resolve("meta/llama-3-8b");

    try testing.expectEqual(Provider.meta, spec.id.provider);
    try testing.expectEqual(AccuracyTier.heuristic, spec.accuracy);
    try testing.expect(spec.encoding == null);
}
