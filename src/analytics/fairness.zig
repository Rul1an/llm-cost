const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const metrics = @import("metrics.zig");
const word_count_mod = @import("word_count.zig");
const corpus_mod = @import("corpus.zig");

// Import tokenizer from parent module
const tokenizer_mod = @import("../tokenizer/mod.zig");
const registry = tokenizer_mod.registry;
const openai = tokenizer_mod.openai;

/// Statistics for a single language
pub const LanguageStats = struct {
    tokens: usize,
    words: usize,
    bytes: usize,
    fertility: f64,
    parity_ratio: f64,
};

/// Metadata about the analysis
pub const ReportMeta = struct {
    model: []const u8,
    encoding: []const u8,
    baseline: []const u8,
};

/// Global metrics across all languages
pub const GlobalMetrics = struct {
    gini_coefficient: f64,
    max_parity_ratio: f64,
    worst_language: []const u8,
};

/// Complete fairness analysis report
pub const FairnessReport = struct {
    meta: ReportMeta,
    global_metrics: GlobalMetrics,
    languages: std.StringHashMap(LanguageStats),
    allocator: Allocator,

    pub fn deinit(self: *FairnessReport) void {
        // Note: strings in meta and global_metrics are borrowed from corpus config
        // Only free what we allocated
        self.languages.deinit();
    }

    /// Custom JSON serialization using Zig 0.14.0 WriteStream API
    pub fn jsonStringify(self: @This(), out_stream: anytype) !void {
        try out_stream.beginObject();

        // meta object
        try out_stream.objectField("meta");
        try out_stream.beginObject();
        try out_stream.objectField("model");
        try out_stream.write(self.meta.model);
        try out_stream.objectField("encoding");
        try out_stream.write(self.meta.encoding);
        try out_stream.objectField("baseline");
        try out_stream.write(self.meta.baseline);
        try out_stream.endObject();

        // global_metrics object
        try out_stream.objectField("global_metrics");
        try out_stream.beginObject();
        try out_stream.objectField("gini_coefficient");
        try out_stream.write(self.global_metrics.gini_coefficient);
        try out_stream.objectField("max_parity_ratio");
        try out_stream.write(self.global_metrics.max_parity_ratio);
        try out_stream.objectField("worst_language");
        try out_stream.write(self.global_metrics.worst_language);
        try out_stream.endObject();

        // languages object
        try out_stream.objectField("languages");
        try out_stream.beginObject();

        var lang_iter = self.languages.iterator();
        while (lang_iter.next()) |entry| {
            try out_stream.objectField(entry.key_ptr.*);
            try out_stream.beginObject();

            const stats = entry.value_ptr.*;
            try out_stream.objectField("tokens");
            try out_stream.write(stats.tokens);
            try out_stream.objectField("words");
            try out_stream.write(stats.words);
            try out_stream.objectField("bytes");
            try out_stream.write(stats.bytes);
            try out_stream.objectField("fertility");
            try out_stream.write(stats.fertility);
            try out_stream.objectField("parity_ratio");
            try out_stream.write(stats.parity_ratio);

            try out_stream.endObject();
        }

        try out_stream.endObject(); // end languages
        try out_stream.endObject(); // end root
    }

    /// Serialize to JSON string
    pub fn toJson(self: @This(), allocator: Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        try json.stringify(self, .{}, list.writer());

        return list.toOwnedSlice();
    }

    /// Write JSON to writer
    pub fn writeJson(self: @This(), writer: anytype) !void {
        try json.stringify(self, .{ .whitespace = .indent_2 }, writer);
    }
};

/// Fairness Analyzer - orchestrates the analysis process
pub const FairnessAnalyzer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) FairnessAnalyzer {
        return .{ .allocator = allocator };
    }

    /// Run fairness analysis on a corpus for a specific model
    pub fn analyze(
        self: *FairnessAnalyzer,
        corpus: *corpus_mod.CorpusConfig,
        model_name: []const u8,
    ) !FairnessReport {
        // Get encoding spec for model
        const spec = registry.Registry.getEncodingForModel(model_name) orelse {
            return error.UnknownModel;
        };

        // Initialize tokenizer
        var tok = openai.OpenAITokenizer.init(self.allocator, .{
            .spec = spec,
            .approximate_ok = true,
            .bpe_version = .v2_1,
        }) catch {
            return error.TokenizerInitFailed;
        };
        defer tok.deinit(self.allocator);

        // Analyze each language
        var language_stats = std.StringHashMap(LanguageStats).init(self.allocator);
        errdefer language_stats.deinit();

        var parity_ratios = std.ArrayList(f64).init(self.allocator);
        defer parity_ratios.deinit();

        // First pass: calculate fertility for each language
        var lang_iter = corpus.languages.iterator();
        while (lang_iter.next()) |entry| {
            const lang_code = entry.key_ptr.*;
            const lang_config = entry.value_ptr.*;

            // Load text
            const text = corpus_mod.loadLanguageText(self.allocator, lang_config) catch |err| {
                std.debug.print("Warning: Could not load {s}: {}\n", .{ lang_config.path, err });
                continue;
            };
            defer self.allocator.free(text);

            // Count tokens
            const result = tok.count(self.allocator, text) catch {
                std.debug.print("Warning: Tokenization failed for {s}\n", .{lang_code});
                continue;
            };

            // Count words
            const word_count = lang_config.word_count_override orelse
                word_count_mod.countWords(text, lang_config.mode);

            // Calculate fertility
            const fertility = metrics.calculateFertility(result.tokens, word_count);

            const stats = LanguageStats{
                .tokens = result.tokens,
                .words = word_count,
                .bytes = text.len,
                .fertility = fertility,
                .parity_ratio = 0.0, // Will be calculated after baseline
            };

            try language_stats.put(lang_code, stats);
        }

        // Get baseline fertility
        const baseline_stats = language_stats.get(corpus.baseline_lang) orelse {
            return error.BaselineAnalysisFailed;
        };
        const baseline_fertility = baseline_stats.fertility;

        // Second pass: calculate parity ratios
        var max_parity: f64 = 0.0;
        var worst_lang: []const u8 = corpus.baseline_lang;

        var stats_iter = language_stats.iterator();
        while (stats_iter.next()) |entry| {
            const lang_code = entry.key_ptr.*;
            const stats = entry.value_ptr;

            const parity = metrics.calculateParityRatio(stats.fertility, baseline_fertility);
            stats.parity_ratio = parity;

            try parity_ratios.append(parity);

            if (parity > max_parity) {
                max_parity = parity;
                worst_lang = lang_code;
            }
        }

        // Calculate Gini coefficient
        const gini = metrics.calculateGini(parity_ratios.items);

        return FairnessReport{
            .meta = .{
                .model = model_name,
                .encoding = spec.name,
                .baseline = corpus.baseline_lang,
            },
            .global_metrics = .{
                .gini_coefficient = gini,
                .max_parity_ratio = max_parity,
                .worst_language = worst_lang,
            },
            .languages = language_stats,
            .allocator = self.allocator,
        };
    }
};

/// Run fairness analysis from CLI arguments
pub fn runFairnessAnalysis(
    allocator: Allocator,
    corpus_path: []const u8,
    model_name: []const u8,
    format: []const u8,
) !void {
    // Load corpus
    var corpus = try corpus_mod.loadCorpus(allocator, corpus_path);
    defer corpus.deinit(allocator);

    // Run analysis
    var analyzer = FairnessAnalyzer.init(allocator);
    var report = try analyzer.analyze(&corpus, model_name);
    defer report.deinit();

    // Output
    const stdout = std.io.getStdOut().writer();

    if (std.mem.eql(u8, format, "json")) {
        try report.writeJson(stdout);
        try stdout.writeByte('\n');
    } else {
        // Text format
        try stdout.print("Fairness Analysis Report\n", .{});
        try stdout.print("========================\n\n", .{});
        try stdout.print("Model: {s}\n", .{report.meta.model});
        try stdout.print("Encoding: {s}\n", .{report.meta.encoding});
        try stdout.print("Baseline: {s}\n\n", .{report.meta.baseline});

        try stdout.print("Global Metrics:\n", .{});
        try stdout.print("  Gini Coefficient: {d:.4}\n", .{report.global_metrics.gini_coefficient});
        try stdout.print("  Max Parity Ratio: {d:.2}x\n", .{report.global_metrics.max_parity_ratio});
        try stdout.print("  Most Taxed: {s}\n\n", .{report.global_metrics.worst_language});

        try stdout.print("Per-Language Stats:\n", .{});
        try stdout.print("{s:>6} {s:>10} {s:>10} {s:>10} {s:>12} {s:>12}\n", .{
            "Lang", "Tokens", "Words", "Bytes", "Fertility", "Parity",
        });
        try stdout.print("{s:->6} {s:->10} {s:->10} {s:->10} {s:->12} {s:->12}\n", .{
            "", "", "", "", "", "",
        });

        var lang_iter = report.languages.iterator();
        while (lang_iter.next()) |entry| {
            const lang = entry.key_ptr.*;
            const stats = entry.value_ptr.*;
            try stdout.print("{s:>6} {d:>10} {d:>10} {d:>10} {d:>12.2} {d:>11.2}x\n", .{
                lang,
                stats.tokens,
                stats.words,
                stats.bytes,
                stats.fertility,
                stats.parity_ratio,
            });
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "LanguageStats: basic creation" {
    const stats = LanguageStats{
        .tokens = 100,
        .words = 80,
        .bytes = 400,
        .fertility = 1.25,
        .parity_ratio = 1.0,
    };
    try std.testing.expectEqual(@as(usize, 100), stats.tokens);
}

test "FairnessReport: json serialization" {
    const allocator = std.testing.allocator;

    var languages = std.StringHashMap(LanguageStats).init(allocator);
    defer languages.deinit();

    try languages.put("en", .{
        .tokens = 100,
        .words = 80,
        .bytes = 400,
        .fertility = 1.25,
        .parity_ratio = 1.0,
    });

    const report = FairnessReport{
        .meta = .{
            .model = "gpt-4o",
            .encoding = "o200k_base",
            .baseline = "en",
        },
        .global_metrics = .{
            .gini_coefficient = 0.15,
            .max_parity_ratio = 1.5,
            .worst_language = "zh",
        },
        .languages = languages,
        .allocator = allocator,
    };

    const json_str = try report.toJson(allocator);
    defer allocator.free(json_str);

    // Verify it's valid JSON by parsing it back
    const parsed = try json.parseFromSlice(json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}
