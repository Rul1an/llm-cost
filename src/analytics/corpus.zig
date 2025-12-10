const std = @import("std");
const json = std.json;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const word_count = @import("word_count.zig");

/// Configuration for a single language in the corpus
pub const LanguageConfig = struct {
    name: []const u8,
    path: []const u8,
    mode: word_count.WordCountMode = .whitespace,
    word_count_override: ?usize = null, // User can provide exact word count
};

/// Full corpus configuration loaded from JSON
pub const CorpusConfig = struct {
    baseline_lang: []const u8,
    languages: std.StringHashMap(LanguageConfig),

    pub fn deinit(self: *CorpusConfig, allocator: Allocator) void {
        // Free all allocated strings
        var iter = self.languages.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.name);
            allocator.free(entry.value_ptr.path);
        }
        self.languages.deinit();
        allocator.free(self.baseline_lang);
    }
};

/// Load corpus configuration from JSON file
pub fn loadCorpus(allocator: Allocator, corpus_path: []const u8) !CorpusConfig {
    // Read JSON file
    const file = try fs.cwd().openFile(corpus_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 1024 * 1024) { // 1MB limit for config file
        return error.CorpusFileTooLarge;
    }

    const json_text = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(json_text);

    return parseCorpusJson(allocator, json_text);
}

/// Parse corpus JSON string
pub fn parseCorpusJson(allocator: Allocator, json_text: []const u8) !CorpusConfig {
    const parsed = try json.parseFromSlice(json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const root = parsed.value;

    if (root != .object) {
        return error.InvalidCorpusFormat;
    }

    var baseline_lang: ?[]const u8 = null;
    var languages = std.StringHashMap(LanguageConfig).init(allocator);
    var success = false;

    // Cleanup handler
    defer if (!success) {
        var it = languages.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.name);
            allocator.free(entry.value_ptr.path);
        }
        languages.deinit();
        if (baseline_lang) |b| allocator.free(b);
    };

    // Parse config section
    if (root.object.get("config")) |config_obj| {
        if (config_obj == .object) {
            if (config_obj.object.get("baseline_lang")) |baseline| {
                if (baseline == .string) {
                    baseline_lang = try allocator.dupe(u8, baseline.string);
                } else {
                    return error.InvalidBaselineLang;
                }
            } else {
                return error.MissingBaselineLang;
            }
        } else {
            return error.InvalidConfigSection;
        }
    } else {
        return error.MissingConfigSection;
    }

    // Parse languages section
    if (root.object.get("languages")) |langs_obj| {
        if (langs_obj != .object) {
            return error.InvalidLanguagesSection;
        }

        var iter = langs_obj.object.iterator();
        while (iter.next()) |entry| {
            const lang_code = entry.key_ptr.*;
            const lang_data = entry.value_ptr.*;

            if (lang_data != .object) {
                return error.InvalidLanguageEntry;
            }

            var lang_config = LanguageConfig{
                .name = undefined,
                .path = undefined,
                .mode = .whitespace,
                .word_count_override = null,
            };

            // Parse name
            if (lang_data.object.get("name")) |name| {
                if (name == .string) {
                    lang_config.name = try allocator.dupe(u8, name.string);
                } else {
                    return error.InvalidLanguageName;
                }
            } else {
                return error.MissingLanguageName;
            }
            // If we fail after allocating name, we must clean it up.
            // But our main defer handles map loop. This entry is not in map yet.
            // So we need errdefer here: this protects against allocation failures in the path parsing block below,
            // ensuring name is freed if path allocation fails.
            errdefer allocator.free(lang_config.name);

            // Parse path
            if (lang_data.object.get("path")) |path| {
                if (path == .string) {
                    lang_config.path = try allocator.dupe(u8, path.string);
                } else {
                    return error.InvalidLanguagePath;
                }
            } else {
                return error.MissingLanguagePath;
            }
            errdefer allocator.free(lang_config.path);

            // Parse optional mode
            if (lang_data.object.get("mode")) |mode| {
                if (mode == .string) {
                    lang_config.mode = word_count.WordCountMode.fromString(mode.string) orelse .whitespace;
                }
            }

            // Parse optional word_count
            if (lang_data.object.get("word_count")) |wc| {
                if (wc == .integer) {
                    lang_config.word_count_override = @intCast(wc.integer);
                }
            }

            const key = try allocator.dupe(u8, lang_code);
            errdefer allocator.free(key);

            try languages.put(key, lang_config);
        }
    } else {
        return error.MissingLanguagesSection;
    }

    // Validate baseline exists in languages
    if (baseline_lang) |bl| {
        if (!languages.contains(bl)) {
            return error.BaselineNotInLanguages;
        }
    } else {
        return error.MissingBaselineLang; // Should be caught earlier
    }

    success = true;
    return CorpusConfig{
        .baseline_lang = baseline_lang.?,
        .languages = languages,
    };
}

/// Load text content for a language from its configured path
pub fn loadLanguageText(allocator: Allocator, lang_config: LanguageConfig) ![]const u8 {
    const file = try fs.cwd().openFile(lang_config.path, .{});
    defer file.close();

    // Limit to 100MB per language file
    return try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
}

// =============================================================================
// Tests
// =============================================================================

test "parseCorpusJson: valid minimal" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{
        \\  "config": { "baseline_lang": "en" },
        \\  "languages": {
        \\    "en": { "name": "English", "path": "en.txt" }
        \\  }
        \\}
    ;

    var config = try parseCorpusJson(allocator, json_text);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("en", config.baseline_lang);
    try std.testing.expect(config.languages.contains("en"));

    const en = config.languages.get("en").?;
    try std.testing.expectEqualStrings("English", en.name);
    try std.testing.expectEqualStrings("en.txt", en.path);
}

test "parseCorpusJson: with mode and word_count" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{
        \\  "config": { "baseline_lang": "en" },
        \\  "languages": {
        \\    "en": { "name": "English", "path": "en.txt", "mode": "whitespace" },
        \\    "zh": { "name": "Chinese", "path": "zh.txt", "mode": "character", "word_count": 1000 }
        \\  }
        \\}
    ;

    var config = try parseCorpusJson(allocator, json_text);
    defer config.deinit(allocator);

    const en = config.languages.get("en").?;
    try std.testing.expectEqual(word_count.WordCountMode.whitespace, en.mode);
    try std.testing.expectEqual(@as(?usize, null), en.word_count_override);

    const zh = config.languages.get("zh").?;
    try std.testing.expectEqual(word_count.WordCountMode.character, zh.mode);
    try std.testing.expectEqual(@as(?usize, 1000), zh.word_count_override);
}

test "parseCorpusJson: missing config" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{
        \\  "languages": {
        \\    "en": { "name": "English", "path": "en.txt" }
        \\  }
        \\}
    ;

    const result = parseCorpusJson(allocator, json_text);
    try std.testing.expectError(error.MissingConfigSection, result);
}

test "parseCorpusJson: baseline not in languages" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{
        \\  "config": { "baseline_lang": "fr" },
        \\  "languages": {
        \\    "en": { "name": "English", "path": "en.txt" }
        \\  }
        \\}
    ;

    const result = parseCorpusJson(allocator, json_text);
    try std.testing.expectError(error.BaselineNotInLanguages, result);
}
