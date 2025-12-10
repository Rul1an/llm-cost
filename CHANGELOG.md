# Changelog

All notable changes to this project will be documented in this file.

## [v0.5.0] - 2025-12-10

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
