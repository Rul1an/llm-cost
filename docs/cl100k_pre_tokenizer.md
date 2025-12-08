# cl100k Pre-Tokenizer Specification

This document defines the pre-tokenization logic for the `cl100k_base` encoding (used by GPT-4, GPT-3.5-turbo, text-embedding-ada-002).
The behavior is based on the official `tiktoken` regex pattern (from `tiktoken_ext/openai_public.py`).

## Regex Pattern

The core regex is:
```regex
'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+
```

## Branch Breakdown & Priority

The scanner matches these branches in order (left-to-right priority).

### 1. Contractions
**Regex**: `'(?i:[sdmt]|ll|ve|re)`
*   Matches strict case-insensitive english contractions.
*   **Examples**: `'s`, `'T`, `'re`, `'LL`.

### 2. Words (Letters)
**Regex**: `[^\r\n\p{L}\p{N}]?\p{L}+`
*   **Prefix**: Optional 1 char. NOT CR, LF, Letter, Number.
*   **Body**: 1+ characters of Letter (`\p{L}`). NO Numbers.
*   **Examples**: ` hello`, ` World`, ` partial` (in `partial123`).

### 3. Numbers
**Regex**: `\p{N}{1,3}`
*   **No Prefix**.
*   **Body**: 1 to 3 numeric digits (`\p{N}`).
*   **Examples**: `1`, `12`, `123`. `1234` becomes `123`, `4`.

### 4. Punctuation
**Regex**: ` ?[^\s\p{L}\p{N}]+[\r\n]*`
*   **Prefix**: Optional 1 Space (` `).
*   **Body**: 1+ characters that are NOT Whitespace, Letter, or Number.
*   **Suffix**: Optional run of `\r` or `\n`.
*   **Examples**: `!`, ` ...`, ` !!\n`.

### 5. Whitespace (Newline)
**Regex**: `\s*[\r\n]` (Note: `tiktoken` regex uses `[\r\n]`, not `[\r\n]+`, but effective behavior in a loop might cover runs if `\s*` subsumes previous newlines. We standardize on `\s*[\r\n]+` or the o200k logic which is behaviorally compatible).
*   Matches whitespace that ends in at least one CR or LF.

### 6. Whitespace (Trailing)
**Regex**: `\s+(?!\S)`
*   Matches whitespace only if matched to End of String (EOF).

### 7. Whitespace (Generic)
**Regex**: `\s+`
*   Matches any remaining run of whitespace.

## Data Structure Implications
*   `cl100k` strictly separates Letters and Numbers. `o200k` did too, but `cl100k` does NOT have any "Alphanumeric" word concept in the pre-tokenizer.
*   `cl100k` treats `1234` as multiple tokens (Pre-Tokenization split).
