# Architecture Overview

`llm-cost` is a single binary that transforms text (or JSONL streams) into token counts and cost estimates. It is designed for high-performance offline usage in CI pipelines and local scripts.

## High-Level Data Flow

```ascii
+----------------------+
|        User          |
| (shell / CI / agent) |
+----------+-----------+
           |
           v
+----------------------+
|         CLI          |
|  commands.zig        |
|  - tokens            |
|  - price             |
|  - pipe              |
+----------+-----------+
           |
           v
+----------------------+         +----------------------+
|    ModelRegistry     |         |     Pricing DB       |
|  tokenizer/mod.zig   |<------->|   pricing.zig        |
|  - resolve(--model)  |         |  (JSON snapshot)     |
|  - canonical name    |         +----------------------+
|  - encoding spec     |
|  - accuracy tier     |
+----------+-----------+
           |
           v
+----------------------+
|        Engine        |
|   core/engine.zig    |
|  - estimateTokens    |
|  - estimateCost      |
+-----+----------+-----+
      |          |
      |          |
      v          v
+-----------+  +------------------+
| Tokenizer |  |   Pricing Logic  |
|  (BPE)    |  |  (USD per token) |
|  - o200k  |  |  - input/output  |
|  - cl100k |  |  - reasoning     |
+-----------+  +------------------+
           |
           v
+----------------------+
|       Output         |
| - text / json        |
| - ndjson (pipe)      |
+----------------------+
```

## Component Breakdown

### CLI (`src/cli/`)
Parses arguments and dispatches to subcommands.
- **`tokens`**: Simple token counting.
- **`price`**: Cost estimation.
- **`pipe`**: Batch processing of JSONL streams.

### ModelRegistry (`src/tokenizer/model_registry.zig`)
Resolves user input (e.g., `gpt-4o`, `openai/gpt-4o`) into a canonical `ModelSpec`.
- **Accuracy Tier**: Determines if we have an `exact` tokenizer match (e.g., `o200k_base`) or are falling back to a `heuristic` estimate.
- **Normalization**: Maps aliases to official names for consistent pricing lookups.

### Engine (`src/core/engine.zig`)
The orchestration layer.
- **`estimateTokens`**: Delegates to the specific tokenizer logic.
- **`estimateCost`**: Combines token counts with the pricing database.

### Tokenizer (`src/tokenizer/`)
Implements the BPE logic.
- **`bpe.zig`**: A heap-based BPE merge engine (O(N log N)) suitable for worst-case inputs.
- **Scanners**: Hand-written regex-equivalent scanners (`o200k_scanner.zig`, `cl100k_scanner.zig`) that match OpenAI's logic exactly.
- **Parity**: Verified against `tiktoken` using the "Evil Corpus" test suite.

### Pricing DB (`src/pricing.zig`)
Contains an embedded snapshot of model pricing.
- No network calls are made.
- Versions follow the tool's release cycle.

### Pipe Runner (`src/cli/pipe.zig`)
Handles streaming I/O for `llm-cost pipe`.
- **Concurrency**: Supports parallel processing (`--workers N`) for pure data enrichment.
- **Quotas**: Enforces strict budgets (`--max-tokens`, `--max-cost`) by switching to single-threaded mode for deterministic containment.
- **Summary**: Tracks aggregate usage and failures.
