import json
import os
import sys

try:
    import tiktoken
except ImportError:
    print("Error: tiktoken is not installed. Please run `pip install tiktoken`.")
    sys.exit(1)

OUTPUT_DIR = "testdata"
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "evil_corpus_v2.jsonl")

# Ensure output directory exists
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Models to generate data for
MODELS = ["o200k_base", "cl100k_base"]

def get_manual_cases():
    """Returns a list of edge-case strings to test."""
    cases = [
        # Basic
        "Hello world",
        "",
        " ",

        # Branch 1: Contractions (cl100k) / Words (o200k)
        "don't", "it's", "you're", "I'll", "we've",
        "'s", "'t", "'re", "'ve", "'m", "'ll", "'d",
        "It's", "DON'T", # Case sensitivity checks
        " 's", "foo's", # Space+Contraction, Word+Contraction edge cases

        # Branch 2: Words
        "hello", "Hello", "HELLO",
        "naïve", "über", "façade", # Unicode letters
        "مرحبا", "こんにちは", "안녕하세요", # Non-Latin scripts
        "unfinished", "prefix space",

        # Branch 3: Numbers
        "1", "12", "123", # 1-3 digits
        "1234", "12345", "123456", "1234567890", # Splitting behavior
        "0", "00", "007",

        # Branch 4: Punctuation
        "!", ".", "...", "??",
        " ! ", " ... ", # with spaces
        "////", # slashes (check cl100k vs o200k suffix)

        # Branch 5-7: Whitespace
        "\n", "\r", "\r\n", "\n\r",
        " \n ", " \r\n ",
        "   ", # multiple spaces
        "\t", # tab (usually punctuation or whitespace depending on model?)
        "\t\n", "\n\t", # Mixed whitespace edge cases (Branches 5/7)

        # Mixed / Adversarial
        "don't 123",
        "foo123bar",
        "123foo",
        " \r\n \t ",
        "user_name",
        "email@example.com",
        "1.2.3.4",
        "1,000",

        # Long runs
        "a" * 100,
        " " * 100,
        "!" * 100,
    ]
    return cases

def run():
    print(f"Generating Evil Corpus v2 to {OUTPUT_FILE}...")

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        cases = get_manual_cases()

        count = 0
        for text in cases:
            # We treat 'text' as the raw input string.
            for model_name in MODELS:
                try:
                    enc = tiktoken.get_encoding(model_name)
                    # Encode - Strict mode: no special tokens allowed in Evil Corpus
                    # allowed_special expects set or "all". set() is empty set.
                    # disallowed_special expects set or "all".
                    tokens = enc.encode(text, allowed_special=set(), disallowed_special="all")

                    # Create entry
                    entry = {
                        "model": model_name,
                        "text": text,
                        "expected_ids": tokens,
                        "tiktoken_version": tiktoken.__version__
                    }
                    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    count += 1
                except Exception as e:
                    print(f"Skipping model {model_name} for text '{text[:20]}...': {e}")

    print(f"Done. Generated {count} vectors.")

if __name__ == "__main__":
    run()
