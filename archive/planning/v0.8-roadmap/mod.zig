// src/pricing/mod.zig
// Pricing Module - Public API
//
// Resolution order:
// 1. CLI flag: --pricing-file
// 2. Env var: LLM_COST_DB_PATH
// 3. User cache: ~/.cache/llm-cost/pricing_db.json (XDG compliant)
// 4. Embedded snapshot (build-time fallback)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const schema = @import("schema.zig");
pub const parser = @import("parser.zig");

// Re-export main types
pub const PriceDef = schema.PriceDef;
pub const PricingDb = schema.PricingDb;
pub const Provider = schema.Provider;
pub const TokenKind = schema.TokenKind;
pub const CostOptions = schema.CostOptions;
pub const CostResult = schema.CostResult;
pub const StaleStatus = schema.StaleStatus;
pub const StaleError = schema.StaleError;
pub const ModelError = schema.ModelError;

// Embedded pricing database (build-time snapshot)
const EMBEDDED_PRICING_JSON = @embedFile("../../data/pricing_db.json");

/// Source of pricing data
pub const Source = enum {
    Embedded,
    UserCache,
    EnvVar,
    CliFlag,

    pub fn toString(self: Source) []const u8 {
        return switch (self) {
            .Embedded => "embedded snapshot",
            .UserCache => "user cache",
            .EnvVar => "environment variable",
            .CliFlag => "command line",
        };
    }
};

/// Pricing Registry - main interface for pricing operations
pub const PricingRegistry = struct {
    db: PricingDb,
    source: Source,
    source_path: ?[]const u8,
    allocator: Allocator,

    pub const Options = struct {
        /// Override pricing file path (highest priority)
        pricing_file: ?[]const u8 = null,
        /// Force stale data acceptance
        force_stale: bool = false,
    };

    pub const InitError = parser.ParseError || std.fs.File.OpenError || std.fs.File.ReadError || error{
        CriticallyStale,
        HomeDirNotFound,
    };

    /// Initialize registry with resolution order
    pub fn init(allocator: Allocator, options: Options) InitError!PricingRegistry {
        var result: PricingRegistry = .{
            .db = undefined,
            .source = .Embedded,
            .source_path = null,
            .allocator = allocator,
        };

        // Resolution order:
        // 1. CLI flag
        if (options.pricing_file) |path| {
            if (tryLoadFromFile(allocator, path)) |db| {
                result.db = db;
                result.source = .CliFlag;
                result.source_path = path;
            } else |err| {
                std.log.warn("Failed to load pricing from --pricing-file '{s}': {}", .{ path, err });
                // Fall through to next source
            }
        }

        // 2. Environment variable
        if (result.source == .Embedded) {
            if (std.posix.getenv("LLM_COST_DB_PATH")) |env_path| {
                if (tryLoadFromFile(allocator, env_path)) |db| {
                    result.db = db;
                    result.source = .EnvVar;
                    result.source_path = env_path;
                } else |err| {
                    std.log.warn("Failed to load pricing from LLM_COST_DB_PATH '{s}': {}", .{ env_path, err });
                }
            }
        }

        // 3. User cache (XDG compliant)
        if (result.source == .Embedded) {
            if (getUserCachePath(allocator)) |cache_path| {
                defer allocator.free(cache_path);
                if (tryLoadFromFile(allocator, cache_path)) |db| {
                    result.db = db;
                    result.source = .UserCache;
                    // Don't store cache_path since we freed it - it's predictable
                } else |_| {
                    // Cache miss is normal, use embedded
                }
            } else |_| {
                // No home dir, use embedded
            }
        }

        // 4. Embedded fallback (always available)
        if (result.source == .Embedded) {
            result.db = try parser.parseJson(allocator, EMBEDDED_PRICING_JSON);
        }

        // Check staleness
        try result.db.checkStale(options.force_stale);

        return result;
    }

    pub fn deinit(self: *PricingRegistry) void {
        self.db.deinit();
    }

    /// Lookup model pricing, resolving aliases
    pub fn lookup(self: *const PricingRegistry, model: []const u8) ?PriceDef {
        return self.db.lookup(model);
    }

    /// Get provider for model (for FOCUS export)
    pub fn getProvider(self: *const PricingRegistry, model: []const u8) ?[]const u8 {
        return self.db.getProvider(model);
    }

    /// Check if pricing data is stale
    pub fn isStale(self: *const PricingRegistry) StaleStatus {
        return self.db.getStaleStatus();
    }

    /// Calculate cost for a model
    pub fn calculateCost(
        self: *const PricingRegistry,
        model: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        options: CostOptions,
    ) ModelError!CostResult {
        return self.db.calculateCost(model, input_tokens, output_tokens, options);
    }

    /// Get database metadata
    pub fn getInfo(self: *const PricingRegistry) Info {
        return .{
            .source = self.source,
            .source_path = self.source_path,
            .version = self.db.version,
            .updated_at = self.db.updated_at,
            .valid_until = self.db.valid_until,
            .model_count = self.db.models.count(),
            .stale_status = self.db.getStaleStatus(),
        };
    }

    pub const Info = struct {
        source: Source,
        source_path: ?[]const u8,
        version: u32,
        updated_at: i64,
        valid_until: i64,
        model_count: usize,
        stale_status: StaleStatus,
    };
};

/// Try to load pricing database from a file
fn tryLoadFromFile(allocator: Allocator, path: []const u8) !PricingDb {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) {
        return error.UnexpectedEndOfFile;
    }

    return parser.parseJson(allocator, content);
}

/// Get XDG-compliant cache path
fn getUserCachePath(allocator: Allocator) ![]const u8 {
    // XDG_CACHE_HOME or ~/.cache
    const cache_base = std.posix.getenv("XDG_CACHE_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.HomeDirNotFound;
        break :blk try std.fs.path.join(allocator, &.{ home, ".cache" });
    };

    // On Windows, use LOCALAPPDATA
    if (builtin.os.tag == .windows) {
        if (std.posix.getenv("LOCALAPPDATA")) |appdata| {
            return try std.fs.path.join(allocator, &.{ appdata, "llm-cost", "pricing_db.json" });
        }
    }

    return try std.fs.path.join(allocator, &.{ cache_base, "llm-cost", "pricing_db.json" });
}

/// Get XDG-compliant cache directory (for update-db to write to)
pub fn getUserCacheDir(allocator: Allocator) ![]const u8 {
    const cache_base = std.posix.getenv("XDG_CACHE_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.HomeDirNotFound;
        break :blk try std.fs.path.join(allocator, &.{ home, ".cache" });
    };

    if (builtin.os.tag == .windows) {
        if (std.posix.getenv("LOCALAPPDATA")) |appdata| {
            return try std.fs.path.join(allocator, &.{ appdata, "llm-cost" });
        }
    }

    return try std.fs.path.join(allocator, &.{ cache_base, "llm-cost" });
}

// ============================================================================
// Unit Tests
// ============================================================================

test "PricingRegistry init with embedded" {
    var registry = try PricingRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    // Should load embedded data
    try std.testing.expectEqual(Source.Embedded, registry.source);

    // Should have models
    try std.testing.expect(registry.lookup("gpt-4o") != null);
    try std.testing.expect(registry.lookup("claude-3-5-sonnet") != null);
    try std.testing.expect(registry.lookup("gemini-1.5-pro") != null);
}

test "PricingRegistry lookup with aliases" {
    var registry = try PricingRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    // Direct lookup
    const direct = registry.lookup("gpt-4o-2024-11-20");
    try std.testing.expect(direct != null);

    // Alias lookup should work
    const via_alias = registry.lookup("gpt-4o-latest");
    try std.testing.expect(via_alias != null);
}

test "PricingRegistry getProvider for FOCUS" {
    var registry = try PricingRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    try std.testing.expectEqualStrings("OpenAI", registry.getProvider("gpt-4o").?);
    try std.testing.expectEqualStrings("Anthropic", registry.getProvider("claude-3-5-sonnet").?);
    try std.testing.expectEqualStrings("Google", registry.getProvider("gemini-1.5-pro").?);
}

test "PricingRegistry calculateCost" {
    var registry = try PricingRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    const result = try registry.calculateCost("gpt-4o", 1000, 500, .{});

    // 1000 input at $2.50/M = $0.0025
    // 500 output at $10.00/M = $0.005
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), result.input_cost, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), result.output_cost, 0.000001);
    try std.testing.expectEqualStrings("OpenAI", result.provider);
}

test "PricingRegistry calculateCost unknown model" {
    var registry = try PricingRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    const result = registry.calculateCost("gpt-99-ultra", 1000, 500, .{});
    try std.testing.expectError(ModelError.UnknownModel, result);
}

test "PricingRegistry getInfo" {
    var registry = try PricingRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    const info = registry.getInfo();
    try std.testing.expectEqual(Source.Embedded, info.source);
    try std.testing.expectEqual(@as(u32, 1), info.version);
    try std.testing.expect(info.model_count > 10); // We have at least 10 models
}

test "Embedded snapshot parses correctly" {
    // This tests the actual embedded JSON at compile time
    var db = try parser.parseJson(std.testing.allocator, EMBEDDED_PRICING_JSON);
    defer db.deinit();

    // Verify structure
    try std.testing.expectEqual(@as(u32, 1), db.version);

    // Verify key models exist
    try std.testing.expect(db.lookup("gpt-4o") != null);
    try std.testing.expect(db.lookup("claude-3-5-sonnet-20241022") != null);
    try std.testing.expect(db.lookup("gemini-1.5-pro") != null);

    // Verify providers are correct (case-sensitive FOCUS compliance)
    try std.testing.expectEqual(Provider.OpenAI, db.lookup("gpt-4o").?.provider);
    try std.testing.expectEqual(Provider.Anthropic, db.lookup("claude-3-5-sonnet-20241022").?.provider);
    try std.testing.expectEqual(Provider.Google, db.lookup("gemini-1.5-pro").?.provider);
}

test "Alias resolution works for all aliases" {
    var db = try parser.parseJson(std.testing.allocator, EMBEDDED_PRICING_JSON);
    defer db.deinit();

    // Test that all aliases resolve to valid models
    var alias_iter = db.aliases.iterator();
    while (alias_iter.next()) |entry| {
        const target = db.lookup(entry.value_ptr.*);
        try std.testing.expect(target != null);
    }
}
