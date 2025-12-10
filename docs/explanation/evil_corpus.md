# Evil Corpus v2

**Purpose**: Differential testing (parity) between `llm-cost` and the official `tiktoken` library.

## Generator (`tools/gen_evil_corpus.py`)
This Python script generates `testdata/evil_corpus_v2.jsonl`.
It requires `tiktoken` to be installed.

**Usage**:
```bash
pip install tiktoken
python3 tools/gen_evil_corpus.py
```

**Output Format**:
JSONL file where each line is:
```json
{
  "model": "o200k_base",
  "text": "...",
  "expected_ids": [123, 456, ...],
  "tiktoken_version": "0.8.0"
}
```

**Reference Version**:
The current corpus was generated using `tiktoken` **0.8.0** (or similar, check file).
If you regenerate the corpus, you **MUST** update the `tiktoken_version` field to match.

## Parity Harness (`src/test/parity.zig`)
A Zig test that:
1. Reads `testdata/evil_corpus_v2.jsonl`.
2. Encodes the text using `llm-cost`'s `OpenAITokenizer`.
3. Asserts exact match with `expected_ids`.
4. Skips models if their vocab/merges data is missing.

## Requirements
*   **Special Tokens**: The Evil Corpus **MUST NOT** contain special tokens (e.g. `<|endoftext|>`). Special behavior is tested separately.
*   **Parity is Strict**: For valid UTF-8 input, our output ids MUST match `tiktoken` exactly.
*   **Invalid UTF-8**: The Evil Corpus generator **MUST** only emit valid UTF-8 sequences. Invalid UTF-8 handling is covered by fuzzing (see `docs/v0.3-spec.md`).
*   **Frozen Corpus**: Only regenerate the corpus as part of a dedicated PR that:
    1. Documents the change in behavior or version.
    2. Updates both this doc and the `tiktoken_version` field in the JSONL.
