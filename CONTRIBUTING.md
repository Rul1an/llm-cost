# Contributing to llm-cost

## Development

Prerequisites:
- Zig 0.15.x (master/nightly)

### Build
```bash
zig build
```

### Test
```bash
zig build test
```

### Cross-Compilation
This project uses [zig-cross-compile-action](https://github.com/Rul1an/zig-cross-compile-action) for CI releases.
Local testing of cross-compilation can be done via `zig build -Dtarget=...`.

## Directory Structure
- `src/cli/`: CLI entry points and formatting.
- `src/core/`: Core business logic (cost calc).
- `src/tokenizer/`: Tokenizer implementations.
- `src/pricing.zig`: Pricing database loader.
- `src/data/`: Embedded assets.
