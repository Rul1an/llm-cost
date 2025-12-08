#!/usr/bin/env python3
import base64
import tiktoken
import sys

# Format must match tools/convert_vocab.zig expectation:
# <base64_token> <space> <rank>

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 dump_cl100k_vocab.py <output_file>")
        sys.exit(1)

    output_path = sys.argv[1]

    try:
        enc = tiktoken.get_encoding("cl100k_base")
    except Exception as e:
        print(f"Error loading cl100k_base: {e}")
        sys.exit(1)

    print(f"tiktoken version: {getattr(tiktoken, '__version__', 'unknown')}")

    # tiktoken ._mergeable_ranks is a dict of {bytes: rank}
    # We sort by rank to ensure deterministic order (and convert_vocab expects somewhat sorted input for efficiency maybe?
    # Actually convert_vocab sorts internally, but good practice).
    sorted_items = sorted(enc._mergeable_ranks.items(), key=lambda item: item[1])

    print(f"Dumping {len(sorted_items)} items from cl100k_base to {output_path}...")

    with open(output_path, "wb") as f:
        for token_bytes, rank in sorted_items:
            b64_token = base64.b64encode(token_bytes)
            # Write bytes directly
            f.write(b64_token)
            f.write(b" ")
            f.write(str(rank).encode("ascii"))
            f.write(b"\n")

    print("Done.")

if __name__ == "__main__":
    main()
