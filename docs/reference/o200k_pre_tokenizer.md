# o200k_base Pre-Tokenizer Design

**Status**: Draft
**Target**: `src/tokenizer/o200k_scanner.zig`
**Context**: Replaces generic regex engine with a model-specific scanner for performance and parity.

## The Regex
The source pattern for `o200k_base` (from tiktoken) is:
```regex
[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lt}\p{Lm}\p{Lo}\p{M}]+
|
[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+(?=[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]|\s|\p{P}|\p{S}|\p{C}|$)
|
\p{N}{1,3}
|
 ?[^\s\p{L}\p{N}]+[\r\n/]*
|
\s*[\r\n]+
|
\s+(?!\S)
|
\s+
```

## Branch Decomposition
The scanner attempts to match the following branches in order. The first match consumes input.

## Branch Decomposition & Priority
The scanner **MUST** mimic Rust regex semantics: "leftmost-first".
At strict current position, branches are tried in **pattern order**. The first branch that matches consumes input.
We do NOT search for the longest match across branches.

### Branch 1: "Words ending with lowercase/other"
**Regex**: `[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lt}\p{Lm}\p{Lo}\p{M}]+`

*   **Prefix**: Optional non-letter/number/newline (e.g., punct). `[^\r\n\p{L}\p{N}]?`
*   **Body**: Optional sequence of "Uppercase-ish" (Lu/Lt/Lm/Lo/M).
*   **Suffix**: REQUIRED sequence of "Lowercase-ish" (Ll/Lt/Lm/Lo/M).

*Strategy*:
1. Scan optional prefix.
2. Scan potential body.
3. Verify strict suffix requirement. If suffix missing, branch fails (backtrack to start).

### Branch 2: "Words (Uppercase) with Lookahead"
**Regex**: `[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+(?=[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]|\s|\p{P}|\p{S}|\p{C}|$)`

*   **Prefix**: Same optional as Branch 1.
*   **Body**: REQUIRED "Uppercase-ish" sequence.
*   **Lookahead**: Must be followed by Letter/Mark OR Whitespace OR Punctuation OR Symbol OR Control OR EOF.

*Priority*: Only tried if Branch 1 failed.

### Branch 3: "Numbers"
**Regex**: `\p{N}{1,3}`

*   **Body**: 1 to 3 numeric characters.
*   **Semantics**: Splits long numbers into chunks of 3 ("123456" -> "123", "456").
*   **Implementation**: Greedy within the {1,3} range, but iterative scan means subsequent digits become next token.

### Branch 4: "Everything Else (Punctuation/Symbols)"
**Regex**: ` ?[^\s\p{L}\p{N}]+[\r\n/]*`

*   **Prefix**: Optional space.
*   **Body**: 1+ Non-Whitespace/Letter/Number marks.
*   **Suffix**: Optional run of newlines OR slashes `[\r\n/]*`.
    *   *Note*: This suffix consumes trailing newlines, possibly preempting Branch 5 if triggered.

### Branch 5: "Newlines"
**Regex**: `\s*[\r\n]+`

*   **Body**: Whitespace sequence ending in newline(s).
*   **Constraint**: Must contain at least one `\r` or `\n`.

### Branch 6: "Trailing Whitespace"
**Regex**: `\s+(?!\S)`

*   **Body**: Whitespace run at the end of text (lookahead `(?!\S)` matches EOF).

### Branch 7: "Whitespace"
**Regex**: `\s+`

*   **Body**: Generic whitespace run.

## Scanner Algorithm (Zig)

```zig
pub fn next(text: []const u8) ?[]const u8 {
    // 1. Decode generic codepoint stats (isLetter, isNumber, etc.)
    // 2. Dispatch based on first char char-class to avoid trying all branches:
    //    - Letter/Mark -> Try Branch 1, then Branch 2.
    //    - Number -> Try Branch 3.
    //    - Whitespace -> Check for \r\n (Br 5) or EOF (Br 6), else Br 7.
    //    - Other -> Branch 4.
}
```

## Unicode Strategy
**Requirement**: Strict parity. "Approximate" ranges are unacceptable.
**Plan**:
1.  Generate static `Range` tables (`u21` start/end) from Unicode Database (`UnicodeData.txt`, `PropList.txt`).
2.  Implement `isLetter(u21)`, `isNumber(u21)`, etc. using binary search over these tables.
3.  Ensure category mappings match tiktoken's regex engine semantics (Perl/Rust style).

Categories required:
*   `\p{L}` (Letter)
*   `\p{N}` (Number)
*   `\p{Z}` / `\s` (Whitespace)
*   `\p{M}` (Mark)
*   `\p{P}` (Punctuation)
*   `\p{S}` (Symbol)
*   `\p{C}` (Control)
