# Contributing to llm-cost

Thank you for your interest in contributing! We value clean, performant, and reliable code.

## Prerequisites

- **Zig 0.14.0** (strictly pinned).
- Python 3 + `tiktoken` (optional, only for *re-generating* the golden corpus).

## Workflow

1.  **Fork & Branch**: Create a feature branch.
2.  **Develop**: Make your changes.
3.  **Verify**: Run the verification suite locally.
    ```bash
    zig build test        # Unit tests
    zig build fuzz        # Fuzzing sanity check
    zig build test-golden # Parity check (runs against committed jsonl)
    ```
4.  **PR**: Submit a Pull Request targeting `main`.

## Code Style

- **No Panics**: Library code (`src/core`, `src/tokenizer`) should never panic. Use Zig's error sets to bubble up failures.
- **Explicit Memory**: Pass allocators explicitly.
- **Minimal Dependencies**: We avoid external Zig dependencies where possible.
- **Formatting**: Run `zig fmt` before committing.

## Adding a New Model

1.  Update `src/tokenizer/model_registry.zig` to include the new model/alias.
2.  Update `src/pricing.zig` with the latest pricing info.
3.  If the model uses a **new tokenizer** family:
    -   Add the vocab file to `src/data/`.
    -   Implement the scanner in `src/tokenizer/`.
    -   Register the encoding in `src/tokenizer/registry.zig`.
