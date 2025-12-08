# Title
Release v0.4.0: Registry V2, accuracy tiers, pipe summary & quota

# Description

## Summary

This PR merges the `dev` branch into `main` and prepares the project for the v0.4.0 release.

v0.4 focuses on three things:

- A more explicit, multi-provider-ready **model registry**.
- Clear **accuracy tiers** in all relevant outputs.
- Agent-/batch-friendly **pipe UX** (summary + hard quotas).

All changes are backwards compatible for existing v0.3 workflows, with stricter and more explicit behaviour around accuracy and quotas.

---

## Changes

### 1. Registry V2 (Model resolution & accuracy tiers)

- Introduced a `ModelRegistry` layer that resolves model names (e.g. `gpt-4o`, `openai/gpt-4o`) to a canonical `ModelSpec`.
- Each `ModelSpec` carries:
  - `canonical_name` (used for pricing + display).
  - `encoding` (exact tokenizer spec or `null` for generic/whitespace).
  - `accuracy` (`exact` vs `heuristic` for now).
- OpenAI models (`gpt-4o`, `gpt-4`) resolve to:
  - `o200k_base` / `cl100k_base` with `accuracy = exact`.
- Unknown or generic models resolve to a whitespace-based estimator with `accuracy = heuristic`.

**Impact**

- CLI now consistently uses canonical model names for pricing and output.
- There are no silent downgrades: if we don’t have an exact tokenizer, the output is clearly marked as `heuristic`.

---

### 2. Accuracy tiers in CLI output

- `ResultRecord` now includes an `accuracy` field (stringified enum from the registry).
- JSON/NDJSON output includes:

  ```json
  {
    "model": "openai/gpt-4o",
    "tokens_input": 123,
    "tokens_output": 0,
    "cost_usd": 0.0006,
    "tokenizer": "o200k_base",
    "accuracy": "exact",
    "approximate": false
  }
  ```

  `approximate` is now derived from: `accuracy != exact` or missing pricing information.

**Impact**

- Downstream tools can distinguish:
  - exact OpenAI parity vs.
  - heuristic estimates for unknown models.

---

### 3. Pipe: summary & quotas (agent/batch workflows)

#### 3.1 Summary

New flag: `--summary` for `llm-cost pipe`.

- Prints aggregate stats to stderr after processing:
  ```
  summary: lines=123 (failed=4) tokens=45678 (in=42000 out=3678) cost=$0.123456
  ```

- In quota breach scenarios, a partial summary is printed:
  ```
  summary (partial, quota exceeded): lines=10 (failed=1) tokens=1234 (in=1200 out=34) cost=$0.012345
  ```

#### 3.2 Quotas

New CLI flags:
- `--max-tokens <N>`: hard cap on total tokens (in + out).
- `--max-cost <USD>`: hard cap on total cost (USD).

When a quota is hit:
- In single-threaded mode:
  - Processing stops as soon as the limit is reached.
  - Returns a `PipeError.QuotaExceeded` which is translated in CLI to a user-facing error message, e.g.:
    ```
    error: token quota exceeded (max_tokens=100000).
    ```

**Note**: When a quota is set, `pipe` automatically runs in single-thread mode to ensure deterministic containment.

#### 3.3 Error semantics in parallel mode

`--fail-on-error`:
- **Single-threaded**: hard abort on the first per-line failure.
- **Parallel**: best-effort — failed lines are counted, but workers continue processing the remaining queue.

`PipeSummary` now tracks:
- `lines_processed`
- `lines_failed`
- `total_tokens_in`
- `total_tokens_out`
- `total_tokens` (in + out)
- `total_cost_usd`
- `quota_hit` (internal flag used when emitting partial summaries)

**Impact**

- Safer integration in agent loops and batch ETL:
  - Ability to enforce a strict budget.
  - Clear visibility of how much was processed before we stopped.

---

### 4. CLI polish

`llm-cost help` updated to show:
- Full pipe options (mode, workers, quotas, summary, fail-on-error).
- Example usage for tokens/price/pipe.

`tokens`:
- Uses canonical model name and registry accuracy.
- Tries pricing automatically when a known model is specified.

`price`:
- Uses canonical model name for cost lookup and output.
- Reuses tokenizer config when input text is provided (no change in behaviour, just cleaner wiring).

---

### 5. Testing & QA

Local verification (`Zig 0.13.0`):

- `zig build test`
  - Core unit tests (tokenizer, scanners, pipe behaviour).
- `zig build fuzz`
  - Chaos fuzzing for:
    - OpenAI tokenizers (`gpt-4o` / `gpt-4`) with random byte sequences.
    - `ModelRegistry.resolve` fuzzed with random strings.
  - Invariants:
    - No panics/UB.
    - Deterministic outputs for identical inputs.
    - `accuracy == exact` implies `encoding != null`.
- `zig build test-parity`
  - 100% parity on `testdata/evil_corpus_v2.jsonl` for `o200k_base` and `cl100k_base`.
- `zig build bench-bpe`
  - Confirmed that v0.4 registry/CLI changes did not regress BPE performance:
    - `a * 4096` still ≈1.1ms on local dev machine.
    - Emoji runs scale lineair/log-lineair.

Manual smoke tests:
- `llm-cost help`: Verified that new flags and examples show correctly.
- `echo '{"text":"hello"}' | llm-cost pipe --summary`:
  - Verified: token injection, accuracy field, summary format with lines, failed, tokens in/out, cost.

---

## Notes for reviewers

Behavioural changes are deliberately conservative:
- No breaking changes for existing v0.3 scripts that only use `tokens`/`price`.
- `pipe` becomes strictly more informative (extra fields) and safer when quotas are used.

Quota semantics:
- Deterministic guarantees only in single-thread mode (enforced automatically whenever a quota is set).
- Parallel mode is still available when no quotas are used, for high-throughput batch processing.

Accuracy tiers:
- Currently "exact" for known OpenAI models; "heuristic" for everything else.
- Designed to be extended in future versions (e.g. "family" tiers for Llama/Mistral).

---

## Follow-ups after merge

Tag the release:
```bash
git checkout main
git pull origin main
git tag -a v0.4.0 -m "Release v0.4.0"
git push origin v0.4.0
```

Let the GitHub Actions Release workflow:
- run verification,
- build the matrix,
- sign artifacts and attach them to the v0.4.0 release.
