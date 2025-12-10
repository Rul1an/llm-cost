Feature: Fairness Analyzer & Verification

## Added
- **Fairness Analyzer**: New `analyze-fairness` command to evaluate tokenization parity across languages.
- **Golden Tests**: Comprehensive test suite enforcing strict parity with OpenAI's `tiktoken`.
- **Golden Corpus**: `test/golden/corpus_v2.jsonl` covering Basic, Unicode, Code, and Edge cases.

## Fixed
- **CI**: Fixed `release.yml` smoke test failing on unknown `tokens` command (replaced with `count`).
- **Memory Safety**: Fixed leaks in `corpus.zig` and test runners.
