# Technical Design Document: Fase 1.5

**Version:** 1.0  
**Status:** Draft  
**Author:** [Maintainer]  
**Date:** 2025-01  

---

## 1. Overview

Dit document beschrijft de technische architectuur en design decisions voor Fase 1.5 van llm-cost. Het doel is een stabiel fundament voor enterprise automation zonder feature creep.

### 1.1 Design Principles

1. **Zero dependencies:** Geen FFI, geen runtime downloads, single static binary
2. **Comptime over runtime:** Zig's comptime voor zero-cost abstractions
3. **Explicit over implicit:** Geen verborgen heuristics, duidelijke accuracy tiers
4. **Contract stability:** JSON schema en exit codes zijn API, niet implementation detail
5. **Offline first:** Alles werkt zonder netwerk, air-gapped deployable

### 1.2 Non-Goals

- Runtime-configurable tokenizer backends
- Plugin architectuur
- Reasoning/cached token prediction
- C ABI of WASM (Fase 2+)

---

## 2. BPE Engine v2

### 2.1 Problem Statement

De huidige heap-based BPE implementatie heeft O(N log N) complexiteit. Bij worst-case input (lange herhalingen, emoji runs) schaalt dit slecht. Moderne alternatieven (GitHub's bpe crate, BlockBPE) demonstreren dat O(N) haalbaar is.

### 2.2 Algorithm Selection

**Keuze: Backtracking met Bitfield**

Gebaseerd op GitHub's aanpak:

```
1. Pre-tokenize input (regex split op whitespace/punctuation)
2. Voor elk segment:
   a. Initialiseer bitfield[N] = all true (alle posities zijn merge candidates)
   b. Voor elke merge in vocabulary (sorted by rank):
      - Scan segment voor matches
      - Bij match: merge, update bitfield
   c. Backtrack waar nodig voor optimale encoding
3. Concatenate segment tokens
```

**Waarom niet:**
- GPU-based (BlockBPE): Overkill voor CLI tool, dependency nightmare
- Naive quadratic: Te traag
- Huggingface heap-based: Wat we nu hebben, niet lineair

### 2.3 Data Structures

```zig
/// Represents a BPE merge operation
pub const Merge = struct {
    pair: [2]u32,      // token IDs to merge
    result: u32,       // resulting token ID
    rank: u32,         // priority (lower = merge first)
};

/// Pre-computed merge lookup for O(1) pair checking
pub const MergeTable = struct {
    /// Map from (token_a, token_b) -> Merge
    /// Implemented as perfect hash or sorted array with binary search
    entries: []const Merge,
    
    pub fn lookup(self: *const MergeTable, a: u32, b: u32) ?Merge {
        // O(1) average case
    }
};

/// Bitfield tracking valid merge positions
pub const MergeMask = struct {
    bits: []u1,
    
    pub fn isCandidate(self: *const MergeMask, pos: usize) bool {
        return self.bits[pos] == 1;
    }
    
    pub fn invalidate(self: *MergeMask, pos: usize) void {
        self.bits[pos] = 0;
    }
};
```

### 2.4 Complexity Analysis

| Operation | Old (heap) | New (linear) |
|-----------|------------|--------------|
| Single merge pass | O(N log N) | O(N) |
| Full encoding | O(N log N × M) | O(N × M) |
| Memory | O(N) heap allocs | O(N) flat arrays |

Waar M = aantal unique merges (bounded door vocab size).

### 2.5 File Structure

```
src/
├── tokenizer/
│   ├── bpe_v1.zig          # Legacy heap-based (kept for comparison)
│   ├── bpe_v2.zig          # New linear implementation
│   ├── bpe.zig             # Public interface, selects implementation
│   ├── pretokenizer.zig    # Regex-based pre-tokenization
│   └── merge_table.zig     # Merge lookup structures
```

### 2.6 Migration Strategy

1. Implement bpe_v2.zig alongside bpe_v1.zig
2. Add `--bpe-engine v1|v2` flag for testing (hidden, not documented)
3. Run full parity suite against both
4. Benchmark both on standard corpus
5. Switch default to v2 when parity + perf confirmed
6. Remove v1 in v0.6.0 (one release cycle deprecation)

---

## 3. Tokenizer Backend Architecture

### 3.1 Design Goals

- Ondersteuning voor meerdere tokenizer families (tiktoken, toekomstig SentencePiece)
- Zero runtime overhead door comptime generics
- Duidelijk extensiepunt voor contributors

### 3.2 Interface Definition

```zig
/// Compile-time interface for tokenizer backends
/// Any type that satisfies this interface can be used with Tokenizer(Backend)
pub const BackendInterface = struct {
    /// Encode text to token IDs
    /// Returns error.InvalidUtf8 for malformed input
    pub fn encode(input: []const u8, allocator: Allocator) Error![]u32;
    
    /// Count tokens without full encoding (may be optimized)
    pub fn count(input: []const u8) Error!usize;
    
    /// Decode token IDs back to text
    pub fn decode(tokens: []const u32, allocator: Allocator) Error![]u8;
    
    /// Backend identifier for logging/debugging
    pub const name: []const u8;
    
    /// Accuracy tier for this backend
    pub const accuracy: Accuracy;
};

pub const Accuracy = enum {
    exact,      // Parity with reference implementation
    heuristic,  // Best-effort, may differ from vendor
    estimate,   // Rough approximation (char/4, etc.)
};
```

### 3.3 Backend Implementations

```zig
// src/tokenizer/backends/o200k.zig
pub const O200kBackend = struct {
    pub const name = "o200k_base";
    pub const accuracy = .exact;
    
    const vocab = @embedFile("../../data/o200k_base.bin");
    const merges = @embedFile("../../data/o200k_merges.bin");
    
    pub fn encode(input: []const u8, allocator: Allocator) ![]u32 {
        return bpe_v2.encode(vocab, merges, input, allocator);
    }
    
    pub fn count(input: []const u8) !usize {
        return bpe_v2.countOnly(vocab, merges, input);
    }
    
    pub fn decode(tokens: []const u32, allocator: Allocator) ![]u8 {
        return bpe_v2.decode(vocab, tokens, allocator);
    }
};

// src/tokenizer/backends/heuristic.zig
pub const HeuristicBackend = struct {
    pub const name = "heuristic";
    pub const accuracy = .estimate;
    
    /// Approximation: ~4 characters per token for English text
    const CHARS_PER_TOKEN = 4;
    
    pub fn encode(input: []const u8, allocator: Allocator) ![]u32 {
        // Not implemented - heuristic doesn't produce real tokens
        return error.NotSupported;
    }
    
    pub fn count(input: []const u8) !usize {
        return (input.len + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN;
    }
    
    pub fn decode(tokens: []const u32, allocator: Allocator) ![]u8 {
        return error.NotSupported;
    }
};
```

### 3.4 Tokenizer Generic

```zig
// src/tokenizer/tokenizer.zig
pub fn Tokenizer(comptime Backend: type) type {
    // Compile-time interface check
    comptime {
        if (!@hasDecl(Backend, "encode")) @compileError("Backend missing encode()");
        if (!@hasDecl(Backend, "count")) @compileError("Backend missing count()");
        if (!@hasDecl(Backend, "name")) @compileError("Backend missing name");
        if (!@hasDecl(Backend, "accuracy")) @compileError("Backend missing accuracy");
    }
    
    return struct {
        const Self = @This();
        
        allocator: Allocator,
        
        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }
        
        pub fn encode(self: *const Self, input: []const u8) ![]u32 {
            return Backend.encode(input, self.allocator);
        }
        
        pub fn count(self: *const Self, input: []const u8) !usize {
            return Backend.count(input);
        }
        
        pub fn decode(self: *const Self, tokens: []const u32) ![]u8 {
            return Backend.decode(tokens, self.allocator);
        }
        
        pub fn getName() []const u8 {
            return Backend.name;
        }
        
        pub fn getAccuracy() Accuracy {
            return Backend.accuracy;
        }
    };
}

// Type aliases for common use
pub const O200kTokenizer = Tokenizer(O200kBackend);
pub const Cl100kTokenizer = Tokenizer(Cl100kBackend);
pub const HeuristicTokenizer = Tokenizer(HeuristicBackend);
```

### 3.5 Model Registry

```zig
// src/model_registry.zig
pub const ModelInfo = struct {
    name: []const u8,
    provider: []const u8,
    encoding: Encoding,
    context_window: u32,
    pricing: ?PricingInfo,
};

pub const Encoding = enum {
    o200k_base,
    cl100k_base,
    heuristic,
};

/// Runtime model resolution
pub fn resolve(model_name: []const u8) ?ModelInfo {
    // Lookup in embedded model database
    return model_db.get(model_name);
}

/// Get tokenizer for a model (comptime dispatch where possible)
pub fn getTokenizer(comptime encoding: Encoding, allocator: Allocator) TokenizerUnion {
    return switch (encoding) {
        .o200k_base => .{ .o200k = O200kTokenizer.init(allocator) },
        .cl100k_base => .{ .cl100k = Cl100kTokenizer.init(allocator) },
        .heuristic => .{ .heuristic = HeuristicTokenizer.init(allocator) },
    };
}

/// Tagged union for runtime polymorphism (unavoidable for --model flag)
pub const TokenizerUnion = union(Encoding) {
    o200k: O200kTokenizer,
    cl100k: Cl100kTokenizer,
    heuristic: HeuristicTokenizer,
    
    pub fn count(self: *TokenizerUnion, input: []const u8) !usize {
        return switch (self.*) {
            .o200k => |*t| t.count(input),
            .cl100k => |*t| t.count(input),
            .heuristic => |*t| t.count(input),
        };
    }
};
```

---

## 4. CLI Output Contract

### 4.1 JSON Schema

#### 4.1.1 Pipe Output Record

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "llm-cost pipe output record",
  "type": "object",
  "required": ["tokens_in", "cost_usd", "accuracy"],
  "properties": {
    "tokens_in": {
      "type": "integer",
      "minimum": 0,
      "description": "Input token count"
    },
    "tokens_out": {
      "type": "integer",
      "minimum": 0,
      "description": "Output token count (0 if not estimated)"
    },
    "cost_input_usd": {
      "type": "number",
      "minimum": 0,
      "description": "Cost for input tokens in USD"
    },
    "cost_output_usd": {
      "type": "number",
      "minimum": 0,
      "description": "Cost for output tokens in USD (0 if not estimated)"
    },
    "cost_usd": {
      "type": "number",
      "minimum": 0,
      "description": "Total cost in USD"
    },
    "accuracy": {
      "type": "string",
      "enum": ["exact", "heuristic", "estimate"],
      "description": "Accuracy tier of the token count"
    }
  },
  "additionalProperties": true
}
```

**Note:** `additionalProperties: true` allows pass-through of original JSONL fields.

#### 4.1.2 Summary Output

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "llm-cost summary",
  "type": "object",
  "required": ["version", "lines_total", "tokens_in", "cost_usd"],
  "properties": {
    "version": {
      "type": "string",
      "const": "1",
      "description": "Schema version for forward compatibility"
    },
    "model": {
      "type": "string",
      "description": "Model used for pricing (e.g., openai/gpt-4o)"
    },
    "lines_total": {
      "type": "integer",
      "minimum": 0
    },
    "lines_failed": {
      "type": "integer",
      "minimum": 0
    },
    "tokens_in": {
      "type": "integer",
      "minimum": 0
    },
    "tokens_out": {
      "type": "integer",
      "minimum": 0
    },
    "cost_input_usd": {
      "type": "number",
      "minimum": 0
    },
    "cost_output_usd": {
      "type": "number",
      "minimum": 0
    },
    "cost_usd": {
      "type": "number",
      "minimum": 0
    },
    "accuracy": {
      "type": "string",
      "enum": ["exact", "heuristic", "estimate", "mixed"]
    },
    "quota_hit": {
      "type": "boolean",
      "description": "True if --max-tokens or --max-cost limit was reached"
    }
  }
}
```

### 4.2 Exit Codes

```zig
// src/cli/exit_codes.zig
pub const ExitCode = enum(u8) {
    ok = 0,
    err_generic = 1,
    err_usage = 2,
    // 3-63 reserved for future generic errors
    err_quota = 64,      // BSD EX_USAGE range start
    err_partial = 65,
    // 66-78 reserved for application-specific errors
    
    pub fn toInt(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};
```

| Code | Name | Description | When |
|------|------|-------------|------|
| 0 | `ok` | Success | All lines processed, no quota hit |
| 1 | `err_generic` | Generic error | Unexpected panic, I/O error |
| 2 | `err_usage` | Usage error | Bad CLI arguments, missing required flags |
| 64 | `err_quota` | Quota exceeded | `--max-tokens` or `--max-cost` limit reached |
| 65 | `err_partial` | Partial failure | Some lines failed, stream completed |

### 4.3 Flag Combinations

```
llm-cost pipe [OPTIONS] < input.jsonl

Output control:
  --format <text|json>           Output format (default: text)
  --summary                      Print summary after processing
  --summary-format <text|json>   Summary format (default: text)
  --quiet                        Suppress non-JSON output

Behavior:
  --fail-on-error                Exit on first line error (default: continue)
  --max-tokens <N>               Stop after N total tokens
  --max-cost <USD>               Stop after $USD total cost
```

---

## 5. Pricing Model v2

### 5.1 Data Structures

```zig
// src/pricing/types.zig
pub const PricingInfo = struct {
    /// Cost per 1M input tokens in USD
    input_per_million: f64,
    
    /// Cost per 1M output tokens in USD
    output_per_million: f64,
    
    /// Cost per 1M cached input tokens (null if not supported)
    cached_input_per_million: ?f64,
    
    /// Context window size
    context_window: u32,
    
    /// Pricing effective date (for audit trail)
    effective_date: []const u8,
    
    /// Notes about pricing limitations
    notes: ?[]const u8,
};

pub const CostBreakdown = struct {
    tokens_input: u64,
    tokens_output: u64,
    cost_input_usd: f64,
    cost_output_usd: f64,
    cost_total_usd: f64,
    accuracy: Accuracy,
    
    pub fn calculate(
        tokens_in: u64,
        tokens_out: u64,
        pricing: PricingInfo,
        accuracy: Accuracy,
    ) CostBreakdown {
        const cost_in = @as(f64, @floatFromInt(tokens_in)) * pricing.input_per_million / 1_000_000.0;
        const cost_out = @as(f64, @floatFromInt(tokens_out)) * pricing.output_per_million / 1_000_000.0;
        
        return .{
            .tokens_input = tokens_in,
            .tokens_output = tokens_out,
            .cost_input_usd = cost_in,
            .cost_output_usd = cost_out,
            .cost_total_usd = cost_in + cost_out,
            .accuracy = accuracy,
        };
    }
};
```

### 5.2 Pricing Database Schema

```json
{
  "schema_version": "2",
  "generated": "2025-01-15T00:00:00Z",
  "models": {
    "openai/gpt-4o": {
      "encoding": "o200k_base",
      "input_per_million": 2.50,
      "output_per_million": 10.00,
      "cached_input_per_million": 1.25,
      "context_window": 128000,
      "effective_date": "2024-11-01",
      "notes": "Cached pricing requires API confirmation"
    },
    "openai/gpt-4o-mini": {
      "encoding": "o200k_base",
      "input_per_million": 0.15,
      "output_per_million": 0.60,
      "cached_input_per_million": 0.075,
      "context_window": 128000,
      "effective_date": "2024-07-01"
    },
    "openai/gpt-4-turbo": {
      "encoding": "cl100k_base",
      "input_per_million": 10.00,
      "output_per_million": 30.00,
      "context_window": 128000,
      "effective_date": "2024-04-01"
    }
  }
}
```

### 5.3 Scope Statement (for docs)

```markdown
## What llm-cost CAN tell you

- **Input token count**: Exact for supported encodings (o200k_base, cl100k_base)
- **Input cost**: Based on published rates in pricing database
- **Estimated output tokens**: If you provide `--estimate-output <tokens>`
- **Estimated output cost**: Based on output token estimate

## What llm-cost CANNOT tell you

- **Reasoning tokens**: Determined by model at inference time (o1/o3 series)
- **Cached token hits**: Server-side state, not predictable
- **Tool call costs**: Depends on tool responses
- **Multimodal costs**: Image/audio pricing varies by resolution/duration
- **Actual billed amount**: May differ due to rounding, promotions, etc.

## Recommended workflow

For accurate cost tracking:

1. Use llm-cost for **pre-flight estimates** (prompt budgeting, CI gates)
2. Capture **vendor usage logs** from API responses
3. **Enrich** usage logs with llm-cost token counts for validation
4. Compare estimates vs actuals to calibrate your models
```

---

## 6. Testing Strategy

### 6.1 Test Pyramid

```
                    ┌─────────────┐
                    │   Release   │  Manual: 10GB+ load test
                    │    Gate     │  before version bump
                    ├─────────────┤
                    │   Golden    │  CLI contract tests
                    │   Tests     │  (zig build test-golden)
                ┌───┴─────────────┴───┐
                │    Integration      │  Parity tests, Evil Corpus
                │       Tests         │  (zig build test-parity)
            ┌───┴─────────────────────┴───┐
            │         Unit Tests          │  Function-level
            │                             │  (zig build test)
        ┌───┴─────────────────────────────┴───┐
        │            Fuzz Tests               │  Continuous/nightly
        │                                     │  (zig build fuzz)
        └─────────────────────────────────────┘
```

### 6.2 Golden Test Structure

```
testdata/golden/
├── chat_sample/
│   ├── input.jsonl           # 50 lines mixed content
│   ├── expect.tokens.jsonl   # Expected --mode tokens --format json
│   ├── expect.price.jsonl    # Expected --mode price --format json
│   └── expect.summary.json   # Expected --summary-format json
├── adversarial/
│   ├── input.jsonl           # Edge cases, evil corpus samples
│   ├── expect.tokens.jsonl
│   └── expect.summary.json
├── large/
│   ├── input.jsonl           # 1000+ lines for perf regression
│   └── expect.summary.json
└── errors/
    ├── input.jsonl           # Lines that should fail
    ├── expect.partial.jsonl  # Partial output with errors
    └── expect.summary.json   # lines_failed > 0
```

### 6.3 Golden Test Runner

```zig
// src/test/golden_test.zig
const TestCase = struct {
    name: []const u8,
    input: []const u8,
    args: []const []const u8,
    expected_stdout: []const u8,
    expected_stderr: ?[]const u8,
    expected_exit: ExitCode,
};

fn runGoldenTest(case: TestCase) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"./zig-out/bin/llm-cost"} ++ case.args,
        .stdin_behavior = .Pipe,
    });
    
    // Write input
    try result.stdin.writeAll(case.input);
    result.stdin.close();
    
    // Check exit code
    const exit_code = result.term.Exited;
    try std.testing.expectEqual(case.expected_exit.toInt(), exit_code);
    
    // Compare output (semantic JSON comparison)
    try expectJsonEqual(case.expected_stdout, result.stdout);
}
```

---

## 7. Security Architecture

### 7.1 SLSA Build Level 2 Requirements

| Requirement | Implementation |
|-------------|----------------|
| Scripted build | `build.zig` defines all build steps |
| Version controlled | Git with signed commits (recommended) |
| Build service | GitHub Actions (not local machine) |
| Provenance generated | slsa-github-generator action |
| Provenance non-forgeable | Signed by GitHub OIDC |
| Provenance available | Published alongside release artifacts |

### 7.2 Release Workflow

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-linux
          - os: ubuntu-latest
            target: aarch64-linux
          - os: macos-latest
            target: x86_64-macos
          - os: macos-latest
            target: aarch64-macos
          - os: windows-latest
            target: x86_64-windows
    
    runs-on: ${{ matrix.os }}
    
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
      
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@7ab2955eb728f5440978d7b4398b0a5950020e12 # v2.2.0
        with:
          version: 0.13.0
      
      - name: Build
        run: zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseSafe
      
      - name: Generate checksums
        run: sha256sum zig-out/bin/llm-cost* > checksums-${{ matrix.target }}.txt
      
      - name: Upload artifacts
        uses: actions/upload-artifact@5d5d22a31266ced268874388b861e4b58bb5c2f3 # v4.3.1
        with:
          name: llm-cost-${{ matrix.target }}
          path: |
            zig-out/bin/llm-cost*
            checksums-${{ matrix.target }}.txt

  provenance:
    needs: build
    permissions:
      actions: read
      id-token: write
      contents: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.0.0
    with:
      base64-subjects: "${{ needs.build.outputs.checksums_base64 }}"
      upload-assets: true

  release:
    needs: [build, provenance]
    runs-on: ubuntu-latest
    
    steps:
      - name: Download all artifacts
        uses: actions/download-artifact@c850b930e6ba138125429b7e5c93fc707a7f8427 # v4.1.4
      
      - name: Generate SBOM
        run: |
          syft . -o cyclonedx-json > sbom.cdx.json
      
      - name: Sign with Cosign
        run: |
          cosign sign-blob --yes llm-cost-* > signatures.txt
      
      - name: Create Release
        uses: softprops/action-gh-release@de2c0eb89ae2a093876385947365aca7b0e5f844 # v1
        with:
          files: |
            llm-cost-*
            *.intoto.jsonl
            sbom.cdx.json
            signatures.txt
```

### 7.3 Verification Instructions

```markdown
## Verifying a Release

### 1. Verify SLSA Provenance

```bash
slsa-verifier verify-artifact llm-cost-x86_64-linux \
  --provenance-path llm-cost-x86_64-linux.intoto.jsonl \
  --source-uri github.com/your-org/llm-cost \
  --source-tag v0.5.0
```

### 2. Verify Cosign Signature

```bash
cosign verify-blob \
  --signature llm-cost-x86_64-linux.sig \
  --certificate llm-cost-x86_64-linux.crt \
  llm-cost-x86_64-linux
```

### 3. Verify Checksum

```bash
sha256sum -c checksums-x86_64-linux.txt
```
```

---

## 8. Future Considerations (Out of Scope)

### 8.1 SentencePiece Backend (Fase 2+)

De Backend architectuur ondersteunt dit zonder breaking changes:

```zig
// Future: src/tokenizer/backends/sentencepiece.zig
pub const SentencePieceBackend = struct {
    pub const name = "sentencepiece";
    pub const accuracy = .exact;
    
    model_data: []const u8,
    
    pub fn init(model_path: []const u8) !SentencePieceBackend {
        // Load .model file
    }
    
    pub fn encode(self: *const SentencePieceBackend, input: []const u8, allocator: Allocator) ![]u32 {
        // SentencePiece encoding (different algorithm than BPE)
    }
};
```

### 8.2 Vendor Log Enrichment (Fase 2+)

```bash
# Future workflow
llm-cost enrich \
  --vendor-log openai_usage.jsonl \
  --output enriched.jsonl
```

Dit vereist parsing van vendor-specifieke response formats, niet alleen tokenization.

### 8.3 Library Interface (Fase 2+)

```zig
// Future: lib/llm_cost.zig (exported as static lib)
export fn llm_cost_count(model: [*:0]const u8, text: [*]const u8, len: usize) i64;
export fn llm_cost_estimate(model: [*:0]const u8, text: [*]const u8, len: usize, out: *CostResult) i32;
```

Alleen implementeren als er concrete vraag is.

---

## Appendix A: Decision Log

| Date | Decision | Rationale | Alternatives Considered |
|------|----------|-----------|------------------------|
| 2025-01 | Lineaire BPE in Zig | Zero dependencies, matches design principles | Rust FFI (rejected: adds toolchain), keep O(N log N) (rejected: not competitive) |
| 2025-01 | Comptime generics | Zero-cost, idiomatic Zig | Runtime vtable (rejected: overhead), trait objects (rejected: not Zig) |
| 2025-01 | Embed vocab | Offline-first, single binary | Runtime download (rejected: breaks air-gapped), compile-time include (chosen) |
| 2025-01 | BSD exit codes | Standard, CI-friendly | Custom codes (rejected: confusing), POSIX only (rejected: limited range) |
| 2025-01 | SLSA L2 | Achievable with GitHub Actions | L3 (rejected: needs dedicated infra), L1 (rejected: too basic) |
