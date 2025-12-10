## Verification Matrix

Before any release (or PR merge), the following checks must pass:

| Check | Command | Purpose |
| :--- | :--- | :--- |
| **Unit Tests** | `zig build test` | Core logic, pipe IO, pricing math |
| **Parity Tests** | `zig build test-parity` | 100% match with `tiktoken` (requires Python) |
| **Fuzz Tests** | `zig build fuzz` | Parser robustness (no panics on random input) |
| **Benchmarks** | `zig build bench-bpe` | Performance regression check (~1ms/4KB) |

## Release Process
```bash
zig build fuzz
```
*Note: This runs ~2000 iterations per model as a CI-friendly safety check.*

### 3. Parity Tests
Verifies that tokenization output is bit-identical to OpenAI's `tiktoken` library reference.
```bash
zig build test-parity
```
*Note: This relies on `testdata/evil_corpus_v2.jsonl` being present and frozen in the repo. Do NOT regenerate this file in CI to ensure stability.*
See [docs/evil_corpus.md](evil_corpus.md) for regeneration rules.

### 4. Performance Baseline
Ensures no performance regressions.
```bash
zig build bench-bpe
```
**Success Criteria**:
- `a * 4096` scaling should be < 2ms (linear/log-linear).
- Throughput should be >30 MB/s.

## Release Steps

The GitHub Actions Release workflow handles the heavy lifting:
- **Build**: Compiles binaries for Linux (gnu/musl), macOS (ARM64), and Windows.
- **SBOM**: Generates CycloneDX SBOMs using `syft`.
- **Sign**: Signs artifacts using `cosign` (keyless).
- **Publish**: Attaches artifacts to the GitHub Release.

### Manual Steps

1. **Update Version**:
   - Bump version in `build.zig.zon` (if applicable).
   - Update `README.md` if version numbers are mentioned.
2. **Changelog**: Add a new entry to `CHANGELOG.md`.
3. **Commit**: `git commit -m "chore: prepare release vX.Y.Z"`
4. **Tag**: `git tag -a vX.Y.Z -m "Release vX.Y.Z"`
5. **Push**: `git push origin vX.Y.Z`

### Signature Verification

Users can verify the release artifacts using Cosign:

```bash
cosign verify-blob \
  --certificate llm-cost-linux-x86_64.crt \
  --signature llm-cost-linux-x86_64.sig \
  llm-cost-linux-x86_64
```
