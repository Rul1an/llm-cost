# Changelog

All notable changes to this project will be documented in this file.

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
