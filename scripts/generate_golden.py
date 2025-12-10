#!/usr/bin/env python3
import json
import tiktoken
import sys

# Best practices 2025: Use explicit encoding retrieval and handle special tokens safely.

MODELS = [
    ("gpt-4", "cl100k_base"),
    ("gpt-4o", "o200k_base"),
]

# "Evil" corpus designed to stress-test BPE boundaries, Unicode, and whitespace.
CASES = [
    # Basic
    "Hello world",
    "",  # Empty
    "   ", # Whitespace only

    # Unicode / CJK
    "こんにちは世界", # Japanese
    "Hello 🌍 world", # Emoji mixing
    "👍🏽", # Skin tone modifier

    # Normalization & Edge cases
    "café", # NFC
    "cafe\u0301", # NFD (combining acute)

    # Whitespace heavy
    "  hello  \n  world  ",
    "\t\t\t",

    # Long runs
    "a" * 100,

    # Random bytes/garbage (if valid utf8)
    "ð\u009f\u0092\u00a9", # Pile of poo utf-8 seq interpreted as string (if python handles it)

    # Programming
    "fn main() { println!(\"Hello\"); }",

    # Special tokens (as text) -> Should be encodable if disallowed_special=() or "all" depending on usage.
    # Here we treat them as normal text for parity test (tiktoken encode_ordinary equivalent)
    "<|endoftext|>",
    "User: Hello<|endoftext|>",
]

OUTPUT_FILE = "testdata/golden/evil_corpus_v2.jsonl"

def main():
    try:
        import tiktoken
    except ImportError:
        print("Error: tiktoken not installed. Run 'pip install tiktoken'")
        sys.exit(1)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        for text in CASES:
            for model_name, encoding_name in MODELS:
                try:
                    enc = tiktoken.get_encoding(encoding_name)
                    # We use encode_ordinary to simulate "text that happens to contain special tokens"
                    # being treated as text, or strictly standard text.
                    # Our Zig engine .ordinary mode matches encode_ordinary.
                    tokens = enc.encode_ordinary(text)

                    record = {
                        "model": model_name,
                        "encoding": encoding_name,
                        "text": text,
                        "tokens": tokens,
                        "count": len(tokens)
                    }
                    f.write(json.dumps(record, ensure_ascii=False) + "\n")
                except Exception as e:
                    print(f"Failed to encode '{text}' for {model_name}: {e}")

    print(f"Generated {len(CASES) * len(MODELS)} records in {OUTPUT_FILE}")

if __name__ == "__main__":
    main()
