# Changelog

All notable changes to this project will be documented in this file.

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
