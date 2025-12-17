# Tokenizer Audit Checklist & Invariants

This document defines the critical invariants, safety checks, and performance tripwires for the `llm-cost` tokenizer implementation. Use this checklist when modifying the vocabulary loader, BPE logic, or scanner.

## A. Asset Invariants (vocab.bin)

**Header & Layout**
- [x] **Magic**: Must be `"BPE2"` (4 bytes).
- [x] **Version**: Must be `2` (u32 little-endian).
- [x] **Size Check**: `data.len` must be `>= 64 + token_count*8 + blob_size`.
- [x] **Reserved**: Bytes 52..64 must be 0.
- [x] **Sanity**: `token_count > 0`, `blob_size > 0`, `max_token_len > 0`.

**Token Table Correctness**
- [x] **Bounds**: For every non-empty token: `offset + length <= blob_size`.
- [x] **Length Limit**: `length <= max_token_len`.

**Byte-Token Completeness (Critical)**
- [x] **Completeness**: All 256 byte values (0..255) must exist as mapped tokens.
- [x] **Exactness**: `getBytes(byte_to_token[b])` must be exactly `[1]u8{b}`.

## B. Merge Lookup Correctness & Safety
- [x] **Scratch Size**: `scratch.len >= max_token_len` (enforced at allocation).
- [x] **Bounds Check**: `lookup()` returns `null` if `total_len > scratch.len` (no OOB).
- [x] **No Stack Alloc**: Merges depend on heap-allocated scratch buffer (no 256-byte stack limits).
- [x] **No Alloc Per Call**: `lookup()` reuses the scratch buffer.

## C. Pre-tokenizer / Scanner Invariants (cl100k / o200k)
- [ ] **Forward Progress**: Every loop iteration must consume ≥1 byte.
- [ ] **UTF-8 Robustness**: Invalid UTF-8 must not cause infinite loops.
- [ ] **Branch Order**: Contractions processed before words, etc. (matching `tiktoken` regex).
- [ ] **Splitting**: Newline/whitespace branches must not overlap incorrectly.

## D. Engine Integration Invariants
- [x] **Arena Reset**: `ArenaAllocator` reset per chunk in `count`/`encode`.
- [x] **Scratch Lifecycle**: Allocated once per `encode`/`count` call, freed at end.
- [x] **Memory Growth**: No O(N) retention of temporary structs.
- [x] **Approximate Mode**: Only enabled if explicit; otherwise hard fail on missing vocab.

## E. Runner / Parity Harness Tripwires
- [x] **Strict JSON**: Tokens array must be integers.
- [x] **Diagnostics**: Reports mismatch index and explicit "expected/actual ended".
- [x] **Safety**: Output text is escaped and truncated.
- [x] **Exit Code**: Non-zero exit on failure.

## F. Fuzzing Hooks (Property Tests)

**1. Scanner Fuzz**
- **Goal**: No crash, infinite loop, or data loss.
- **Properties**:
    - `tokenize()` always terminates.
    - Sum of `token.text.len` == `input.len`.
    - No token has `len == 0`.
    - Tokens are valid slices of input.

**2. Vocab Loader Fuzz**
- **Goal**: Corrupt data yields clear error, never crash/UB.
- **Properties**:
    - Random/truncated inputs return `error.*`.
    - Valid loads yield valid pointers (within blob).

**3. Encode Fuzz**
- **Goal**: End-to-end stability.
- **Properties**:
    - `encode(text)` terminates.
    - `output_tokens.len < input.len` (generally, but specifically valid IDs).

## G. Performance Tripwires (Microbenchmarks)
- [ ] **Worst-case Merge**: Linear runtime on repeated bytes/patterns.
- [ ] **Memory Ceiling**: RSS stable/proportional on 10MB+ inputs.
