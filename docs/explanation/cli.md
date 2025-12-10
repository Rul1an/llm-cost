# CLI Reference (v0.7.0)

`llm-cost` is a high-performance, offline command-line utility for token counting and cost estimation. It follows the **Unix Philosophy**: it reads text streams, processes them efficiently, and outputs structured data, making it ideal for composition in CI/CD pipelines and shell scripts.

## Core Philosophy
1.  **Offline First**: No API calls required. Pricing and tokenizers are embedded.
2.  **Zero Dependency**: Single static binary.
3.  **Pipeline Ready**: Reads `stdin`, writes `stdout` (JSON/Text).
4.  **Exact Parity**: Matches OpenAI's `tiktoken` logic exactly.

## Global Options
*   `-h, --help`: Show usage information.
*   `-v, --version`: Show version information.

---

## Commands

### 1. `count`
Calculates the number of tokens in a text string or file.

**Usage:**
```bash
llm-cost count --model <model> [source] [--format <fmt>]
```

**Arguments:**
*   `--model, -m`: (Required) Model identifier (e.g., `gpt-4o`, `gpt-4`).
*   `--text, -t`: Input text string.
*   `--file, -f`: Input file path.
*   `--format`: Output format (`text` [default], `json`).

**Examples:**
```bash
# Count string
llm-cost count -m gpt-4o -t "Hello world"

# Count file
llm-cost count -m gpt-4o -f document.txt

# JSON output (useful for scripts)
llm-cost count -m gpt-4o -t "Hello" --format json
# Output: {"model":"gpt-4o","tokens":1,"bytes":5,"approximate":false}
```

### 2. `estimate`
Calculates the cost of a hypothetical or real API call based on token counts.

**Usage:**
```bash
llm-cost estimate --model <model> [counts]
```

**Arguments:**
*   `--model, -m`: (Required) Model identifier.
*   `--input-tokens`: Number of prompt/input tokens.
*   `--output-tokens`: Number of completion/output tokens.
*   `--reasoning-tokens`: (Optional) Number of reasoning tokens (for o1/o3 models).

**Examples:**
```bash
# Estimate cost for a large job
llm-cost estimate -m gpt-4o --input-tokens 1000000 --output-tokens 50000

# High-reasoning workload
llm-cost estimate -m o1 --input-tokens 500 --output-tokens 2000 --reasoning-tokens 5000
```

### 3. `pipe`
Stream processing mode. Reads a stream of JSON objects (NDJSON) or raw text from `stdin`, adds token counts/cost estimates, and writes to `stdout`.

**Usage:**
```bash
cat inputs.jsonl | llm-cost pipe --model <model> [options]
```

**Arguments:**
*   `--model, -m`: (Required) Model to base calculations on.
*   `--field`: JSON field to tokenize (default: `content`).
*   `--raw`: Treat input as raw text lines instead of JSON.
*   `--max-tokens`: Enforce specific token limit (exit/error if exceeded).
*   `--max-cost`: Enforce specific cost limit ($).
*   `--summary`: Print aggregate statistics at the end.
*   `--fail-fast`: Exit immediately on first error.

**Examples:**
```bash
# Enrich a log stream with token counts
tail -f access.log | llm-cost pipe -m gpt-4o --raw

# Cost guardrail in CI
cat dataset.jsonl | llm-cost pipe -m gpt-4o --max-cost 5.00
```

### 4. `analyze-fairness` (Beta)
Analyzes a text corpus to determine the "Token Tax" (inefficiency) for different languages compared to English.

**Usage:**
```bash
llm-cost analyze-fairness --corpus <path> --model <model>
```

**Arguments:**
*   `--corpus, -c`: Path to `corpus.json` file.
*   `--model, -m`: Model/Tokenizer to analyze.
*   `--format`: Output format (`text`, `json`).

**Metrics:**
*   **Fertility**: Tokens per word.
*   **Parity Ratio**: Fertility relative to English.
*   **Gini Coefficient**: Measure of inequality across languages in the corpus.

### 5. `tokenizer-report`
Generates a detailed statistical report on how a specific text is tokenized, identifying the most frequent tokens and compression efficiency.

**Usage:**
```bash
llm-cost tokenizer-report --model <model> --file <path>
```

**Arguments:**
*   `--model, -m`: (Required) Model identifier.
*   `--file, -f`: Input file path (or use `--stdin`).
*   `--top-k`: Number of top tokens to show (default: 10).

### 6. `models`
Lists all supported models and their current pricing rates (embedded in the binary).

**Usage:**
```bash
llm-cost models
```

## Exit Codes
`llm-cost` uses BSD-style exit codes for reliable scripting:
*   `0`: Success.
*   `1`: General error (missing arguments, calculation error).
*   `2`: Usage error (invalid flags).
*   `3`: I/O error (file not found).
*   `64`: Quota exceeded (used with `pipe --max-cost`).
