# llm-cost Vocabulary Binary Format v2

## Design Principles

1. **Alignment-safe**: No packed structs, use explicit byte reads
2. **Zero-copy friendly**: Token strings reference embedded blob directly
3. **Verification**: SHA256 hash of source .tiktoken file embedded
4. **Simple**: No separate merge table (tiktoken doesn't have one)

## Tiktoken Ground Truth

The `.tiktoken` file format is simply:
```
<base64-token-bytes> <rank>\n
<base64-token-bytes> <rank>\n
...
```

Where `rank` = token ID. Lower rank = higher BPE merge priority.

BPE merging is **implicit**: if `bytes(token_A) ++ bytes(token_B)` exists 
in the vocabulary, and its rank is lower than both A and B, then merge.

## Binary Layout

```
┌─────────────────────────────────────────────────────────────┐
│ HEADER (64 bytes, fixed)                                    │
├─────────────────────────────────────────────────────────────┤
│ magic         [4]u8    = "BPE2"                             │
│ version       u32      = 2 (little-endian)                  │
│ token_count   u32      = number of tokens                   │
│ max_token_len u32      = longest token in bytes             │
│ blob_size     u32      = size of token_bytes section        │
│ source_hash   [32]u8   = SHA256 of source .tiktoken file    │
│ reserved      [12]u8   = zeros (future use)                 │
├─────────────────────────────────────────────────────────────┤
│ TOKEN TABLE (token_count * 8 bytes)                         │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ For each token (sorted by rank/ID):                     │ │
│ │   offset    u32   = offset into token_bytes             │ │
│ │   length    u32   = length in bytes                     │ │
│ └─────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│ TOKEN BYTES (blob_size bytes)                               │
│ All token byte sequences concatenated                       │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### Why no separate merge table?

Tiktoken's BPE algorithm doesn't use a precomputed merge table.
Instead, it does:

```python
def get_merge_rank(token_a_bytes, token_b_bytes):
    merged = token_a_bytes + token_b_bytes
    return vocab.get(merged, infinity)  # lookup in vocab
```

So we only need a `bytes -> rank` lookup (our StringHashMap).

### Why u32 for offsets/lengths?

- cl100k_base: ~100K tokens, max ~50 bytes per token
- o200k_base: ~200K tokens, max ~50 bytes per token
- Total blob size: ~5MB max
- u32 is plenty (4GB limit)

### Why sorted by rank?

Rank = token ID. Sorting by rank means:
- token_table[rank] gives you the token for that rank
- O(1) decode: rank → bytes
- The encoder still uses StringHashMap for bytes → rank

### Alignment Safety

All reads use `std.mem.readInt` instead of pointer casts:

```zig
// ✅ CORRECT - alignment-safe
const token_count = std.mem.readInt(u32, blob[8..12], .little);

// ❌ WRONG - UB if blob not aligned
const token_count = @as(*const u32, @ptrCast(blob.ptr + 8)).*;
```

## File Sizes (Expected)

| Encoding    | Tokens  | Est. Size |
|-------------|---------|-----------|
| cl100k_base | 100,256 | ~1.8 MB   |
| o200k_base  | 199,998 | ~3.5 MB   |

## Verification

The `source_hash` field contains SHA256 of the original .tiktoken file.
This enables:

1. CI check that .bin matches source
2. Reproducible builds
3. Detection of vocab updates

## Special Tokens

Special tokens (like `<|im_start|>`) are included in the main token table
with their assigned ranks. They're distinguished by:

1. Their byte sequence (contains `<|` and `|>`)
2. Their high ranks (typically > 100000 for cl100k)

The pre-tokenizer handles special token detection before BPE.

## Compression (Future)

The format supports future compression via:
- Magic changing to "BPZ2" (zstd compressed)
- Adding `compressed_size` field in reserved space
- Decompressing on load into arena allocator

For now, uncompressed is fine (~1.8MB for cl100k is acceptable).
