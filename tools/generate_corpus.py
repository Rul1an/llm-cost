import sys
import json
import tiktoken

def generate(output_path):
    enc_o200k = tiktoken.get_encoding("o200k_base")
    # enc_cl100k = tiktoken.get_encoding("cl100k_base") # Enable later

    # Test cases:
    # 1. Simple text
    # 2. Unicode
    # 3. Special tokens (if allowed)
    # 4. Whitespace weirdness
    inputs = [
        "Hello world",
        "Hello   world",
        "hello world",
        " The quick brown fox jumps over the lazy dog.",
        "äöüß",
        "😊",
        "data: [1, 2, 3]",
        "def foo(x):\n    return x + 1",
        "user@example.com",
        "1234567890",
        "     ",
        "\n\n\n",
    ]

    with open(output_path, "w") as f:
        for text in inputs:
            # o200k
            try:
                tokens = enc_o200k.encode(text)
                record = {
                    "text": text,
                    "model": "gpt-4o",
                    "encoding": "o200k_base",
                    "tokens": tokens,
                    "count": len(tokens)
                }
                f.write(json.dumps(record) + "\n")
            except Exception as e:
                print(f"Error encoding '{text}': {e}", file=sys.stderr)

    print(f"Generated {len(inputs)} records to {output_path}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python generate_corpus.py <output_file>")
        sys.exit(1)

    generate(sys.argv[1])
