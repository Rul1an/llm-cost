#!/usr/bin/env python3
"""
Benchmark llm-cost vs tiktoken

Compares tokenization performance between llm-cost and tiktoken on
identical inputs to produce fair, reproducible benchmarks.

Usage:
    python scripts/bench_vs_tiktoken.py [options]

Options:
    --size SIZE        Input size: 1KB, 10KB, 100KB, 1MB (default: 1MB)
    --iterations N     Number of iterations (default: 100)
    --encoding ENC     Encoding to test (default: o200k_base)
    --warmup N         Warmup iterations (default: 10)
    --json             Output JSON instead of table
    --output FILE      Write results to file
    --llm-cost PATH    Path to llm-cost binary (default: ./zig-out/bin/llm-cost)

Examples:
    # Basic comparison
    python scripts/bench_vs_tiktoken.py

    # Quick test with smaller input
    python scripts/bench_vs_tiktoken.py --size 10KB --iterations 50

    # JSON output for CI
    python scripts/bench_vs_tiktoken.py --json --output results.json
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# Check tiktoken availability
try:
    import tiktoken
    TIKTOKEN_AVAILABLE = True
except ImportError:
    TIKTOKEN_AVAILABLE = False


@dataclass
class BenchmarkResult:
    """Result of a single benchmark run"""
    name: str
    encoding: str
    input_bytes: int
    iterations: int
    tokens: int
    times_ns: list[int]

    @property
    def min_ns(self) -> int:
        return min(self.times_ns)

    @property
    def max_ns(self) -> int:
        return max(self.times_ns)

    @property
    def mean_ns(self) -> float:
        return statistics.mean(self.times_ns)

    @property
    def p50_ns(self) -> float:
        return statistics.median(self.times_ns)

    @property
    def p95_ns(self) -> float:
        sorted_times = sorted(self.times_ns)
        idx = int(len(sorted_times) * 0.95)
        return sorted_times[min(idx, len(sorted_times) - 1)]

    @property
    def p99_ns(self) -> float:
        sorted_times = sorted(self.times_ns)
        idx = int(len(sorted_times) * 0.99)
        return sorted_times[min(idx, len(sorted_times) - 1)]

    @property
    def throughput_mbps(self) -> float:
        """Calculate throughput in MB/s"""
        if self.mean_ns == 0:
            return 0
        bytes_per_sec = self.input_bytes / (self.mean_ns / 1e9)
        return bytes_per_sec / 1e6

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "encoding": self.encoding,
            "input_bytes": self.input_bytes,
            "iterations": self.iterations,
            "tokens": self.tokens,
            "throughput_mbps": round(self.throughput_mbps, 4),
            "latency_ns": {
                "min": self.min_ns,
                "p50": int(self.p50_ns),
                "p95": int(self.p95_ns),
                "p99": int(self.p99_ns),
                "max": self.max_ns,
                "mean": int(self.mean_ns),
            }
        }


def parse_size(size_str: str) -> int:
    """Parse size string like '1KB', '10MB' into bytes"""
    size_str = size_str.upper().strip()

    multipliers = {
        'B': 1,
        'KB': 1024,
        'MB': 1024 * 1024,
        'GB': 1024 * 1024 * 1024,
    }

    for suffix, mult in sorted(multipliers.items(), key=lambda x: -len(x[0])):
        if size_str.endswith(suffix):
            num_str = size_str[:-len(suffix)]
            return int(float(num_str) * mult)

    return int(size_str)


def generate_test_data(size_bytes: int, seed: int = 42) -> str:
    """
    Generate reproducible English-like text for benchmarking.

    Uses a fixed word list and deterministic selection for reproducibility.
    """
    import random
    random.seed(seed)

    # Common English words of varying lengths
    words = [
        # Short words
        "the", "a", "an", "is", "it", "to", "of", "in", "on", "at",
        "and", "or", "but", "not", "for", "with", "as", "by", "from",
        # Medium words
        "hello", "world", "this", "that", "have", "been", "will", "would",
        "could", "should", "about", "after", "before", "between", "through",
        "during", "within", "without", "because", "although", "however",
        # Longer words
        "performance", "tokenization", "benchmark", "implementation",
        "optimization", "measurement", "comparison", "throughput",
        "processing", "algorithm", "application", "development",
        # Technical words
        "function", "variable", "parameter", "interface", "component",
        "structure", "encoding", "decoding", "compression", "analysis",
        # Numbers and punctuation contexts
        "100", "2024", "first", "second", "third", "example", "result",
    ]

    result = []
    current_size = 0

    while current_size < size_bytes:
        word = random.choice(words)
        space = " " if result else ""
        addition = space + word
        if current_size + len(addition) > size_bytes:
            # Fill remaining space
            remaining = size_bytes - current_size
            result.append(addition[:remaining])
            break
        result.append(addition)
        current_size += len(addition)

    return "".join(result)


def benchmark_tiktoken(
    text: str,
    encoding: str,
    iterations: int,
    warmup: int
) -> BenchmarkResult:
    """Benchmark tiktoken tokenizer"""
    enc = tiktoken.get_encoding(encoding)

    # Warmup
    for _ in range(warmup):
        enc.encode(text)

    # Benchmark
    times_ns = []
    tokens = None

    for _ in range(iterations):
        start = time.perf_counter_ns()
        result = enc.encode(text)
        elapsed = time.perf_counter_ns() - start
        times_ns.append(elapsed)
        if tokens is None:
            tokens = len(result)

    return BenchmarkResult(
        name=f"tiktoken",
        encoding=encoding,
        input_bytes=len(text.encode('utf-8')),
        iterations=iterations,
        tokens=tokens or 0,
        times_ns=times_ns,
    )


def benchmark_llm_cost(
    text: str,
    encoding: str,
    iterations: int,
    warmup: int,
    binary_path: str
) -> Optional[BenchmarkResult]:
    """Benchmark llm-cost tokenizer via CLI"""

    # Check binary exists
    if not Path(binary_path).exists():
        print(f"Warning: llm-cost binary not found at {binary_path}", file=sys.stderr)
        return None

    # Write test data to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(text)
        temp_path = f.name

    try:
        # Map encoding to model
        model_map = {
            "cl100k_base": "gpt-4",
            "o200k_base": "gpt-4o",
        }
        model = model_map.get(encoding, "gpt-4o")

        # Warmup
        for _ in range(warmup):
            subprocess.run(
                [binary_path, "count", temp_path, "--model", model],
                capture_output=True,
                check=True,
            )

        # Benchmark
        times_ns = []
        tokens = None

        for _ in range(iterations):
            start = time.perf_counter_ns()
            result = subprocess.run(
                [binary_path, "count", temp_path, "--model", model],
                capture_output=True,
                check=True,
            )
            elapsed = time.perf_counter_ns() - start
            times_ns.append(elapsed)

            if tokens is None:
                # Parse token count from output
                output = result.stdout.decode().strip()
                try:
                    # Assume output format is "NNNN tokens" or just "NNNN"
                    tokens = int(output.split()[0])
                except (ValueError, IndexError):
                    tokens = 0

        return BenchmarkResult(
            name="llm-cost",
            encoding=encoding,
            input_bytes=len(text.encode('utf-8')),
            iterations=iterations,
            tokens=tokens or 0,
            times_ns=times_ns,
        )

    finally:
        os.unlink(temp_path)


def format_table(results: list[BenchmarkResult]) -> str:
    """Format results as ASCII table"""
    if not results:
        return "No results to display"

    # Calculate baseline for ratio
    baseline_throughput = results[0].throughput_mbps if results else 1

    lines = [
        "╔════════════════════════════════════════════════════════════════════════════╗",
        "║                        Benchmark Comparison                                ║",
        "╠════════════════════════════════════════════════════════════════════════════╣",
        "║ Implementation │ Throughput  │   p50    │   p95    │   p99    │   Ratio   ║",
        "╟────────────────┼─────────────┼──────────┼──────────┼──────────┼───────────╢",
    ]

    for r in results:
        ratio = r.throughput_mbps / baseline_throughput if baseline_throughput > 0 else 0
        lines.append(
            f"║ {r.name:<14} │ {r.throughput_mbps:>7.2f} MB/s│ {r.p50_ns/1e6:>6.2f}ms │ "
            f"{r.p95_ns/1e6:>6.2f}ms │ {r.p99_ns/1e6:>6.2f}ms │ {ratio:>6.2f}x   ║"
        )

    lines.append("╚════════════════════════════════════════════════════════════════════════════╝")

    return "\n".join(lines)


def format_comparison_summary(results: list[BenchmarkResult]) -> str:
    """Generate comparison summary"""
    if len(results) < 2:
        return ""

    tiktoken_result = next((r for r in results if "tiktoken" in r.name.lower()), None)
    llm_cost_result = next((r for r in results if "llm-cost" in r.name.lower()), None)

    if not tiktoken_result or not llm_cost_result:
        return ""

    ratio = llm_cost_result.throughput_mbps / tiktoken_result.throughput_mbps

    lines = [
        "",
        "── Comparison Summary ──",
        "",
        f"  tiktoken:  {tiktoken_result.throughput_mbps:>7.2f} MB/s ({tiktoken_result.tokens:,} tokens)",
        f"  llm-cost:  {llm_cost_result.throughput_mbps:>7.2f} MB/s ({llm_cost_result.tokens:,} tokens)",
        "",
    ]

    # Token parity check
    if tiktoken_result.tokens == llm_cost_result.tokens:
        lines.append(f"  ✓ Token count matches: {tiktoken_result.tokens:,}")
    else:
        diff = abs(tiktoken_result.tokens - llm_cost_result.tokens)
        lines.append(f"  ⚠️ Token count differs by {diff} ({tiktoken_result.tokens} vs {llm_cost_result.tokens})")

    lines.append("")

    # Verdict
    if ratio > 1.1:
        lines.append(f"  ✅ llm-cost is {ratio:.2f}x FASTER than tiktoken")
    elif ratio < 0.9:
        lines.append(f"  ⚠️  llm-cost is {1/ratio:.2f}x SLOWER than tiktoken")
    else:
        lines.append(f"  ≈ Performance is comparable (ratio: {ratio:.2f}x)")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark llm-cost vs tiktoken",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument(
        "--size", default="1MB",
        help="Input size (e.g., 1KB, 10KB, 100KB, 1MB)"
    )
    parser.add_argument(
        "--iterations", type=int, default=100,
        help="Number of benchmark iterations"
    )
    parser.add_argument(
        "--encoding", default="o200k_base",
        choices=["cl100k_base", "o200k_base"],
        help="Encoding to benchmark"
    )
    parser.add_argument(
        "--warmup", type=int, default=10,
        help="Warmup iterations"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output JSON format"
    )
    parser.add_argument(
        "--output", type=str,
        help="Write output to file"
    )
    parser.add_argument(
        "--llm-cost", default="./zig-out/bin/llm-cost",
        help="Path to llm-cost binary"
    )

    args = parser.parse_args()

    # Parse size
    size_bytes = parse_size(args.size)

    # Check dependencies
    if not TIKTOKEN_AVAILABLE:
        print("Error: tiktoken not installed. Run: pip install tiktoken", file=sys.stderr)
        sys.exit(1)

    # Generate test data
    print(f"Generating {args.size} test data...", file=sys.stderr)
    text = generate_test_data(size_bytes)
    print(f"  Generated {len(text):,} bytes", file=sys.stderr)

    print(f"Running benchmarks ({args.iterations} iterations, {args.warmup} warmup)...", file=sys.stderr)

    results = []

    # Benchmark tiktoken
    print("  Benchmarking tiktoken...", file=sys.stderr)
    tiktoken_result = benchmark_tiktoken(text, args.encoding, args.iterations, args.warmup)
    results.append(tiktoken_result)
    print(f"    {tiktoken_result.throughput_mbps:.2f} MB/s", file=sys.stderr)

    # Benchmark llm-cost
    print("  Benchmarking llm-cost...", file=sys.stderr)
    llm_cost_result = benchmark_llm_cost(
        text, args.encoding, args.iterations, args.warmup, args.llm_cost
    )
    if llm_cost_result:
        results.append(llm_cost_result)
        print(f"    {llm_cost_result.throughput_mbps:.2f} MB/s", file=sys.stderr)
    else:
        print("    Skipped (binary not found)", file=sys.stderr)

    # Format output
    if args.json:
        output = json.dumps({
            "meta": {
                "input_size": args.size,
                "input_bytes": size_bytes,
                "encoding": args.encoding,
                "iterations": args.iterations,
            },
            "results": [r.to_dict() for r in results],
        }, indent=2)
    else:
        output = format_table(results) + format_comparison_summary(results)

    # Write output
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"\nResults written to {args.output}", file=sys.stderr)
    else:
        print()
        print(output)


if __name__ == "__main__":
    main()
