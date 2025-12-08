const std = @import("std");

/// The binary file layout (Must match tools/convert_vocab.zig)
const Header = extern struct {
    magic: u32,
    count: u32,
    strings_len: u32,
};

const IndexEntry = extern struct {
    offset: u32,
    rank: u32,
    len: u32,
};

/// Zero-copy BPE Tokenizer Engine
pub const BpeEngine = struct {
    index: []const IndexEntry,
    string_blob: []const u8,

    /// Initialize from raw embedded bytes
    pub fn init(embedded_data: []const u8) !BpeEngine {
        if (embedded_data.len < @sizeOf(Header)) return error.InvalidData;

        // Read header
        const header = std.mem.bytesToValue(Header, embedded_data[0..@sizeOf(Header)]);

        if (header.magic != 0xAABBCCDD) return error.InvalidMagic;

        const index_start = @sizeOf(Header);
        // Cast header.count to avoid overflow risk in calculation, though typically safe
        const index_size = @as(usize, @intCast(header.count)) * @sizeOf(IndexEntry);

        if (embedded_data.len < index_start + index_size) return error.TruncatedData;

        const index_bytes = embedded_data[index_start .. index_start + index_size];

        // Manual pointer cast to avoid []align(1) mismatch
        // We assume the embedded data has sufficient alignment (usually 16 or 4).
        // If embedded_data is only align(1), @alignCast might fail at runtime if not actually aligned!
        // However, standard allocators/embeds are usually aligned.
        const index_ptr: [*]const IndexEntry = @ptrCast(@alignCast(index_bytes.ptr));
        const index = index_ptr[0 .. header.count];

        const strings_start = index_start + index_size;
        if (embedded_data.len < strings_start + header.strings_len) return error.TruncatedStrings;

        const string_blob = embedded_data[strings_start .. strings_start + header.strings_len];

        return BpeEngine{
            .index = index,
            .string_blob = string_blob,
        };
    }

    /// O(log N) lookup. Returns Rank.
    pub fn getRank(self: BpeEngine, token: []const u8) ?u32 {
        const Context = struct {
            blob: []const u8,

            pub fn compare(ctx: @This(), key: []const u8, entry: IndexEntry) std.math.Order {
                const entry_str = ctx.blob[entry.offset .. entry.offset + entry.len];
                return std.mem.order(u8, key, entry_str);
            }
        };

        const ctx = Context{ .blob = self.string_blob };

        // Zero-allocation binary search
        const idx = std.sort.binarySearch(
            IndexEntry,
            token,
            self.index,
            ctx,
            Context.compare
        );

        if (idx) |i| {
            return self.index[i].rank;
        }
        return null;
    }

    /// Helper to find token by rank (O(N) - slow, for debugging)
    /// Not strictly needed for encoding, usually needed for decoding.
    pub fn getToken(self: BpeEngine, rank: u32) ?[]const u8 {
        // Since we sort by Token, we can't binary search by Rank.
        // If we need fast decode, we need a second index (Rank -> Token).
        // For 'llm-cost', we only need encoding (count).
        // If debug printing is needed, linear scan is acceptable for v0.1.
        for (self.index) |entry| {
            if (entry.rank == rank) {
                return self.string_blob[entry.offset .. entry.offset + entry.len];
            }
        }
        return null;
    }

    // --- Encoding Logic ---

    /// Simplified GPT-4o pre-tokenizer (split words).
    /// Returns a slice of the text for the next "word".
    /// Updates `start_idx`.
    fn nextWord(_: BpeEngine, text: []const u8, start_idx: *usize) ?[]const u8 {
        if (start_idx.* >= text.len) return null;

        const start = start_idx.*;
        var end = start;

        // Simple approximate scanner:
        // 1. Eat whitespace? GPT preserves whitespace attached to words often.
        // Rule: Usually ` ?\p{L}+` (optional space + letters).

        const c = text[end];

        if (std.ascii.isWhitespace(c)) {
            // Consume sequence of whitespace
            while (end < text.len and std.ascii.isWhitespace(text[end])) : (end += 1) {}
            // In GPT, pure whitespace sequences are often separate tokens or prefixes?
            // Actually `\s+(?!\S)` is trailing space.
            // Let's return the whitespace chunk.
        } else if (std.ascii.isAlphabetic(c)) {
            // Consume letters
             while (end < text.len and std.ascii.isAlphabetic(text[end])) : (end += 1) {}
        } else if (std.ascii.isDigit(c)) {
             while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        } else {
            // Punctuation / other: 1 char
            end += 1;
        }

        start_idx.* = end;
        return text[start..end];
    }

    /// Encode pre-tokenized text segments.
    /// Caller owns result slice.
    pub fn encode(self: BpeEngine, alloc: std.mem.Allocator, pre_tokens: []const @import("pre_tokenizer.zig").PreToken) ![]u32 {
        var tokens = std.ArrayList(u32).init(alloc);
        errdefer tokens.deinit();

        for (pre_tokens) |pt| {
            // TODO: Special token handling
            try self.encodeWord(pt.text, &tokens);
        }

        return tokens.toOwnedSlice();
    }

    /// Core BPE Merge for a single word
    fn encodeWord(self: BpeEngine, word: []const u8, output: *std.ArrayList(u32)) !void {
        // 1. Initial breakdown: every byte is a token?
        // Actually GPT-4o is byte-level BPE.
        // We start by mapping each byte/char to a token rank if possible, or byte fallback.
        // For simplicity v0.1: Treating bytes as u8.
        // But `o200k_base` has tokens for common bytes.
        // Strategy:
        //  - Start with list of "parts" (each byte as a separate part).
        //  - Loop:
        //     Find pair (parts[i], parts[i+1]) with min Rank.
        //     If no pair found in map, stop.
        //     Merge -> parts[i] = merged key, remove parts[i+1].

        // Use a small scratch ArrayList for the parts.
        // Each part is a slice of `word`.
        // Optimisation: linked list or array list?
        // Word length is usually small. ArrayList is fine.

        // Parts: list of slices.
        // Ranks: Cache rank for the part?
        // Actually we need to find pairs.

        // Optimization: For long words, this is slow. But "nextWord" keeps them naturally small.

        // A part is just a range start/len in the word, OR a combined token?
        // Actually, we are merging bytes.
        // "parts" are indices into the word? No, BPE can merge disjoint things?
        // No, BPE is strictly adjacent merges.
        // So `parts` is a list of sub-slices of `word`.

        // 1. Init parts = [ word[0..1], word[1..2], ... ]
        var parts = std.ArrayList([]const u8).init(output.allocator);
        defer parts.deinit();

        for (0..word.len) |i| {
            try parts.append(word[i..i+1]);
        }

        // BPE Loop
        while (parts.items.len > 1) {
            var min_rank: u32 = std.math.maxInt(u32);
            var best_idx: ?usize = null;
            var best_token: ?u32 = null; // The rank of the combined pair if merged

            // Find best pair
            for (0..parts.items.len - 1) |i| {
                const p1 = parts.items[i];
                const p2 = parts.items[i+1];

                // Construct merged key
                // Note: This requires allocation or stack buffer.
                // Max token length?
                // We can use a small buffer. If pair > buffer, it's unlikely a token?
                // Tokens can be long.
                // We use an allocator for the check?
                // Or just `p1` and `p2` are slices of `word`... wait!
                // If we merge 'a' and 'b' -> 'ab', 'ab' is slice of word[0..2].
                // Yes! Because BPE merges adjacency, the result is ALWAYS a contiguous slice of the original word!
                // Proof: (i..j) merged with (j..k) -> (i..k).
                // So we never need to allocate strings, just merge slices!
                // UNLESS `parts` are tokens that are NOT slices of original (e.g. byte fallbacks?).
                // For GPT-2/3/4 byte-level BPE, this holds true for the UTF-8 bytes.

                // So:
                const merged_len = p1.len + p2.len;
                // Since they are adjacent in the list, are they adjacent in memory?
                // Initially yes. After merges?
                // [a] [b] [c] -> merge a,b -> [ab] [c]. 'ab' is contiguous.
                // [ab] [c] -> merge ab, c -> [abc]. 'abc' is contiguous.
                // So yes, `merged` is always a slice of `word`.
                // We can assume `p1.ptr` + `p1.len` == `p2.ptr`.

                // Safely recreate the slice
                const merged_slice = p1.ptr[0..merged_len];

                if (self.getRank(merged_slice)) |r| {
                    if (r < min_rank) {
                        min_rank = r;
                        best_idx = i;
                        best_token = r;
                    }
                }
            }

            if (best_idx) |idx| {
                // Merge parts[idx] and parts[idx+1]
                const p1 = parts.items[idx];
                const p2 = parts.items[idx+1];
                const merged = p1.ptr[0 .. p1.len + p2.len];

                parts.items[idx] = merged;
                _ = parts.orderedRemove(idx + 1);
            } else {
                break; // No mergeable pairs found
            }
        }

        // Output tokens
        for (parts.items) |part| {
            if (self.getRank(part)) |r| {
                try output.append(r);
            } else {
                // Unknown token? Fallback?
                // In GPT-4o everything should be covered by byte tokens at least?
                // Or we emit UNK?
                // For estimation, we count 1.
                // But we should try to append *something*.
                // "Byte fallback" means every byte has a rank.
                // If getRank returns null for a single byte, something is wrong with our data or map.
                // We will assume 0 or UNK for now.
                // Actually `getRank` returning null for single byte is possible if not in vocab.
                // But o200k usually covers all bytes.
                try output.append(0); // Placeholder
            }
        }
    }
};
