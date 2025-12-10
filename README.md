# llm-cost

echo 'Hello' | llm-cost count --model gpt-4o
```

### 3. Cost Estimation

Estimate cost using embedded pricing DB:

```bash
llm-cost estimate \
  --model gpt-4o \
  --input-tokens 1000 \
  --output-tokens 500
```

## Parity & Verification

Tokenization is guaranteed to be identical to `tiktoken` for supported encodings.

**Guarantees:**
- **Vocab**: Vocabulary and merge tables are exported from `tiktoken` and embedded as binary blobs.
- **Golden Data**: `scripts/generate_golden.py` builds `evil_corpus_v2.jsonl` with 30 edge cases (whitespace, unicode).
- **CI**: `src/golden_test.zig` validates `llm-cost` against this corpus.

**Run checks:**
```bash
zig build test          # Unit tests
zig build test-golden   # Parity verification
zig build fuzz          # Stability fuzzing
```

**Known Limitations**:
- Pricing data is updated as of December 2025.
- Requires Zig 0.14.0 exact version.

## License

See [LICENSE](LICENSE) and [NOTICE](NOTICE).
