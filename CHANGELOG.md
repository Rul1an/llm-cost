# Changelog

All notable changes to this project will be documented in this file.

## [v0.1.4] - 2025-12-07
### Fixed
- **Windows Support**: Resolved compilation error (`STDIN_FILENO` missing) by using `std.io` fallback for standard streams on Windows targets.
- **Cross-Compilation**: Verified green builds for Linux (GNU/MUSL), macOS (ARM64), and Windows (x86_64).

## [v0.1.3] - 2025-12-07
### Fixed
- **Runtime I/O**: Replaced `std.fs.File` flag checks with raw POSIX `read`/`write` for stdin/stdout to fix `NotOpenForReading` errors on macOS/Linux.

## [v0.1.2] - 2025-12-07
### Fixed
- **Alignment Safety**: Updated `src/tokenizer/bpe.zig` to use `extern struct` and manual pointer casting for `IndexEntry`, ensuring compatibility with Zig 0.13.0 restrictive type checking.
- **Embed Paths**: Cleaned up relative paths for tokenizer data.

## [v0.1.1] - 2025-12-07
### Fixed
- **Zig 0.13.0 Compliance**:
  - Removed `single_threaded` field from `build.zig` (deprecated in 0.13).
  - Replaced custom I/O logic with `std.io` wrappers.
  - Corrected `read` loop pattern to handle `!usize` return type correctly.
  - Removed unused function parameters in CLI.

## [v0.1.0] - 2025-12-07
### Added
- **Core Engine**: Initial release of `llm-cost` CLI.
- **Tokenizer**: Zero-copy BPE implementation for `o200k_base` (GPT-4o).
- **Pricing**: Embedded pricing database (`default_pricing.json`).
- **Commands**: `tokens` (count), `price` (estimate), `models` (list).
- **Formats**: Support for `text`, `json`, and `ndjson` output.
- **CI/CD**: `release.yml` with `zig-cross-compile-action` integration.
