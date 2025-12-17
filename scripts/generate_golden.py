#!/usr/bin/env python3
"""Generate golden test data using tiktoken as reference."""

import json
import tiktoken
from pathlib import Path
import sys
import os

# Test cases organized by category
TEST_CASES = {
    "basic": [
        "",
        "hello",
        "Hello World",
        "The quick brown fox jumps over the lazy dog.",
    ],
    "whitespace": [
        " ",
        "  ",
        "\n",
        "\n\n",
        "\t",
        "hello world",  # single space
        "hello  world",  # double space
        "hello\nworld",
        "  leading",
        "trailing  ",
    ],
    "contractions": [
        "I'm",
        "don't",
        "it's",
        "you're",
        "they've",
        "I'll",
        "can't",
        "won't",
        "shouldn't",
    ],
    "unicode": [
        "café",
        "naïve",
        "日本語",
        "中文测试",
        "Привет мир",
        "مرحبا بالعالم",
        "🎉",
        "🚀🌟💻",
        "👨‍👩‍👧‍👦",  # ZWJ family
        "é",  # single char
        "e\u0301",  # e + combining acute (NFD)
    ],
    "numbers": [
        "0",
        "123",
        "1000000",
        "3.14159",
        "1,234,567",
        "-42",
        "1e10",
        "0x1F",
    ],
    "code": [
        "def foo():",
        "function bar() {",
        "public static void main",
        "<div class=\"test\">",
        '{"key": "value"}',
        "SELECT * FROM users",
        "import numpy as np",
        "console.log('hello')",
        "#!/bin/bash",
        "// comment",
        "/* block */",
    ],
    "mixed": [
        "Hello, 世界! 🌍",
        "Price: $19.99",
        "Email: test@example.com",
        "URL: https://example.com/path?q=1",
        "Date: 2025-12-10",
        "Phone: +1-555-123-4567",
    ],
    "evil": [
        "\x00",  # null byte
        "\ufeff",  # BOM
        "\u200b",  # zero-width space
        "\u200d",  # ZWJ
        "\u2028",  # line separator
        "\u2029",  # paragraph separator
        "a\u0300\u0301\u0302",  # multiple combining marks
        # "\ud83d",  # lone surrogate (invalid UTF-8, causes json dump error)
    ],
}

# 1. Version Pinning (Audit Requirement)
# We strictly test against 0.8.0 to prevent upstream drift invalidated the parity audit.
EXPECTED_TIKTOKEN_VERSION = "0.8.0"
assert tiktoken.__version__ == EXPECTED_TIKTOKEN_VERSION, \
    f"Expected tiktoken {EXPECTED_TIKTOKEN_VERSION}, got {tiktoken.__version__}"

# 2. Test Cases
# We include specific "nasty" cases for parity.
TEST_CASES = {
    "simple": [
        "hello world",
        "Hello World",
        " hello world",
        "hello world ",
    ],
    "scaling": [
        "a" * 100,
        "test " * 50,
    ],
    "special_literals": [
        # Must be treated as TEXT in ordinary mode!
        "<|endoftext|>",
        "<|fim_prefix|>hello<|fim_suffix|>",
    ],
    "unicode": [
        "💩",
        "Hello 💩 World",
        "こんにちは世界", # Japanese
        "안녕하세요", # Korean
        "你好世界", # Chinese
        "مرحبا بالعالم", # Arabic (RTL)
    ],
    "code": [
        "fn main() { print(\"hello\"); }",
        "print('hello world')",
        "<div>html test</div>",
        "class Foo extends Bar { constructor() { super(); } }",
    ],
    "whitespace": [
        "   ",
        "\t\t\t",
        "\n\n\n",
        "  hello  \n  world  ",
    ]
}

ENCODINGS = ["cl100k_base", "o200k_base"]

LOREM_IPSUM = """Lorem ipsum dolor sit amet, consectetur adipiscing elit.
Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."""

SAMPLE_CODE = """
def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)
"""

def generate_golden():
    os.makedirs("test/golden", exist_ok=True)
    out_path = "test/golden/corpus_v2.jsonl"

    with open(out_path, "w") as f:
        print(f"Generating {out_path} using tiktoken {tiktoken.__version__}...")

        count = 0
        for enc_name in ENCODINGS:
            try:
                enc = tiktoken.get_encoding(enc_name)
            except:
                print(f"Skipping {enc_name} (not found)")
                continue

            for category, inputs in TEST_CASES.items():
                for i, text in enumerate(inputs):
                    # 3. Usage of encode_ordinary
                    # Our Zig tokenizer is "dumb" (pure BPE), specials are handled upstream.
                    # So we verify against encode_ordinary to ensure <|endoftext|> is tokenized as literals.
                    tokens = enc.encode_ordinary(text)

                    case = {
                        "id": f"{enc_name}_{category}_{i}",
                        "encoding": enc_name,
                        "category": category,
                        "text": text,
                        "tokens": tokens,
                        "token_count": len(tokens),
                    }
                    f.write(json.dumps(case, ensure_ascii=False) + "\n")
                    count += 1

    print(f"Generated {count} test cases to {out_path}")

def generate_long_tests(output_path: Path):
    """Generate long text test cases."""
    print("Generating long test cases...")

    # Generate various long texts
    long_texts = [
        ("repeat_hello", "hello " * 1000),
        ("repeat_unicode", "日本語テスト " * 500),
        ("lorem_ipsum", LOREM_IPSUM * 10),
        ("code_block", SAMPLE_CODE * 20),
    ]

    results = []

    for encoding_name in ENCODINGS:
        try:
            enc = tiktoken.get_encoding(encoding_name)
        except:
            continue

        for name, text in long_texts:
            try:
                tokens = enc.encode(text)
                results.append({
                    "id": f"long_{name}_{encoding_name}",
                    "encoding": encoding_name,
                    "category": "long",
                    "text": text,
                    "tokens": tokens,
                    "token_count": len(tokens),
                })
            except Exception as e:
                print(f"Warning: Failed to encode long text {name}: {e}")

    with open(output_path, "a", encoding="utf-8") as f:
        for item in results:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")

    print(f"Added {len(results)} long test cases")

if __name__ == "__main__":
    try:
        import tiktoken
    except ImportError:
        print("Error: 'tiktoken' module not found. Please install it using: pip install tiktoken")
        sys.exit(1)

    output = Path("test/golden/corpus_v2.jsonl")
    generate_golden()
    generate_long_tests(output)
