# Phase 5: Performance Benchmarks

**Status:** PLANNED  
**Effort:** 3-4 days  
**Dependencies:** Phase 4 Complete (SLSA ✅)

---

## 1. Executive Summary

This phase implements comprehensive performance benchmarks for llm-cost, enabling:
- Quantified performance claims (MB/s, latency percentiles)
- Regression detection in CI
- Head-to-head comparison with tiktoken
- Performance documentation for users

### Target Metrics

| Metric | Target | Rationale |
|--------|--------|-----------|
| **Throughput** | ≥10 MB/s | Match or exceed tiktoken (~6 MB/s) |
| **Latency p99** | <1ms per 1KB | Interactive use cases |
| **Memory** | <100MB RSS | CLI tool constraint |
| **Scaling** | Linear O(n) | No pathological inputs |

---

## 2. Industry Baseline

### tiktoken Performance (Reference)

| Source | Throughput | Notes |
|--------|------------|-------|
| OpenAI official | 3-6x faster than HuggingFace | ~6 MB/s claimed |
| TokenMonster bench | 6.2 MB/s | GPT-2 tokenizer |
| fast_bpe_tokenizer | 2.8 MB/s (tiktoken) vs 32 MB/s | 10x faster claim |
| GitHub rust-gems | ~4x faster than tiktoken | ~25 MB/s |
| rs-bpe | 3-6x faster than tiktoken | Rust implementation |

### Competitive Landscape

| Implementation | Language | Throughput | Notes |
|----------------|----------|------------|-------|
| tiktoken | Rust+Python | ~6 MB/s | Reference implementation |
| HuggingFace tokenizers | Rust+Python | ~2 MB/s | Feature-rich |
| TokenMonster | Go | ~12 MB/s | Optimized |
| GitHub bpe | Rust | ~25 MB/s | Linear complexity |
| fast_bpe_tokenizer | C++ | ~32 MB/s | Greedy algorithm |

### Our Target Position

```
                    Throughput (MB/s)
    0        10        20        30        40
    |---------|---------|---------|---------|
    
    HuggingFace [██]
    tiktoken    [██████]
    llm-cost    [██████████████] ← Target: 10-15 MB/s
    GitHub bpe  [█████████████████████████]
```

---

## 3. Benchmark Categories

### 3.1 Micro-Benchmarks

| Benchmark | Input | Iterations | Measures |
|-----------|-------|------------|----------|
| `encode_small` | 100 bytes | 100,000 | Latency, throughput |
| `encode_medium` | 10 KB | 10,000 | Latency, throughput |
| `encode_large` | 1 MB | 100 | Throughput, memory |
| `encode_huge` | 100 MB | 10 | Throughput, scaling |
| `decode_roundtrip` | 10 KB | 10,000 | Correctness overhead |

### 3.2 Real-World Benchmarks

| Benchmark | Dataset | Size | Measures |
|-----------|---------|------|----------|
| `bench_prose` | War and Peace | 3.2 MB | English prose |
| `bench_code` | Linux kernel sample | 5 MB | C code |
| `bench_mixed` | Wikipedia dump | 10 MB | Multi-language |
| `bench_unicode` | CJK corpus | 2 MB | Multi-byte chars |
| `bench_json` | OpenAI API logs | 1 MB | Structured data |

### 3.3 Stress Tests

| Test | Purpose | Pass Criteria |
|------|---------|---------------|
| `stress_pathological` | Worst-case input (aaaa...) | No quadratic blowup |
| `stress_memory` | 1GB input | <2GB RSS |
| `stress_concurrent` | 8 threads | Linear scaling |

### 3.4 Comparative Benchmarks

| Comparison | Method | Output |
|------------|--------|--------|
| `vs_tiktoken` | Same input, measure both | Ratio chart |
| `vs_tiktoken_parity` | Verify identical output | Pass/fail |

---

## 4. Implementation

### 4.1 Benchmark Harness (`src/bench.zig`)

```zig
const std = @import("std");
const Tokenizer = @import("tokenizer/mod.zig").Tokenizer;

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_bytes: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    stddev_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    
    pub fn throughputMBps(self: BenchmarkResult) f64 {
        const bytes_per_sec = @as(f64, @floatFromInt(self.total_bytes)) / 
                             (@as(f64, @floatFromInt(self.total_ns)) / 1_000_000_000.0);
        return bytes_per_sec / 1_000_000.0;
    }
    
    pub fn format(self: BenchmarkResult, writer: anytype) !void {
        try writer.print(
            \\{s}:
            \\  Iterations:  {d}
            \\  Total bytes: {d:.2} MB
            \\  Throughput:  {d:.2} MB/s
            \\  Latency:
            \\    min:  {d:.3} ms
            \\    p50:  {d:.3} ms
            \\    p95:  {d:.3} ms
            \\    p99:  {d:.3} ms
            \\    max:  {d:.3} ms
            \\
        , .{
            self.name,
            self.iterations,
            @as(f64, @floatFromInt(self.total_bytes)) / 1_000_000.0,
            self.throughputMBps(),
            @as(f64, @floatFromInt(self.min_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.p50_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.p95_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.p99_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.max_ns)) / 1_000_000.0,
        });
    }
};

pub fn runBenchmark(
    name: []const u8,
    tokenizer: *Tokenizer,
    input: []const u8,
    iterations: u64,
    warmup: u64,
) !BenchmarkResult {
    var latencies = try std.ArrayList(u64).initCapacity(std.heap.page_allocator, iterations);
    defer latencies.deinit();
    
    // Warmup
    for (0..warmup) |_| {
        _ = try tokenizer.encode(input);
    }
    
    // Benchmark
    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();
        _ = try tokenizer.encode(input);
        const elapsed = timer.read();
        total_ns += elapsed;
        try latencies.append(elapsed);
    }
    
    // Sort for percentiles
    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));
    
    return BenchmarkResult{
        .name = name,
        .iterations = iterations,
        .total_bytes = input.len * iterations,
        .total_ns = total_ns,
        .min_ns = latencies.items[0],
        .max_ns = latencies.items[latencies.items.len - 1],
        .mean_ns = total_ns / iterations,
        .stddev_ns = calculateStdDev(latencies.items, total_ns / iterations),
        .p50_ns = latencies.items[latencies.items.len / 2],
        .p95_ns = latencies.items[latencies.items.len * 95 / 100],
        .p99_ns = latencies.items[latencies.items.len * 99 / 100],
    };
}

fn calculateStdDev(values: []const u64, mean: u64) u64 {
    var sum_sq: u128 = 0;
    for (values) |v| {
        const diff = if (v > mean) v - mean else mean - v;
        sum_sq += @as(u128, diff) * @as(u128, diff);
    }
    const variance = sum_sq / values.len;
    return @intCast(std.math.sqrt(variance));
}
```

### 4.2 Main Benchmark Suite (`src/bench_suite.zig`)

```zig
const std = @import("std");
const bench = @import("bench.zig");
const Tokenizer = @import("tokenizer/mod.zig").Tokenizer;

const ENCODINGS = [_][]const u8{ "cl100k_base", "o200k_base" };

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Print header
    try stdout.print(
        \\╔══════════════════════════════════════════════════════════════╗
        \\║             llm-cost Performance Benchmark Suite             ║
        \\║                      v{s}                              ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\System: {s}
        \\Date:   {s}
        \\
    , .{ version, getSystemInfo(), getTimestamp() });
    
    // Load test data
    const small_input = "Hello, world! This is a test.";
    const medium_input = try loadTestFile(allocator, "data/bench/medium.txt");
    defer allocator.free(medium_input);
    const large_input = try loadTestFile(allocator, "data/bench/large.txt");
    defer allocator.free(large_input);
    
    // Run benchmarks for each encoding
    for (ENCODINGS) |encoding| {
        try stdout.print("\n═══ Encoding: {s} ═══\n\n", .{encoding});
        
        var tokenizer = try Tokenizer.init(allocator, encoding);
        defer tokenizer.deinit();
        
        // Micro-benchmarks
        try stdout.print("── Micro-Benchmarks ──\n\n", .{});
        
        const small_result = try bench.runBenchmark(
            "encode_small (30B)",
            &tokenizer,
            small_input,
            100_000,
            1000,
        );
        try small_result.format(stdout);
        
        const medium_result = try bench.runBenchmark(
            "encode_medium (10KB)",
            &tokenizer,
            medium_input,
            10_000,
            100,
        );
        try medium_result.format(stdout);
        
        const large_result = try bench.runBenchmark(
            "encode_large (1MB)",
            &tokenizer,
            large_input,
            100,
            10,
        );
        try large_result.format(stdout);
        
        // Summary
        try stdout.print(
            \\── Summary ──
            \\
            \\  Best throughput:  {d:.2} MB/s ({s})
            \\  Worst latency:    {d:.3} ms p99 ({s})
            \\
        , .{
            @max(small_result.throughputMBps(), 
                 @max(medium_result.throughputMBps(), large_result.throughputMBps())),
            "encode_large",
            @as(f64, @floatFromInt(small_result.p99_ns)) / 1_000_000.0,
            "encode_small",
        });
    }
    
    // Memory benchmark
    try stdout.print("\n═══ Memory Usage ═══\n\n", .{});
    try runMemoryBenchmark(stdout);
    
    // Pathological input test
    try stdout.print("\n═══ Stress Tests ═══\n\n", .{});
    try runPathologicalTest(stdout, allocator);
}

fn runMemoryBenchmark(writer: anytype) !void {
    const rss = try getCurrentRSS();
    try writer.print("  Current RSS: {d:.2} MB\n", .{
        @as(f64, @floatFromInt(rss)) / 1_000_000.0,
    });
}

fn runPathologicalTest(writer: anytype, allocator: std.mem.Allocator) !void {
    // Test with worst-case input (repeated characters)
    const pathological = try allocator.alloc(u8, 100_000);
    defer allocator.free(pathological);
    @memset(pathological, 'a');
    
    var tokenizer = try Tokenizer.init(allocator, "cl100k_base");
    defer tokenizer.deinit();
    
    var timer = try std.time.Timer.start();
    _ = try tokenizer.encode(pathological);
    const elapsed = timer.read();
    
    const expected_linear_ns = 100_000 * 100; // ~100ns per byte is generous
    
    if (elapsed > expected_linear_ns * 10) {
        try writer.print("  ⚠️  Pathological input: {d:.2} ms (potential O(n²) detected!)\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    } else {
        try writer.print("  ✓  Pathological input: {d:.2} ms (linear complexity)\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }
}
```

### 4.3 Comparative Benchmark Script (`scripts/bench_vs_tiktoken.py`)

```python
#!/usr/bin/env python3
"""
Benchmark llm-cost vs tiktoken

Usage:
    python scripts/bench_vs_tiktoken.py [--size 1MB] [--iterations 100]
"""

import argparse
import subprocess
import time
import statistics
import json
import tiktoken
from pathlib import Path

def generate_test_data(size_bytes: int) -> str:
    """Generate random English-like text"""
    words = [
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
        "hello", "world", "this", "is", "a", "test", "of", "tokenization",
        "performance", "benchmark", "comparison", "between", "implementations"
    ]
    
    result = []
    current_size = 0
    while current_size < size_bytes:
        word = words[current_size % len(words)]
        result.append(word)
        current_size += len(word) + 1
    
    return " ".join(result)[:size_bytes]


def benchmark_tiktoken(text: str, encoding: str, iterations: int) -> dict:
    """Benchmark tiktoken"""
    enc = tiktoken.get_encoding(encoding)
    
    # Warmup
    for _ in range(min(10, iterations)):
        enc.encode(text)
    
    # Benchmark
    times = []
    for _ in range(iterations):
        start = time.perf_counter_ns()
        tokens = enc.encode(text)
        elapsed = time.perf_counter_ns() - start
        times.append(elapsed)
    
    return {
        "name": f"tiktoken ({encoding})",
        "iterations": iterations,
        "bytes": len(text.encode()),
        "tokens": len(tokens),
        "min_ns": min(times),
        "max_ns": max(times),
        "mean_ns": statistics.mean(times),
        "p50_ns": statistics.median(times),
        "p95_ns": sorted(times)[int(len(times) * 0.95)],
        "p99_ns": sorted(times)[int(len(times) * 0.99)],
        "throughput_mbps": (len(text.encode()) / (statistics.mean(times) / 1e9)) / 1e6,
    }


def benchmark_llm_cost(text: str, encoding: str, iterations: int) -> dict:
    """Benchmark llm-cost via CLI"""
    # Write test file
    test_file = Path("/tmp/bench_input.txt")
    test_file.write_text(text)
    
    # Warmup
    for _ in range(min(10, iterations)):
        subprocess.run(
            ["./zig-out/bin/llm-cost", "count", str(test_file), "--model", "gpt-4o"],
            capture_output=True,
            check=True,
        )
    
    # Benchmark
    times = []
    for _ in range(iterations):
        start = time.perf_counter_ns()
        result = subprocess.run(
            ["./zig-out/bin/llm-cost", "count", str(test_file), "--model", "gpt-4o"],
            capture_output=True,
            check=True,
        )
        elapsed = time.perf_counter_ns() - start
        times.append(elapsed)
    
    # Parse token count from output
    output = result.stdout.decode()
    tokens = int(output.split()[0]) if output else 0
    
    return {
        "name": f"llm-cost ({encoding})",
        "iterations": iterations,
        "bytes": len(text.encode()),
        "tokens": tokens,
        "min_ns": min(times),
        "max_ns": max(times),
        "mean_ns": statistics.mean(times),
        "p50_ns": statistics.median(times),
        "p95_ns": sorted(times)[int(len(times) * 0.95)],
        "p99_ns": sorted(times)[int(len(times) * 0.99)],
        "throughput_mbps": (len(text.encode()) / (statistics.mean(times) / 1e9)) / 1e6,
    }


def format_results(results: list[dict]) -> str:
    """Format benchmark results as table"""
    lines = [
        "╔════════════════════════════════════════════════════════════════════╗",
        "║                    Benchmark Comparison                            ║",
        "╠════════════════════════════════════════════════════════════════════╣",
        "║ Implementation      │ Throughput │  p50   │  p95   │  p99   │ Ratio║",
        "╟─────────────────────┼────────────┼────────┼────────┼────────┼──────╢",
    ]
    
    baseline = results[0]["throughput_mbps"]
    
    for r in results:
        ratio = r["throughput_mbps"] / baseline
        lines.append(
            f"║ {r['name']:<19} │ {r['throughput_mbps']:>7.2f} MB/s│ {r['p50_ns']/1e6:>5.2f}ms│ "
            f"{r['p95_ns']/1e6:>5.2f}ms│ {r['p99_ns']/1e6:>5.2f}ms│ {ratio:>4.2f}x║"
        )
    
    lines.append("╚════════════════════════════════════════════════════════════════════╝")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Benchmark llm-cost vs tiktoken")
    parser.add_argument("--size", default="1MB", help="Input size (e.g., 1KB, 1MB)")
    parser.add_argument("--iterations", type=int, default=100, help="Number of iterations")
    parser.add_argument("--encoding", default="o200k_base", help="Encoding to test")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()
    
    # Parse size
    size_str = args.size.upper()
    if size_str.endswith("KB"):
        size = int(size_str[:-2]) * 1024
    elif size_str.endswith("MB"):
        size = int(size_str[:-2]) * 1024 * 1024
    else:
        size = int(size_str)
    
    print(f"Generating {args.size} test data...")
    text = generate_test_data(size)
    
    print(f"Running benchmarks ({args.iterations} iterations)...")
    
    results = []
    
    # tiktoken benchmark
    print("  Benchmarking tiktoken...")
    results.append(benchmark_tiktoken(text, args.encoding, args.iterations))
    
    # llm-cost benchmark
    print("  Benchmarking llm-cost...")
    results.append(benchmark_llm_cost(text, args.encoding, args.iterations))
    
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print()
        print(format_results(results))
        
        # Verdict
        ratio = results[1]["throughput_mbps"] / results[0]["throughput_mbps"]
        if ratio > 1.1:
            print(f"\n✅ llm-cost is {ratio:.1f}x FASTER than tiktoken")
        elif ratio < 0.9:
            print(f"\n⚠️  llm-cost is {1/ratio:.1f}x SLOWER than tiktoken")
        else:
            print(f"\n≈ llm-cost and tiktoken have similar performance")


if __name__ == "__main__":
    main()
```

### 4.4 CI Workflow (`.github/workflows/bench.yml`)

```yaml
# Performance Benchmark Workflow
#
# Runs on:
# - Weekly schedule (track regressions)
# - Manual trigger (for releases)
# - PR comments with "/benchmark"

name: Benchmarks

on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday
  workflow_dispatch:
    inputs:
      compare_tiktoken:
        description: 'Compare with tiktoken'
        required: false
        default: 'true'
        type: boolean
  issue_comment:
    types: [created]

permissions:
  contents: read
  pull-requests: write
  issues: write

env:
  ZIG_VERSION: "0.14.0"

jobs:
  # Only run on /benchmark comment
  check-trigger:
    if: >
      github.event_name != 'issue_comment' || 
      (github.event.issue.pull_request && contains(github.event.comment.body, '/benchmark'))
    runs-on: ubuntu-latest
    outputs:
      should_run: ${{ steps.check.outputs.should_run }}
    steps:
      - id: check
        run: echo "should_run=true" >> $GITHUB_OUTPUT

  benchmark:
    needs: check-trigger
    if: needs.check-trigger.outputs.should_run == 'true'
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout
        uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1

      - name: Setup Zig
        uses: mlugg/setup-zig@v1
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Build Release
        run: zig build -Doptimize=ReleaseFast

      - name: Download Benchmark Data
        run: |
          mkdir -p data/bench
          
          # Small: Lorem ipsum
          echo "Lorem ipsum dolor sit amet, consectetur adipiscing elit." > data/bench/small.txt
          
          # Medium: War and Peace excerpt (10KB)
          curl -sL "https://www.gutenberg.org/files/2600/2600-0.txt" | head -c 10240 > data/bench/medium.txt
          
          # Large: Full text (1MB)
          curl -sL "https://www.gutenberg.org/files/2600/2600-0.txt" | head -c 1048576 > data/bench/large.txt

      - name: Run Benchmarks
        id: bench
        run: |
          # Build and run benchmark suite
          zig build bench -Doptimize=ReleaseFast
          ./zig-out/bin/llm-cost-bench > benchmark_results.txt
          
          cat benchmark_results.txt
          
          # Extract key metrics for comparison
          THROUGHPUT=$(grep "Best throughput" benchmark_results.txt | awk '{print $3}')
          echo "throughput=$THROUGHPUT" >> $GITHUB_OUTPUT

      - name: Compare with tiktoken
        if: ${{ github.event.inputs.compare_tiktoken != 'false' }}
        run: |
          pip install tiktoken
          python scripts/bench_vs_tiktoken.py --size 1MB --iterations 50 > comparison.txt
          cat comparison.txt

      - name: Upload Results
        uses: actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08  # v4.6.0
        with:
          name: benchmark-results
          path: |
            benchmark_results.txt
            comparison.txt
          retention-days: 90

      - name: Comment on PR
        if: github.event_name == 'issue_comment'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const results = fs.readFileSync('benchmark_results.txt', 'utf8');
            const comparison = fs.existsSync('comparison.txt') 
              ? fs.readFileSync('comparison.txt', 'utf8') 
              : '';
            
            const body = `## 📊 Benchmark Results
            
            \`\`\`
            ${results}
            \`\`\`
            
            ${comparison ? `### vs tiktoken\n\`\`\`\n${comparison}\n\`\`\`` : ''}
            `;
            
            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: body
            });

      - name: Check Regression
        run: |
          THROUGHPUT="${{ steps.bench.outputs.throughput }}"
          THRESHOLD="5.0"  # MB/s minimum
          
          if (( $(echo "$THROUGHPUT < $THRESHOLD" | bc -l) )); then
            echo "::error::Performance regression detected! Throughput: ${THROUGHPUT} MB/s < ${THRESHOLD} MB/s"
            exit 1
          fi
          
          echo "✅ Performance OK: ${THROUGHPUT} MB/s"

  # Track benchmark history
  store-results:
    needs: benchmark
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    
    steps:
      - name: Download Results
        uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16  # v4.1.8
        with:
          name: benchmark-results

      - name: Append to History
        run: |
          DATE=$(date -u +"%Y-%m-%d")
          COMMIT="${{ github.sha }}"
          
          # Extract throughput
          THROUGHPUT=$(grep "Best throughput" benchmark_results.txt | awk '{print $3}')
          
          # Append to CSV (would be stored in a separate branch or artifact)
          echo "$DATE,$COMMIT,$THROUGHPUT" >> benchmark_history.csv

      - name: Upload History
        uses: actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08
        with:
          name: benchmark-history
          path: benchmark_history.csv
          retention-days: 365
```

---

## 5. Output Formats

### 5.1 Console Output

```
╔══════════════════════════════════════════════════════════════╗
║             llm-cost Performance Benchmark Suite             ║
║                      v0.7.0                                  ║
╚══════════════════════════════════════════════════════════════╝

System: Linux x86_64, 16 cores, 32GB RAM
Date:   2025-12-10T14:30:00Z

═══ Encoding: cl100k_base ═══

── Micro-Benchmarks ──

encode_small (30B):
  Iterations:  100000
  Total bytes: 3.00 MB
  Throughput:  15.23 MB/s
  Latency:
    min:  0.001 ms
    p50:  0.002 ms
    p95:  0.003 ms
    p99:  0.004 ms
    max:  0.012 ms

encode_medium (10KB):
  Iterations:  10000
  Total bytes: 100.00 MB
  Throughput:  12.45 MB/s
  Latency:
    min:  0.723 ms
    p50:  0.803 ms
    p95:  0.892 ms
    p99:  0.956 ms
    max:  1.234 ms

encode_large (1MB):
  Iterations:  100
  Total bytes: 100.00 MB
  Throughput:  11.82 MB/s
  Latency:
    min:  82.3 ms
    p50:  84.6 ms
    p95:  87.2 ms
    p99:  89.1 ms
    max:  92.4 ms

── Summary ──

  Best throughput:  15.23 MB/s (encode_small)
  Worst latency:    0.004 ms p99 (encode_small)

═══ Memory Usage ═══

  Current RSS: 45.2 MB
  Peak RSS:    67.8 MB

═══ Stress Tests ═══

  ✓  Pathological input: 12.34 ms (linear complexity)
  ✓  Large file (100MB): 8.45 s (11.83 MB/s)
```

### 5.2 JSON Output

```json
{
  "meta": {
    "version": "0.7.0",
    "timestamp": "2025-12-10T14:30:00Z",
    "system": {
      "os": "linux",
      "arch": "x86_64",
      "cores": 16,
      "memory_gb": 32
    },
    "zig_version": "0.14.0"
  },
  "benchmarks": [
    {
      "name": "encode_small",
      "encoding": "cl100k_base",
      "input_bytes": 30,
      "iterations": 100000,
      "throughput_mbps": 15.23,
      "latency_ns": {
        "min": 1000,
        "p50": 2000,
        "p95": 3000,
        "p99": 4000,
        "max": 12000
      }
    }
  ],
  "comparison": {
    "tiktoken": {
      "throughput_mbps": 6.2
    },
    "ratio": 2.46
  },
  "memory": {
    "current_rss_mb": 45.2,
    "peak_rss_mb": 67.8
  },
  "stress_tests": {
    "pathological": {
      "passed": true,
      "time_ms": 12.34
    }
  }
}
```

### 5.3 Markdown Report (for CI)

```markdown
## 📊 Benchmark Results

**Version:** v0.7.0  
**Date:** 2025-12-10  
**Commit:** abc1234

### Throughput

| Input Size | cl100k_base | o200k_base |
|------------|-------------|------------|
| 30B        | 15.2 MB/s   | 14.8 MB/s  |
| 10KB       | 12.5 MB/s   | 12.1 MB/s  |
| 1MB        | 11.8 MB/s   | 11.5 MB/s  |

### vs tiktoken

| Metric | llm-cost | tiktoken | Ratio |
|--------|----------|----------|-------|
| 1MB throughput | 11.8 MB/s | 6.2 MB/s | **1.9x faster** |
| p99 latency | 89 ms | 165 ms | **1.9x faster** |

### Status

✅ **No regressions detected**
```

---

## 6. Test Data

### 6.1 Bundled Data (`data/bench/`)

| File | Size | Content | Source |
|------|------|---------|--------|
| `small.txt` | 100B | Lorem ipsum | Generated |
| `medium.txt` | 10KB | War and Peace excerpt | Gutenberg |
| `large.txt` | 1MB | War and Peace | Gutenberg |
| `code.txt` | 500KB | Linux kernel sample | kernel.org |
| `unicode.txt` | 200KB | Multi-language Wikipedia | Wikipedia |
| `pathological.txt` | 100KB | Repeated 'a' chars | Generated |

### 6.2 Download Script

```bash
#!/bin/bash
# scripts/download_bench_data.sh

set -euo pipefail

mkdir -p data/bench

echo "Downloading benchmark data..."

# War and Peace (English prose)
curl -sL "https://www.gutenberg.org/files/2600/2600-0.txt" -o data/bench/war_and_peace.txt

# Create size variants
head -c 100 data/bench/war_and_peace.txt > data/bench/small.txt
head -c 10240 data/bench/war_and_peace.txt > data/bench/medium.txt
head -c 1048576 data/bench/war_and_peace.txt > data/bench/large.txt

# Pathological input
python3 -c "print('a' * 100000)" > data/bench/pathological.txt

echo "Done!"
ls -lh data/bench/
```

---

## 7. Build Integration

### 7.1 build.zig Addition

```zig
// Benchmark executable
const bench_exe = b.addExecutable(.{
    .name = "llm-cost-bench",
    .root_source_file = b.path("src/bench_suite.zig"),
    .target = target,
    .optimize = .ReleaseFast,  // Always optimize benchmarks
});
b.installArtifact(bench_exe);

const run_bench = b.addRunArtifact(bench_exe);
run_bench.step.dependOn(b.getInstallStep());
if (b.args) |args| {
    run_bench.addArgs(args);
}

const bench_step = b.step("bench", "Run performance benchmarks");
bench_step.dependOn(&run_bench.step);
```

---

## 8. Success Criteria

| Criterion | Target | Verification |
|-----------|--------|--------------|
| Throughput ≥10 MB/s | cl100k_base, 1MB input | `bench_suite` output |
| vs tiktoken ≥1.5x | Same input, same encoding | `bench_vs_tiktoken.py` |
| No O(n²) regression | Pathological input <100ms | Stress test |
| Memory <100MB | 1MB input | RSS measurement |
| CI benchmark job | Weekly + on-demand | GitHub Actions |
| Benchmark history | 90 days retention | Artifact storage |

---

## 9. Timeline

| Day | Task |
|-----|------|
| 1 | Implement `bench.zig` harness |
| 1 | Implement `bench_suite.zig` |
| 2 | Create `bench_vs_tiktoken.py` |
| 2 | Download/generate test data |
| 3 | CI workflow (`bench.yml`) |
| 3 | Documentation |
| 4 | Run full benchmark, tune if needed |

**Total: ~4 days**

---

## 10. Future Enhancements

| Enhancement | Description | Priority |
|-------------|-------------|----------|
| Continuous tracking | Graph throughput over time | Medium |
| Multi-threaded bench | Test parallel tokenization | Low |
| Memory profiling | Track allocations | Medium |
| Flame graphs | CPU profiling visualization | Low |
| Regression alerts | Slack/email on regression | Medium |
