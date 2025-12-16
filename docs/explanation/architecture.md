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
- **`count`**: Simple token counting.
- **`estimate`**: Cost estimation.
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
- **`bpe_v2_1.zig`**: Current default engine. Uses Index-based Token Buffer + Min-Heap Merge Queue + Arena Allocator.
- **`bpe_v2.zig`**: Legacy pointer-based implementation (retained for reference).
- **Scanners**: Hand-written regex-equivalent scanners (`o200k_scanner.zig`, `cl100k_scanner.zig`) that match OpenAI's logic exactly.
- **Parity**: Verified against `tiktoken` using the "Evil Corpus" test suite.

### Pricing DB Service (TUF-lite)
The pricing database is now a remote-updateable artifact (`pricing_db.json.zst`) managed via a secure manifest system.

-   **Manifest (`manifest.json`)**: Contains metadata (version, timestamp, schema version) and the SHA256 hash of the compressed database. The manifest itself is signed with Ed25519.
-   **Database (`pricing_db.json.zst`)**: Zstandard-compressed JSON.
-   **Security**:
    -   `update-db` fetches the manifest first.
    -   Verifies the Ed25519 signature against the embedded public key.
    -   Verifies the timestamp (anti-freeze/anti-replay).
    -   Downloads the DB and verifies its SHA256 hash against the manifest.
    -   Performs an atomic install (write-to-temp -> rename).
-   **Offline**: By default, `llm-cost` uses the embedded database if no cached update is found. Estimation never makes network calls.

### Pipe Runner (`src/cli/pipe.zig`)
Handles streaming I/O for `llm-cost pipe`.
- **Processing**: Single-threaded stream processing with 64KB read buffers.
- **Quotas**: Enforces strict budgets (`--max-tokens`, `--max-cost`) deterministically.
- **Summary**: Tracks aggregate usage and failures.
