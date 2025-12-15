# Changelog

## [v1.3.0] - 2025-12-15
### Added
- **FinOps Reporting**: Automated "Cost Integrity Cards" (GitHub Job Summaries) and `audit.json` artifacts.
- **Validation Suites**: P0 (PR Gate) and P1 (Nightly/Scale) suites enforcing schema, PII safety, and determinism.
- **Metrics**: `global_drift_bps` (Global Basis Points Drift) added to `factors.toml` metadata.
- **Artifacts**: Release builds now include `perf_metrics.txt` and `audit.json` as immutable assets.
- **Compliance**: Standardized validation on FOCUS v1.0.

### Changed
- **Guardrails**: `finops_p0` is now a required status check for `main` branch merges.
- **Tooling**: `render_report.py` supports fail-fast thresholds (`FINOPS_FAIL_FAST`).

## [v1.2.2] - 2025-12-14
### Changed
- **CLI**: `calibrate` now returns stable exit codes (0=Success, 2=Schema/Data Error, 3=Insufficient/Zero Match).
- **Docs**: Updated `README.md` and examples to use best practices and include `calibrate` command.
- **CI**: Hardened `examples/` workflows (SHA-pinning, installer script).

### Fixed
- **Tests**: Fixed `golden_test.zig` to correctly assert on exit codes.

## [v1.2.1] - 2025-12-14
### Added
- **Metadata & Audit Trail**: `factors.toml` now includes `[metadata]` with input hashes (SHA256), tool version, matching mode, and stats.
- **Fail-Fast Validation**:
    - Fatal error on duplicate Estimate IDs or Fuzzy Match Collisions.
    - Fatal error if CSV is missing required FOCUS columns (`ResourceId`, `BilledCost`, `ChargePeriodStart`).
- **UX**: Added `--actuals` alias for `--csv` flag.
- **CLI**: `calibrate` validation now warns specifically about missing columns.

## [v1.2.0] - 2025-12-14

### Added
- **Command**: `llm-cost calibrate` for comparing estimates against actual billing data (Drift Analysis).
- **Import**: FOCUS v1.0 CSV import support with Tags-based extensions (`x-cache-hit-ratio`, `x-call-count`).
- **Output**: Cost multiplier output as TOML factors file (`factors.toml`).
- **Matching**: Fuzzy ResourceId matching to handle FinOps tool ID transformations (prefix stripping).
- **Stats**: Wilson Score confidence intervals for statistical significance.
- **Export**: `llm-cost export --format=json` for generating compatibility estimates.

### Changed
- **CLI**: `llm-cost export` now defaults to CSV but supports JSON map output for calibration integration.
- **Performance**: Optimized streaming join for low memory footprint on large datasets.

### Technical
- **Determinism**: Drift calculation uses integer basis points (bps) to eliminate floating-point non-determinism.
- **Unicode**: Robust `\uXXXX` surrogate pair support in JSON Tags for accurate parsing.
- **Safety**: `max_groups` guardrail (100k default) prevents cardinality explosions.

## [v1.1.12] - 2025-12-14
### Fixed
- **CI**: Restrict release workflow to trigger only on full semantic version tags (`v*.*.*`). This prevents build failures on major version alias tags (e.g., `v1`) which result in a version string ("1") that Zig cannot parse.

## [v1.1.11] - 2025-12-14
### Fixed
- **CI**: Fixed `zig build` panic caused by improper shell variable expansion of the version string in `release.yml`. Now pre-calculating `APP_VERSION` in the workflow env to pass a clean semantic version to the build action.

## [v1.1.10] - 2025-12-14
### Fixed
- **Tests**: Corrected `golden_test.zig` assertions to match actual JSON output format (cost as string) and CSV precision (6 decimals), fixing false negative CI failures.

## [v1.1.9] - 2025-12-14
### Fixed
- **Build**: Resolved compilation error in `src/golden_test.zig` where `i128` cost values were incorrectly compared against `f64` expectations, breaking `zig build test-golden` (and thus CI).

## [v1.1.8] - 2025-12-14
### Fixed
- **CI Stability**: Restricted `Golden`, `Fuzz`, `Parity`, and `Bench` tests to run only on Linux CI runners (matching `ci.yml`), as they require specific environment consistency not present on Windows/MacOS runners. Unit tests and binary smoke tests remain cross-platform.

## [v1.1.7] - 2025-12-14
### Fixed
- **CI Reliability**: Updated release workflow to use `zig-cross-compile-action@v3` for improved cross-platform support.
- **Determinism**: Enforced `LF` line endings via `.gitattributes` to prevent test failures on Windows (CRLF mismatches).

## [v1.1.6] - 2025-12-14
### Fixed
- **Windows Support**: Hardened `git` execution by correctly propagating `Path` and `SystemRoot` environment variables, resolving CI test failures on Windows.

## [v1.1.5] - 2025-12-14
### Fixed
- **Build**: Resolved `unused import` error in `src/determinism_test.zig` causing CI failure.

## [v1.1.4] - 2025-12-14

### Changed
- **Internal Cost Representation**: Refactored `f64` floats to `i128` MicroUSD (1e-6) for deterministic integer arithmetic.
- **FOCUS Export**: Rows stable-sorted by `(ChargePeriodStart, ResourceId, ServiceName)`.
- **JSON Output**: Costs emitted as fixed-precision strings (e.g., "0.000005") instead of floats.

### Added
- **Verification**: `llm-cost verify <artifact>` command for SHA256 integrity and provenance checks.
- **Supply Chain**: CycloneDX SBOM and SLSA-aligned build provenance included in releases.

### Security
- **Pinning**: GitHub Actions pinned to immutable commit SHAs.
- **Reproducible Builds**: Timestamps normalized via `SOURCE_DATE_EPOCH`.

### Fixed
- **Safety**: Resolved double-free segfault in `estimate` and `models` commands.
- **Formatting**: Fixed negative cost formatting bug (e.g. refunds).

## [v1.1.3] - 2025-12-??
### Added
- (Content from previous check...)

## [v1.1.2] ...
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

## [v1.0.1] - FOCUS Hardening (Backport base)
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
