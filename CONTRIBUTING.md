# Contributing to llm-cost

Thank you for your interest in contributing! We value clean, performant, and reliable code.

## Prerequisites

- **Zig 0.14.0** (strictly pinned).
- Python 3 + `tiktoken` (optional, only for *re-generating* the golden corpus).

## Setup
1. Run `./scripts/setup_hooks.sh` to install git hooks (enforces formatting).

## Workflow

**Rule #1: Never push to `main`. Always use a Feature Branch & PR.**

1.  **Branch**: `git checkout -b feat/your-feature` or `fix/your-bug`.
2.  **Develop**: Write clean, panic-free code.
3.  **Format**: `zig fmt build.zig src/` (Automated by pre-push hook).
4.  **Verify**:
    ```bash
    zig build test        # Unit tests
    zig build fuzz        # Fuzzing sanity check
    zig build test-golden # Parity check
    zig build test-parity # Tokenizer compliance
    ```
5.  **Commit**: Use conventional commits (e.g. `feat: ...`, `fix: ...`).
6.  **PR**: Push to origin and open a Pull Request.

## Code Style

- **No Panics**: Library code (`src/core`, `src/tokenizer`) should never panic. Use Zig's error sets.
- **Explicit Memory**: Pass allocators explicitly.
- **Minimal Dependencies**: We avoid external Zig dependencies.
- **Strict Formatting**: CI will fail if `zig fmt` has not been run.

## Adding a New Model

1.  Update `src/tokenizer/model_registry.zig` to include the new model/alias.
2.  Update `src/pricing.zig` with the latest pricing info.
3.  If the model uses a **new tokenizer** family:
    -   Add the vocab file to `src/data/`.
    -   Implement the scanner in `src/tokenizer/`.
    -   Register the encoding in `src/tokenizer/registry.zig`.
