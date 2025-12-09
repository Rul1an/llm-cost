# llm-cost

[![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases)
[![Build Status](https://img.shields.io/github/actions/workflow/status/Rul1an/llm-cost/release.yml?branch=main)](https://github.com/Rul1an/llm-cost/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Offline, exact token counting & cost estimation for OpenAI-style LLMs.**

`llm-cost` is a high-performance, single-binary CLI written in [Zig](https://ziglang.org). It provides production-grade token counting (perfect parity with `tiktoken`) and offline cost estimation.

- **Features**: `o200k_base` (GPT-4o) & `cl100k_base` support, 100% offline, cross-platform binaries.
- **Why not just tiktoken?**: Single binary (no Python required), built-in pricing DB, batch processing (`pipe`), and strict memory safety.
- **Privacy & Safety**: **No data leaves your machine.** All tokenization and pricing logic runs 100% locally.
- **Supported Models**: `gpt-4o`, `gpt-4`, `gpt-3.5-turbo`, and accurate pricing for all major OpenAI endpoints.

## Who is this for?

- **ML Engineers**: Estimate costs for evaluation pipelines and RAG prompts.
- **Data Teams**: Process JSONL logs in batch to reconstruct historical token usage.
- **FinOps / Platform**: Add "budget guards" (`--max-cost`) to CI/CD pipelines to prevent accidental overspending.

## Documentation

- **[Installation & Usage](#installation)**: Getting started.
- **[Architecture](docs/architecture.md)**: High-level design and data flow.
- **[Performance](docs/perf.md)**: Benchmarks and O(N log N) BPE implementation.
- **[Verification](docs/evil_corpus.md)**: How we verify parity with OpenAI.

## Installation

Download the latest binary from the [Releases Page](https://github.com/Rul1an/llm-cost/releases).

**Linux / macOS / Windows**:
```bash
# Example for Linux x86_64
wget https://github.com/Rul1an/llm-cost/releases/latest/download/llm-cost-linux-x86_64.zip
unzip llm-cost-linux-x86_64.zip
chmod +x llm-cost
sudo mv llm-cost /usr/local/bin/
```

*See [Releases](https://github.com/Rul1an/llm-cost/releases) for signatures and SHA256 hashes.*

## Usage

### Token Counting & Pricing

```bash
# Count tokens (defaults to o200k_base for gpt-4o)
echo "Hello AI" | llm-cost tokens --model gpt-4o

# Estimate price for a file
llm-cost price --model gpt-4o prompt.txt
```

### Pipe Mode (Batch / Agent)

Process JSONL streams efficiently. Useful for adding token counts to logs or enforcing quotas in agent loops.

```bash
cat data.jsonl | llm-cost pipe --model gpt-4o --summary --max-cost 5.00
```

See `llm-cost help` for full options.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions and guidelines.

By participating in this project, you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security & Compliance

llm-cost is ontworpen als een **offline** CLI-tool met een sterke focus op supply chain veiligheid en voorspelbaar gedrag.

- 🔒 **Offline by design**
  llm-cost maakt geen netwerkverbindingen, slaat geen secrets op en leest alleen van stdin of expliciete bestanden.

- 🧾 **Signed releases + SBOM**
  Alle officiële releases bevatten:
  - ondertekende binaries (`.sig` + `.crt`),
  - een CycloneDX SBOM (`.cdx.json`),
  - SLSA Level 2 provenance voor build-herkomst.

- 🧱 **Reproducible CI pipeline**
  - Zig 0.13.x gepind.
  - GitHub Actions gepind op SHA.
  - Release workflow draait `zig build test`, `zig build test-golden`, `zig build fuzz`, `zig build test-parity` voordat binaries worden gebouwd en gesigned.

- ✅ **Supported versions & disclosure policy**
  Zie [`SECURITY.md`](./SECURITY.md) voor:
  - ondersteunde versies (support matrix),
  - responsible disclosure proces,
  - response targets (72h ack / 90d fix).

- 🔍 **Security & verification guide**
  Zie [`docs/security.md`](./docs/security.md) voor:
  - stap-voor-stap verificatie van signatures & SLSA provenance,
  - SBOM-verificatie,
  - voorbeeld-commando’s voor enterprise omgevingen.

- 📊 **Performance & regression testing**
  Zie [`docs/benchmarks.md`](./docs/benchmarks.md) voor:
  - benchmark-scripts,
  - interpretatie van resultaten,
  - hoe regressies gedetecteerd worden voordat een release live gaat.

Als je llm-cost wilt inzetten in een streng gereguleerde omgeving (financieel, zorg, overheid) en extra informatie nodig hebt, start dan bij [`SECURITY.md`](./SECURITY.md) en [`docs/security.md`](./docs/security.md).

## License

MIT
