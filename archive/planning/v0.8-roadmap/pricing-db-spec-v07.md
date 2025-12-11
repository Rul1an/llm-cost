# Pricing Database Module Specification

**Module**: `llm-cost/pricing`
**Version**: v0.7.0
**Status**: IMPLEMENTATION SPEC
**Date**: December 2025

---

## Overview

The Pricing Database provides model pricing data for cost estimation. It follows an **offline-first** design with optional updates from a signed remote source.

### Design Principles

1. **Offline-first**: Always works without network access
2. **Secure updates**: All remote data cryptographically signed
3. **Graceful degradation**: Stale data warns, never blocks (until hard expiry)
4. **Provider-aware**: Model → Provider mapping for FOCUS export

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Resolution Order                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. CLI flag      --pricing-file ./custom.json                  │
│         │                                                        │
│         ▼                                                        │
│  2. Env var       LLM_COST_PRICING_FILE=/path/to/prices.json    │
│         │                                                        │
│         ▼                                                        │
│  3. User cache    ~/.llm-cost/pricing-db.json (from update-db)  │
│         │                                                        │
│         ▼                                                        │
│  4. Embedded      Compiled into binary at build time            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `PricingRegistry` | `src/pricing/registry.zig` | In-memory model lookup |
| `PricingLoader` | `src/pricing/loader.zig` | Resolution chain, file parsing |
| `PricingUpdater` | `src/pricing/updater.zig` | Remote fetch, signature verification |
| `embedded_prices` | `src/pricing/embedded.zig` | Build-time snapshot (generated) |

---

## Schema Definition

### JSON Schema (v1)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_version", "generated_at", "valid_until", "models"],
  "properties": {
    "schema_version": {
      "type": "integer",
      "const": 1
    },
    "generated_at": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 timestamp when this file was generated"
    },
    "valid_until": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 timestamp after which data is considered stale"
    },
    "models": {
      "type": "object",
      "additionalProperties": { "$ref": "#/$defs/ModelPricing" }
    },
    "aliases": {
      "type": "object",
      "additionalProperties": { "type": "string" },
      "description": "Model name aliases (e.g., 'gpt-4' -> 'gpt-4-0613')"
    },
    "revocations": {
      "type": "array",
      "items": { "$ref": "#/$defs/Revocation" }
    }
  },
  "$defs": {
    "ModelPricing": {
      "type": "object",
      "required": ["provider", "input_price_per_mtok", "output_price_per_mtok"],
      "properties": {
        "provider": {
          "type": "string",
          "enum": ["OpenAI", "Anthropic", "Google", "Azure", "AWS", "Mistral", "Cohere"]
        },
        "input_price_per_mtok": {
          "type": "number",
          "minimum": 0,
          "description": "USD per 1M input tokens"
        },
        "output_price_per_mtok": {
          "type": "number",
          "minimum": 0,
          "description": "USD per 1M output tokens"
        },
        "cached_input_price_per_mtok": {
          "type": "number",
          "minimum": 0,
          "description": "USD per 1M cached input tokens (if supported)"
        },
        "context_window": {
          "type": "integer",
          "minimum": 1,
          "description": "Maximum context length in tokens"
        },
        "max_output_tokens": {
          "type": "integer",
          "minimum": 1,
          "description": "Maximum output tokens per request"
        },
        "deprecation_date": {
          "type": "string",
          "format": "date",
          "description": "Date when model will be deprecated (YYYY-MM-DD)"
        }
      }
    },
    "Revocation": {
      "type": "object",
      "required": ["key_id", "revoked_at", "reason"],
      "properties": {
        "key_id": {
          "type": "string",
          "description": "Public key fingerprint being revoked"
        },
        "revoked_at": {
          "type": "string",
          "format": "date-time"
        },
        "reason": {
          "type": "string"
        }
      }
    }
  }
}
```

### Example Data

```json
{
  "schema_version": 1,
  "generated_at": "2025-12-15T00:00:00Z",
  "valid_until": "2026-01-15T00:00:00Z",
  "models": {
    "gpt-4o": {
      "provider": "OpenAI",
      "input_price_per_mtok": 2.50,
      "output_price_per_mtok": 10.00,
      "cached_input_price_per_mtok": 1.25,
      "context_window": 128000,
      "max_output_tokens": 16384
    },
    "gpt-4o-mini": {
      "provider": "OpenAI",
      "input_price_per_mtok": 0.15,
      "output_price_per_mtok": 0.60,
      "cached_input_price_per_mtok": 0.075,
      "context_window": 128000,
      "max_output_tokens": 16384
    },
    "gpt-4-turbo": {
      "provider": "OpenAI",
      "input_price_per_mtok": 10.00,
      "output_price_per_mtok": 30.00,
      "context_window": 128000,
      "max_output_tokens": 4096,
      "deprecation_date": "2025-04-30"
    },
    "o1": {
      "provider": "OpenAI",
      "input_price_per_mtok": 15.00,
      "output_price_per_mtok": 60.00,
      "context_window": 200000,
      "max_output_tokens": 100000
    },
    "o1-mini": {
      "provider": "OpenAI",
      "input_price_per_mtok": 3.00,
      "output_price_per_mtok": 12.00,
      "context_window": 128000,
      "max_output_tokens": 65536
    },
    "claude-3-5-sonnet-20241022": {
      "provider": "Anthropic",
      "input_price_per_mtok": 3.00,
      "output_price_per_mtok": 15.00,
      "cached_input_price_per_mtok": 0.30,
      "context_window": 200000,
      "max_output_tokens": 8192
    },
    "claude-3-opus-20240229": {
      "provider": "Anthropic",
      "input_price_per_mtok": 15.00,
      "output_price_per_mtok": 75.00,
      "cached_input_price_per_mtok": 1.50,
      "context_window": 200000,
      "max_output_tokens": 4096
    },
    "claude-3-haiku-20240307": {
      "provider": "Anthropic",
      "input_price_per_mtok": 0.25,
      "output_price_per_mtok": 1.25,
      "cached_input_price_per_mtok": 0.03,
      "context_window": 200000,
      "max_output_tokens": 4096
    },
    "gemini-1.5-pro": {
      "provider": "Google",
      "input_price_per_mtok": 1.25,
      "output_price_per_mtok": 5.00,
      "cached_input_price_per_mtok": 0.3125,
      "context_window": 2000000,
      "max_output_tokens": 8192
    },
    "gemini-1.5-flash": {
      "provider": "Google",
      "input_price_per_mtok": 0.075,
      "output_price_per_mtok": 0.30,
      "cached_input_price_per_mtok": 0.01875,
      "context_window": 1000000,
      "max_output_tokens": 8192
    },
    "gemini-2.0-flash-exp": {
      "provider": "Google",
      "input_price_per_mtok": 0.00,
      "output_price_per_mtok": 0.00,
      "context_window": 1000000,
      "max_output_tokens": 8192
    }
  },
  "aliases": {
    "gpt-4": "gpt-4-0613",
    "gpt-4-turbo-preview": "gpt-4-turbo",
    "claude-3-sonnet": "claude-3-5-sonnet-20241022",
    "claude-3.5-sonnet": "claude-3-5-sonnet-20241022",
    "claude-sonnet": "claude-3-5-sonnet-20241022",
    "gemini-pro": "gemini-1.5-pro"
  },
  "revocations": []
}
```

---

## Zig Type Definitions

```zig
// src/pricing/types.zig

const std = @import("std");

pub const SchemaVersion = 1;

pub const Provider = enum {
    OpenAI,
    Anthropic,
    Google,
    Azure,
    AWS,
    Mistral,
    Cohere,
    Unknown,

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

pub const ModelPricing = struct {
    provider: Provider,
    input_price_per_mtok: f64,
    output_price_per_mtok: f64,
    cached_input_price_per_mtok: ?f64 = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    deprecation_date: ?[]const u8 = null,

    pub fn supportsCaching(self: ModelPricing) bool {
        return self.cached_input_price_per_mtok != null;
    }

    pub fn calculateCost(
        self: ModelPricing,
        input_tokens: u64,
        output_tokens: u64,
        cache_hit_ratio: ?f64,
    ) f64 {
        const input_mtok = @as(f64, @floatFromInt(input_tokens)) / 1_000_000.0;
        const output_mtok = @as(f64, @floatFromInt(output_tokens)) / 1_000_000.0;

        var input_cost: f64 = undefined;
        if (cache_hit_ratio) |ratio| {
            if (self.cached_input_price_per_mtok) |cached_price| {
                const cached_input = input_mtok * ratio;
                const uncached_input = input_mtok * (1.0 - ratio);
                input_cost = (cached_input * cached_price) + (uncached_input * self.input_price_per_mtok);
            } else {
                input_cost = input_mtok * self.input_price_per_mtok;
            }
        } else {
            input_cost = input_mtok * self.input_price_per_mtok;
        }

        const output_cost = output_mtok * self.output_price_per_mtok;
        return input_cost + output_cost;
    }
};

pub const Revocation = struct {
    key_id: []const u8,
    revoked_at: i64, // Unix timestamp
    reason: []const u8,
};

pub const PricingDatabase = struct {
    schema_version: u32,
    generated_at: i64, // Unix timestamp
    valid_until: i64, // Unix timestamp
    models: std.StringHashMap(ModelPricing),
    aliases: std.StringHashMap([]const u8),
    revocations: []const Revocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PricingDatabase {
        return .{
            .schema_version = SchemaVersion,
            .generated_at = 0,
            .valid_until = 0,
            .models = std.StringHashMap(ModelPricing).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .revocations = &[_]Revocation{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PricingDatabase) void {
        self.models.deinit();
        self.aliases.deinit();
    }

    pub fn lookup(self: *const PricingDatabase, model_name: []const u8) ?ModelPricing {
        // Direct lookup first
        if (self.models.get(model_name)) |pricing| {
            return pricing;
        }
        // Try alias resolution
        if (self.aliases.get(model_name)) |canonical| {
            return self.models.get(canonical);
        }
        return null;
    }

    pub fn getProvider(self: *const PricingDatabase, model_name: []const u8) ?Provider {
        if (self.lookup(model_name)) |pricing| {
            return pricing.provider;
        }
        return null;
    }
};

pub const ValidityStatus = enum {
    valid,
    expiring_soon, // < 7 days remaining
    stale,         // Past valid_until, within grace period
    expired,       // Past grace period (30 days)

    pub fn toExitBehavior(self: ValidityStatus) ExitBehavior {
        return switch (self) {
            .valid => .continue_normal,
            .expiring_soon => .warn_and_continue,
            .stale => .warn_and_continue,
            .expired => .error_unless_forced,
        };
    }
};

pub const ExitBehavior = enum {
    continue_normal,
    warn_and_continue,
    error_unless_forced,
};

pub const GracePeriodDays = 30;
pub const ExpiringSoonDays = 7;
```

---

## Registry Implementation

```zig
// src/pricing/registry.zig

const std = @import("std");
const types = @import("types.zig");
const loader = @import("loader.zig");
const embedded = @import("embedded.zig");

pub const Registry = struct {
    db: types.PricingDatabase,
    source: Source,
    loaded_at: i64,

    pub const Source = enum {
        cli_override,
        env_override,
        user_cache,
        embedded,
    };

    pub fn init(allocator: std.mem.Allocator, options: LoadOptions) !Registry {
        // Resolution order: CLI flag → env var → user cache → embedded

        // 1. CLI flag override
        if (options.pricing_file) |path| {
            if (loader.loadFromFile(allocator, path)) |db| {
                return Registry{
                    .db = db,
                    .source = .cli_override,
                    .loaded_at = std.time.timestamp(),
                };
            } else |_| {
                // Fall through if file doesn't exist or is invalid
            }
        }

        // 2. Environment variable
        if (std.posix.getenv("LLM_COST_PRICING_FILE")) |path| {
            if (loader.loadFromFile(allocator, path)) |db| {
                return Registry{
                    .db = db,
                    .source = .env_override,
                    .loaded_at = std.time.timestamp(),
                };
            } else |_| {
                // Fall through
            }
        }

        // 3. User cache
        const cache_path = try getUserCachePath(allocator);
        defer allocator.free(cache_path);
        if (loader.loadFromFile(allocator, cache_path)) |db| {
            return Registry{
                .db = db,
                .source = .user_cache,
                .loaded_at = std.time.timestamp(),
            };
        } else |_| {
            // Fall through
        }

        // 4. Embedded fallback (always succeeds)
        return Registry{
            .db = embedded.getEmbeddedDatabase(allocator),
            .source = .embedded,
            .loaded_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.db.deinit();
    }

    pub fn lookup(self: *const Registry, model_name: []const u8) ?types.ModelPricing {
        return self.db.lookup(model_name);
    }

    pub fn getProvider(self: *const Registry, model_name: []const u8) ?types.Provider {
        return self.db.getProvider(model_name);
    }

    pub fn checkValidity(self: *const Registry) types.ValidityStatus {
        const now = std.time.timestamp();
        const valid_until = self.db.valid_until;
        const grace_end = valid_until + (types.GracePeriodDays * 24 * 60 * 60);
        const expiring_soon = valid_until - (types.ExpiringSoonDays * 24 * 60 * 60);

        if (now > grace_end) {
            return .expired;
        } else if (now > valid_until) {
            return .stale;
        } else if (now > expiring_soon) {
            return .expiring_soon;
        } else {
            return .valid;
        }
    }

    pub fn getValidityMessage(self: *const Registry) ?[]const u8 {
        const status = self.checkValidity();
        return switch (status) {
            .valid => null,
            .expiring_soon => "Pricing data expires soon. Run: llm-cost update-db",
            .stale => "Pricing data expired. Run: llm-cost update-db",
            .expired => "Pricing data too old. Update required or use --force-stale",
        };
    }

    fn getUserCachePath(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        return std.fmt.allocPrint(allocator, "{s}/.llm-cost/pricing-db.json", .{home});
    }
};

pub const LoadOptions = struct {
    pricing_file: ?[]const u8 = null,
    force_stale: bool = false,
};
```

---

## Signature Verification

```zig
// src/pricing/verify.zig

const std = @import("std");
const types = @import("types.zig");

// Embedded public keys (pinned at build time)
pub const PrimaryPublicKey = "RWS..."; // TODO: Generate actual key
pub const SecondaryPublicKey = "RWS..."; // Emergency backup key

pub const VerificationError = error{
    InvalidSignature,
    KeyRevoked,
    SignatureMissing,
    UntrustedKey,
};

pub const VerificationResult = struct {
    valid: bool,
    signed_by: enum { primary, secondary, unknown },
    key_id: []const u8,
};

pub fn verifySignature(
    data: []const u8,
    signature: []const u8,
    revocations: []const types.Revocation,
) VerificationError!VerificationResult {
    // 1. Check revocation list FIRST
    const key_id = extractKeyId(signature);
    for (revocations) |rev| {
        if (std.mem.eql(u8, rev.key_id, key_id)) {
            return VerificationError.KeyRevoked;
        }
    }

    // 2. Verify against known public keys
    if (verifyWithKey(data, signature, PrimaryPublicKey)) {
        return VerificationResult{
            .valid = true,
            .signed_by = .primary,
            .key_id = key_id,
        };
    }

    if (verifyWithKey(data, signature, SecondaryPublicKey)) {
        return VerificationResult{
            .valid = true,
            .signed_by = .secondary,
            .key_id = key_id,
        };
    }

    return VerificationError.InvalidSignature;
}

fn extractKeyId(signature: []const u8) []const u8 {
    // Extract key ID from minisign signature format
    // First 2 bytes: signature algorithm
    // Next 8 bytes: key ID
    if (signature.len < 10) return "";
    return signature[2..10];
}

fn verifyWithKey(data: []const u8, signature: []const u8, public_key: []const u8) bool {
    // minisign verification implementation
    // Uses Ed25519 signature scheme
    _ = data;
    _ = signature;
    _ = public_key;
    // TODO: Implement actual minisign verification
    return false;
}

// For local/custom pricing files (no signature required)
pub fn verifyLocalFile(path: []const u8) bool {
    // Local files are trusted by definition (user explicitly provided them)
    _ = path;
    return true;
}
```

---

## Update Command

```zig
// src/pricing/updater.zig

const std = @import("std");
const types = @import("types.zig");
const verify = @import("verify.zig");

pub const UpdateUrl = "https://prices.llm-cost.dev/v1/pricing-db.json";
pub const SignatureUrl = "https://prices.llm-cost.dev/v1/pricing-db.json.minisig";

pub const UpdateError = error{
    NetworkError,
    VerificationFailed,
    ParseError,
    WriteError,
    KeyRevoked,
};

pub const UpdateResult = struct {
    success: bool,
    models_updated: u32,
    price_changes: []const PriceChange,
    source: []const u8,
};

pub const PriceChange = struct {
    model: []const u8,
    field: []const u8,
    old_value: f64,
    new_value: f64,
};

pub fn updateFromRemote(allocator: std.mem.Allocator, options: UpdateOptions) UpdateError!UpdateResult {
    const writer = std.io.getStdOut().writer();

    // 1. Fetch signature first (smaller, validates we can reach the server)
    writer.print("Fetching from {s}...\n", .{options.url orelse UpdateUrl}) catch {};

    const signature = fetchUrl(allocator, options.signature_url orelse SignatureUrl) catch {
        return UpdateError.NetworkError;
    };
    defer allocator.free(signature);

    // 2. Fetch pricing data
    const data = fetchUrl(allocator, options.url orelse UpdateUrl) catch {
        return UpdateError.NetworkError;
    };
    defer allocator.free(data);

    // 3. Parse to check for embedded revocations
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return UpdateError.ParseError;
    };
    defer parsed.deinit();

    // 4. Check revocation list from the NEW data
    var revocations = std.ArrayList(types.Revocation).init(allocator);
    defer revocations.deinit();
    // TODO: Extract revocations from parsed data

    // 5. Verify signature (checks revocations FIRST)
    const verification = verify.verifySignature(data, signature, revocations.items) catch |err| {
        return switch (err) {
            verify.VerificationError.KeyRevoked => UpdateError.KeyRevoked,
            else => UpdateError.VerificationFailed,
        };
    };

    writer.print("✓ Signature verified ({s})\n", .{
        if (verification.signed_by == .primary) "primary key" else "secondary key",
    }) catch {};

    // 6. Write to user cache
    const cache_path = getUserCachePath(allocator) catch {
        return UpdateError.WriteError;
    };
    defer allocator.free(cache_path);

    ensureDirectoryExists(cache_path) catch {
        return UpdateError.WriteError;
    };

    const file = std.fs.createFileAbsolute(cache_path, .{}) catch {
        return UpdateError.WriteError;
    };
    defer file.close();

    file.writeAll(data) catch {
        return UpdateError.WriteError;
    };

    // 7. Calculate changes (for user feedback)
    // TODO: Compare with existing cache to find price changes

    return UpdateResult{
        .success = true,
        .models_updated = 0, // TODO: Calculate
        .price_changes = &[_]PriceChange{},
        .source = options.url orelse UpdateUrl,
    };
}

pub fn updateFromFile(allocator: std.mem.Allocator, path: []const u8) UpdateError!UpdateResult {
    // For airgapped environments: llm-cost update-db --file ./prices.json
    // Signature file expected at ./prices.json.minisig

    const data = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
        return UpdateError.NetworkError; // Reusing error type
    };
    defer allocator.free(data);

    const sig_path = std.fmt.allocPrint(allocator, "{s}.minisig", .{path}) catch {
        return UpdateError.ParseError;
    };
    defer allocator.free(sig_path);

    const signature = std.fs.cwd().readFileAlloc(allocator, sig_path, 1024) catch {
        return UpdateError.VerificationFailed;
    };
    defer allocator.free(signature);

    // Verify and write to cache (same as remote flow)
    const verification = verify.verifySignature(data, signature, &[_]types.Revocation{}) catch {
        return UpdateError.VerificationFailed;
    };

    _ = verification;

    // Write to cache
    const cache_path = getUserCachePath(allocator) catch {
        return UpdateError.WriteError;
    };
    defer allocator.free(cache_path);

    const file = std.fs.createFileAbsolute(cache_path, .{}) catch {
        return UpdateError.WriteError;
    };
    defer file.close();

    file.writeAll(data) catch {
        return UpdateError.WriteError;
    };

    return UpdateResult{
        .success = true,
        .models_updated = 0,
        .price_changes = &[_]PriceChange{},
        .source = path,
    };
}

fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // HTTP fetch implementation
    // Using std.http.Client for Zig 0.12+
    _ = allocator;
    _ = url;
    return error.NetworkError; // TODO: Implement
}

fn getUserCachePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.llm-cost/pricing-db.json", .{home});
}

fn ensureDirectoryExists(path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub const UpdateOptions = struct {
    url: ?[]const u8 = null,
    signature_url: ?[]const u8 = null,
    file: ?[]const u8 = null,
};
```

---

## CLI Integration

```zig
// src/cli/update_db.zig

const std = @import("std");
const updater = @import("../pricing/updater.zig");

pub fn run(allocator: std.mem.Allocator, args: Args) !u8 {
    const writer = std.io.getStdOut().writer();
    const err_writer = std.io.getStdErr().writer();

    const result = if (args.file) |file|
        updater.updateFromFile(allocator, file)
    else
        updater.updateFromRemote(allocator, .{
            .url = args.url,
        });

    if (result) |res| {
        try writer.print("✓ Updated {d} models", .{res.models_updated});

        if (res.price_changes.len > 0) {
            try writer.print(" ({d} price changes detected)\n\n", .{res.price_changes.len});
            try writer.print("Notable changes:\n", .{});

            for (res.price_changes) |change| {
                const direction: []const u8 = if (change.new_value < change.old_value) "↓" else "↑";
                const pct = @abs((change.new_value - change.old_value) / change.old_value * 100);
                try writer.print("  {s}  ${d:.2} → ${d:.2} ({s}{d:.0}%)\n", .{
                    change.model,
                    change.old_value,
                    change.new_value,
                    direction,
                    pct,
                });
            }
        } else {
            try writer.print("\n", .{});
        }

        return 0;
    } else |err| {
        switch (err) {
            updater.UpdateError.NetworkError => {
                try err_writer.print("❌ Network error: Could not reach pricing server\n", .{});
                try err_writer.print("   Check your internet connection or use --file for offline update\n", .{});
                return 1;
            },
            updater.UpdateError.VerificationFailed => {
                try err_writer.print("❌ Signature verification failed\n", .{});
                try err_writer.print("   The pricing data could not be verified as authentic.\n", .{});
                try err_writer.print("   This may indicate a security issue. Do not proceed.\n", .{});
                return 2;
            },
            updater.UpdateError.KeyRevoked => {
                try err_writer.print("❌ Signing key has been revoked\n", .{});
                try err_writer.print("   Update llm-cost to the latest version: cargo install llm-cost\n", .{});
                return 2;
            },
            updater.UpdateError.ParseError => {
                try err_writer.print("❌ Could not parse pricing data\n", .{});
                try err_writer.print("   The data format may be corrupted or incompatible.\n", .{});
                return 3;
            },
            updater.UpdateError.WriteError => {
                try err_writer.print("❌ Could not write to cache directory\n", .{});
                try err_writer.print("   Check permissions on ~/.llm-cost/\n", .{});
                return 3;
            },
        }
    }
}

pub const Args = struct {
    file: ?[]const u8 = null,
    url: ?[]const u8 = null,
};
```

---

## Embedded Snapshot Generation

Build script generates `embedded.zig` from source data:

```python
#!/usr/bin/env python3
# scripts/generate_embedded_pricing.py

import json
import sys
from datetime import datetime, timedelta

def generate_zig_source(pricing_data: dict) -> str:
    output = '''// AUTO-GENERATED - DO NOT EDIT
// Generated: {generated}
// Source: {source}

const std = @import("std");
const types = @import("types.zig");

pub fn getEmbeddedDatabase(allocator: std.mem.Allocator) types.PricingDatabase {{
    var db = types.PricingDatabase.init(allocator);
    
    db.generated_at = {generated_ts};
    db.valid_until = {valid_until_ts};
    
    // Models
'''
    
    for model_name, model_data in pricing_data['models'].items():
        output += f'''    db.models.put("{model_name}", .{{
        .provider = .{model_data['provider']},
        .input_price_per_mtok = {model_data['input_price_per_mtok']},
        .output_price_per_mtok = {model_data['output_price_per_mtok']},
'''
        if 'cached_input_price_per_mtok' in model_data:
            output += f'''        .cached_input_price_per_mtok = {model_data['cached_input_price_per_mtok']},
'''
        if 'context_window' in model_data:
            output += f'''        .context_window = {model_data['context_window']},
'''
        output += '''    }) catch unreachable;
'''
    
    output += '''
    // Aliases
'''
    for alias, target in pricing_data.get('aliases', {}).items():
        output += f'''    db.aliases.put("{alias}", "{target}") catch unreachable;
'''
    
    output += '''
    return db;
}
'''
    
    generated = datetime.utcnow()
    valid_until = generated + timedelta(days=30)
    
    return output.format(
        generated=generated.isoformat(),
        source='embedded_pricing.json',
        generated_ts=int(generated.timestamp()),
        valid_until_ts=int(valid_until.timestamp()),
    )

if __name__ == '__main__':
    with open(sys.argv[1]) as f:
        data = json.load(f)
    
    print(generate_zig_source(data))
```

Build integration:

```zig
// build.zig (relevant section)

const generate_embedded = b.addSystemCommand(&[_][]const u8{
    "python3",
    "scripts/generate_embedded_pricing.py",
    "data/pricing-db.json",
});

const embedded_source = generate_embedded.captureStdOut();

// Use as a generated source file
const pricing_module = b.addModule("pricing", .{
    .source_file = .{ .generated = embedded_source },
});
```

---

## Key Rotation Procedures

### Planned Rotation (Quarterly)

```bash
# 1. Generate new keypair
minisign -G -p new-key.pub -s new-key.sec

# 2. Create rotation announcement (signed by OLD key)
cat > rotation.json << EOF
{
  "action": "rotate",
  "new_public_key": "$(cat new-key.pub)",
  "effective_date": "2026-03-01T00:00:00Z",
  "transition_end": "2026-06-01T00:00:00Z",
  "reason": "Scheduled quarterly rotation"
}
EOF
minisign -S -s old-key.sec -m rotation.json

# 3. Update pricing DB to dual-sign
minisign -S -s old-key.sec -m pricing-db.json
minisign -S -s new-key.sec -m pricing-db.json -x pricing-db.json.minisig.new

# 4. Publish both signatures during transition
# 5. Release new CLI version with new pinned key
# 6. After 90 days, remove old key from codebase
```

### Emergency Rotation (Key Compromise)

```bash
# 1. IMMEDIATELY create and publish revocation
cat > revocation.json << EOF
{
  "action": "revoke",
  "key_id": "COMPROMISED_KEY_ID",
  "revoked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reason": "Key compromise - see security advisory"
}
EOF

# 2. Sign with SECONDARY key (always kept cold)
minisign -S -s secondary-key.sec -m revocation.json

# 3. Generate new primary keypair
minisign -G -p new-primary.pub -s new-primary.sec

# 4. Publish GitHub Security Advisory (CVE)

# 5. Emergency CLI release (patch version)
#    - Pins new primary key
#    - Includes revocation in embedded data
#    - Rejects any data signed by compromised key

# 6. Sign new pricing DB with new key only (NO transition period)
minisign -S -s new-primary.sec -m pricing-db.json
```

---

## Testing Strategy

### Unit Tests

```zig
// src/pricing/tests.zig

test "lookup resolves aliases" {
    var db = types.PricingDatabase.init(std.testing.allocator);
    defer db.deinit();

    try db.models.put("gpt-4-0613", .{
        .provider = .OpenAI,
        .input_price_per_mtok = 30.0,
        .output_price_per_mtok = 60.0,
    });
    try db.aliases.put("gpt-4", "gpt-4-0613");

    const result = db.lookup("gpt-4");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.provider, .OpenAI);
}

test "validity check detects stale data" {
    var reg = Registry{
        .db = undefined,
        .source = .embedded,
        .loaded_at = std.time.timestamp(),
    };
    reg.db.valid_until = std.time.timestamp() - (35 * 24 * 60 * 60); // 35 days ago

    try std.testing.expectEqual(reg.checkValidity(), .stale);
}

test "cost calculation with caching" {
    const model = types.ModelPricing{
        .provider = .OpenAI,
        .input_price_per_mtok = 2.50,
        .output_price_per_mtok = 10.00,
        .cached_input_price_per_mtok = 1.25,
    };

    // 1M input, 100K output, 80% cache hit
    const cost = model.calculateCost(1_000_000, 100_000, 0.8);

    // Expected: (0.8M * 1.25 + 0.2M * 2.50) + (0.1M * 10.00)
    //         = (1.00 + 0.50) + 1.00 = 2.50
    try std.testing.expectApproxEqAbs(cost, 2.50, 0.01);
}

test "revoked key rejected" {
    const revocations = [_]types.Revocation{
        .{ .key_id = "BADKEY12", .revoked_at = 0, .reason = "compromised" },
    };

    const result = verify.verifySignature("data", "BADKEY12...", &revocations);
    try std.testing.expectError(verify.VerificationError.KeyRevoked, result);
}
```

### Integration Tests

```bash
#!/bin/bash
# tests/integration/pricing_db_test.sh

set -e

echo "=== Pricing DB Integration Tests ==="

# Test 1: Embedded fallback works
echo "Test 1: Embedded fallback"
rm -rf ~/.llm-cost/
OUTPUT=$(llm-cost estimate --model gpt-4o <<< "Hello world")
echo "$OUTPUT" | grep -q '\$' || (echo "FAIL: No cost output"; exit 1)
echo "PASS"

# Test 2: Stale warning appears
echo "Test 2: Stale warning"
mkdir -p ~/.llm-cost/
cat > ~/.llm-cost/pricing-db.json << 'EOF'
{"schema_version":1,"generated_at":"2025-01-01T00:00:00Z","valid_until":"2025-01-15T00:00:00Z","models":{}}
EOF
OUTPUT=$(llm-cost estimate --model gpt-4o <<< "Hello" 2>&1)
echo "$OUTPUT" | grep -q "expired" || (echo "FAIL: No stale warning"; exit 1)
echo "PASS"

# Test 3: Custom pricing file override
echo "Test 3: CLI override"
cat > /tmp/custom-prices.json << 'EOF'
{"schema_version":1,"generated_at":"2025-12-01T00:00:00Z","valid_until":"2026-12-01T00:00:00Z","models":{"test-model":{"provider":"OpenAI","input_price_per_mtok":999,"output_price_per_mtok":999}}}
EOF
OUTPUT=$(llm-cost estimate --pricing-file /tmp/custom-prices.json --model test-model <<< "Hi")
echo "$OUTPUT" | grep -q "999" && echo "PASS" || (echo "FAIL: Override not applied"; exit 1)

echo "=== All tests passed ==="
```

---

## Rollout Plan

### Week 1: Core Types & Registry

- [ ] Implement `types.zig` with all structs
- [ ] Implement `registry.zig` with resolution chain
- [ ] Generate initial `embedded.zig` from current hardcoded data
- [ ] Unit tests for lookup, aliases, cost calculation

### Week 2: Signature Verification

- [ ] Implement `verify.zig` with minisign Ed25519
- [ ] Revocation list checking
- [ ] Integration with loader
- [ ] Unit tests for verification

### Week 3: Update Command & CLI

- [ ] Implement `updater.zig`
- [ ] CLI command `llm-cost update-db`
- [ ] `--file` flag for airgapped updates
- [ ] Stale/expiry warnings in estimate output
- [ ] Integration tests

### Week 4: Infrastructure & Release

- [ ] Set up pricing DB hosting (decision: R2 vs GitHub Pages)
- [ ] Key ceremony (decision: single vs threshold)
- [ ] Initial data collection from providers
- [ ] Documentation
- [ ] v0.7.0 release

---

## Open Decisions for Team

| Decision | Options | Recommendation |
|----------|---------|----------------|
| **Hosting** | Cloudflare R2 / GitHub Pages / Self-hosted | R2 (edge caching, reliability, ~$1/mo) |
| **Key ceremony** | Single maintainer / 2-of-3 threshold | Start single, move to threshold at v1.0 |
| **Initial data** | Manual collection / Official APIs | Manual (no pricing APIs exist), document sources |

---

## References

- [minisign](https://jedisct1.github.io/minisign/) - Signature scheme
- [FOCUS Spec](https://focus.finops.org/) - Cost data standard
- [Roadmap v6](./roadmap-v1.0-final-v6.md) - Parent planning document
