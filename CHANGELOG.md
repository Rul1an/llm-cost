# Changelog

All notable changes to this project will be documented in this file.

## [v0.4.1] - 2025-12-10

### Hardening & Compatibility
- **Zig 0.14.0**: Downgraded codebase to Zig 0.14.0 (stable) to ensure stability and avoid 0.15.x dev churn.
- **BPE v2.1**: Integrated optimized BPE v2.1 logic.
- **Memory Safety**: Fixed initialization memory leaks in `BpeEngineV2` and `TokenBuffer`.
- **Restoration**: Restored missing `unicode_tables.zig` and `golden_test.zig` (fixed runtime compatibility).
- **Verification**: Full test suite (`test`, `test-golden`, `fuzz`) verified green on native Zig 0.14.0.

## [v0.4.0] - 2025-12-09

### Added
- **Registry V2**: Namespaced models (e.g., `openai/gpt-4o`) and aliases (`gpt-4o`).
- **Accuracy Tiers**: JSON output now includes `"accuracy": "exact" | "heuristic"`.
- **Pipe Summary**: New CLI flag `--summary` prints aggregate stats (lines, tokens in/out, cost) to stderr.
- **Pipe Quota**: New CLI flags `--max-tokens N` and `--max-cost N` enforce limits and stop processing when exceeded.
- **Rich Stats**: Pipe output now tracks input and output tokens separately in summary.
- **Custom Vocab**: Documentation for converting and using custom Tiktoken files.
- **Security**: Added `SECURITY.md` policy, pinned GitHub Actions by SHA, and standardized release integrity (SBOM/Signing).
- **Golden Tests**: New `zig build test-golden` target verifies CLI contract integrity (stdout/stderr/exit codes).

### Changed
- **CLI**: Pricing commands now use canonical model names for consistency. `tokens` command enforces strict model existence check (exit code 65).
- **Pipe**: Forced single-threaded execution when quota limits are active to ensure deterministic containment.
- **Behavior**: In parallel pipe mode, `--fail-on-error` marks lines as failed but does not abort the stream (best-effort); hard abort is guaranteed only in single-thread mode.
- **Perf**: Refactored scanner logic to support `AccuracyTier` without performance regression.

## [v0.3.0] - 2025-12-08

### Highlights

- **Strict tokenizer parity with tiktoken**
  - Full support for both `o200k_base` (GPT-4o) and `cl100k_base` (GPT-4 / 3.5 Turbo).
  - Differentially tested against OpenAI’s `tiktoken` using a frozen **Evil Corpus v2** (`testdata/evil_corpus_v2.jsonl`).
  - Special-token handling and `disallowed_special` behavior aligned with `tiktoken`.

- **Robust pre-tokenizers (o200k + cl100k)**
  - Hand-written scanners for `o200k_base` and `cl100k_base` that implement the official regex behavior (including tricky whitespace, contractions, and number splitting).
  - Safe UTF-8 handling with `SafeUtf8Iterator` to avoid crashes on invalid byte sequences.

- **BPE performance: fixed worst-case scaling**
  - Replaced naive O(N²) merge loop with a **heap-based O(N log N)** algorithm for long tokens.
  - Worst-case examples like `"a" * 4096` and long emoji runs now scale lineair/log-lineair (≈250× speedup in microbenchmarks).
  - End-to-end pipeline throughput on stress inputs restored to tens of MB/s.

- **Parity & fuzzing harnesses**
  - New parity test target: `zig build test-parity` compares encoded IDs against the frozen Evil Corpus for all supported encodings.
  - Lightweight fuzzing target: `zig build fuzz` exercises `OpenAITokenizer` with chaotic/invalid inputs to guard against panics and UB.

- **Release & CI hardening**
  - GitHub Actions **Release** workflow:
    - `verify` job runs unit tests, fuzzing, parity checks, and BPE microbenchmarks on Zig 0.13.0.
    - Matrix build produces signed binaries for Linux (GNU/MUSL/ARM), macOS (ARM64), and Windows.
    - Generates CycloneDX SBOMs using Syft and signs artifacts with Cosign (keyless/OIDC).
  - Release artifacts (binary + `.sig` + `.crt` + `.cdx.json`) are attached automatically to GitHub Releases.

### Toolchain

- **Required**: Zig **0.13.x** (pinned in `build.zig` and CI).
- New make-like targets:
  - `zig build test`
  - `zig build fuzz`
  - `zig build test-parity`
  - `zig build bench-bpe`


## [v0.1.4] - 2025-12-07
**Stabilization Release (Windows/POSIX/Alignment)**
This version consolidates several iteration fixes (v0.1.1 — v0.1.3) released on the same day to address cross-compilation targets.

### Fixed
- **Windows Support**: Resolved `STDIN_FILENO` compilation error via `std.io` fallback.
- **Runtime I/O**: Switched to `std.posix` read/write on *nix to bypass Zig 0.13 strict `File` checks (fixes `NotOpenForReading` on pipes).
- **Alignment Safety**: Updated BPE binary loader to use `extern struct` + manual casting for strict ARM alignment compliance.
- **Zig 0.13.0 Compliance**: Removed deprecated build options and cleaned up `std.io` usage.

## [v0.1.0] - 2025-12-07
### Added
- **Core Engine**: Initial release of `llm-cost` CLI.
- **Tokenizer**: Zero-copy BPE implementation for `o200k_base` (GPT-4o).
- **Pricing**: Embedded pricing database (`default_pricing.json`).
- **Commands**: `tokens` (count), `price` (estimate), `models` (list).
- **Formats**: Support for `text`, `json`, and `ndjson` output.
- **CI/CD**: `release.yml` with `zig-cross-compile-action` integration.
