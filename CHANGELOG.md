# Changelog

## [v1.1.1] - Hardening
### Added
- **Determinism (RFC 8785-inspired)**:
    - Implemented Canonical JSON Writer for stable object key sorting.
    - Prompts in `estimate` and tags in `export` are now strictly sorted by ID/Key.
    - Fixed-point cost precision in JSON outputs.
- **Input Hardening**:
    - Pricing DB parser enforces `MAX_JSON_SIZE` (10MB) and `MAX_MODELS` (1000).
    - Minisign verifier adheres to strict line length limits to prevent parser exploits.
- **Release Integrity**:
    - Binary checksums (`checksums.txt`) included in release assets.
    - SLSA Provenance generation using `actions/attest-build-provenance@v2`.

### Fixed
- **Determinism**: Eliminated non-deterministic JSON field ordering in `diff` and `estimate` commands.

## [v1.0.1] - FOCUS Hardening
### Added
- **Deterministic FOCUS Export**:
    - Fixed-point cost precision (12 decimals) using `pico-USD`.
    - Sorted JSON keys in `Tags` column for stable diffs.
    - System tags emitted in strict order.
- **Vantage Compatibility**:
    - Strict column subset (no unsupported columns).
    - `focus-version` and `focus-target` metadata tags.
    - `resource-name` moved to Tags to adhere to Vantage schema constraints.

### Fixed
- **CI Stability**: Refactored `MockState` to use stable heap-allocated `AnyWriter` contexts, preventing Segfaults in tests.

## [v0.10.1] - Stability Patch
### Fixed
- **Golden Tests**: Resolved Signal 6/segfault by (1) implementing hermetic temp CWD (`TestEnv`, `CwdGuard`) and (2) fixing dangling stdout/stderr writers in test harness (Use-After-Return).
- **Security**: Fixed Minisign verification warning ("Trusted comment verification failed") by correctly handling legacy hashed signatures and "bare" comment signatures.
- **Memory**: Fixed memory leak in test harness initialization.

## [v0.10.0] - FOCUS Foundation
### Added
- **Manifest V2**: Upgraded `llm-cost.toml` schema to support `[[prompts]]` (Array of Tables), `[defaults]`, and `tags`.
- **Identity**: Implemented stable `resource_id` derivation (Manifest ID > Path Slug > Content Hash) for FOCUS compliance.
- **Init Command**: New `llm-cost init` interactive wizard to discover prompts and generate configuration.
- **Estimate JSON**: `llm-cost estimate --format json` now outputs structured data including `resource_id` and `cost_usd`.

### Changed
- **Check Command**: Now operates in "mixed mode" — supports both explicit manifest prompts and CLI inputs with policy validation.
- **Docs**: Added `docs/reference/manifest.md` and updated `cli.md`.

## [v0.9.0] - Secure Updates & Governance
### Added
- **Secure Updates**: `llm-cost update-db` command downloads and verifies pricing database via Minisign (Client-Side).
- **Governance**: `llm-cost check` command enforces budgets and policies in CI/CD pipelines.
- **Manifest**: Support for `llm-cost.toml` to define max budget and allowed models.
- **Caching**: Hybrid initialization loads pricing DB from `~/.cache/llm-cost/` if available and verified.

### Changed
- **Pricing Core**: Exposed verification logic for reuse.
- **Engine**: Improved error handling for missing models in strict mode.

## [v0.8.0] - 2025-12-11
### Security (Hardening)
- **Secure Boot**: Implemented Minisign verification for the Pricing Registry. The CLI now verifies:
    1. **Data Integrity**: `Blake2b512` hash of the DB file matches the signed signature.
    2. **Trust Binding**: The signature is cryptographically signed by the release authority (offline public key).
- **Golden Tests**: Enforced CLI contract stability via `src/golden_test.zig` (JSON Schema, Pipe Logic, Pricing Math).

### Added
- **Report Analytics**: New `report` command (aliased as `tokenizer-report`) providing research-grade metrics:
    - **Compression Ratio** (Bytes/Token).
    - **Fertility** (Tokens/Word).
    - **Cost Estimation** (Total Corpus Cost).
- **Pricing Engine (2025)**: Updated schema to support `_mtok` (per million tokens) fields and `reasoning_tokens` (Gemini 2.5, o1).

### Fixed
- **Zero Cost Bug**: Resolved an issue where pricing defaulted to $0 due to field name mismatch (`per_million` vs `per_mtok`).
- **Engine Exports**: Exposed `resolveConfig` and `countTokens` in `core/engine.zig` for public API usage.


### Added
- **Documentation**: Complete overhaul of documentation structure (Diátaxis framework).
- **CLI Reference**: New `docs/explanation/cli.md` guide.
- **Man Page**: Unix-standard man page at `docs/reference/llm-cost.1`.

### Fixed
- **Benchmarks**: Improved dynamic system detection (macOS/Linux) and real-time timestamping.
- **Build**: Resolved Zig 0.15.0 compatibility issues (reverted to 0.14.0 stable API).

## [v0.7.0] - 2025-12-10
### Added
- **Fairness Analyzer**: New `analyze-fairness` command to evaluate tokenization parity metrics (Fertility, Gini, etc.).
- **Golden Tests**: Full parity verification suite against `tiktoken` (140+ test cases).
- **Core**: Integrated C++ style analytics module (`src/analytics/`) for performance.

### Fixed
- **CI**: Fixed `release.yml` smoke test (replaced invalid `tokens` command with `count`).
- **Memory**: Resolved leaks in corpus parsing and test runners.

## [v0.6.2] - 2025-12-10
### Fixed
- **CI**: Fixed `release.yml` workflow failure by using correct SHA-pinned references for `actions/upload-artifact` (v4) and `actions/download-artifact` (v4).
- **Security**: Enforced SHA-pinning for all GitHub Actions in release workflow to comply with security policy.

All notable changes to this project will be documented in this file.

## [0.6.1] - 2025-12-10

### Fixed
- **CI**: Corrected invalid `bench-bpe` step name in `release.yml` workflow (renamed to `bench`).
- **Process**: Enforced `zig fmt` checks in CI (`build.zig` + `src/`) and added `pre-push` git hooks.

## [0.6.0] - 2025-12-10

### Added
- **Analytics Features (`tokenizer-report`)**: New CLI command to profile corpora. Reports compression ratio, vocab utilization, and rare tokens.
- **Benchmarking Suite (`bench`)**: Unified performance runner proving BPE v2.1 linear scaling ($O(N)$) and regression testing.
- **Pipe Mode (v2)**: Restored streaming functionality with robust guardrails (`--max-tokens`, `--max-cost`) and Zero-Leak architecture.
- **BPE v2.1 Engine**: Validated linear-time tokenization logic, eliminating $O(N^2)$ worst-case behavior.
- **Pricing v2**: Cost output now splits input/output/reasoning costs explicitly.

### Changed
- **CLI**: Standardized exit codes (BSD sysexits).
- **JSON Output**: `count` and `tokenizer-report` support structured JSON output via `--format json`.
- **Performance**: Optimized memory usage to O(1) per line in streaming modes.

### Fixed
- Fixed compilation errors with Zig 0.14.0 stable.
- Resolved quadratic complexity in BPE merge logic.

## [0.5.0] - 2025-12-0710

### Features
- **Zero Dependency**: Embedded `cl100k_base` and `o200k_base` vocabularies in binary. Removed `tiktoken` file dependency.
- **BPE v2.1**: Index+Heap based BPE algorithm (O(N log N)).
- **Parity**: Verified 100% bit-for-bit match with `tiktoken` on `evil_corpus_v2` (including whitespace lookahead).
- **Pricing**: Updated database for `gpt-4o`, `o1`, `o3-mini`.

### Changed
- **CLI**: Renamed `tokens` -> `count` and `price` -> `estimate`.
- **Build**: Requires Zig 0.14.0.

### Removed
- **Pipe Mode**: Disabled pending refactor.
- **Python**: No runtime dependency.

## [v0.1.0] - Information pre-v0.5.0
Legacy releases.
