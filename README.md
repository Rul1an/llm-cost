# llm-cost

**Status: Experimental (v0.1)**

A high-performance, single-binary CLI for LLM token counting and cost estimation.

## Features
- **Offline First**: No API calls required.
- **Fast**: Written in Zig for native performance.
- **Cross-Platform**: Statically linked binaries for Linux, macOS, and Windows.
- **Flexible**: Pipe-friendly (`stdin` support) and machine-readable output (`json`, `ndjson`).

## Usage

```bash
# Count tokens (Generic/Whitespace for v0.1)
echo "Hello world" | llm-cost tokens

# Estimate cost (v0.1 Stub)
llm-cost price --model gpt-4o
```

## Build

```bash
zig build
```

## License
MIT
