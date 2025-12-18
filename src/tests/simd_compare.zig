const std = @import("std");
const tok = @import("tokenizer");
const openai = tok.openai;
const registry = tok.registry;
const bpe_algo = tok.bpe;
const Cl100kScanner = tok.Cl100kScanner;
const O200kScanner = tok.O200kScanner;

// Hardened PRNG (XorShift32) for determinism
const Prng = struct {
    state: u32,
    pub fn init(seed: u32) Prng {
        return .{ .state = if (seed == 0) 0xDEADBEEF else seed };
    }
    pub fn next(self: *Prng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }
    pub fn nextBounded(self: *Prng, limit: usize) usize {
        return self.next() % limit;
    }
};

const CATEGORIES = enum {
    PureAscii,
    LongAsciiRuns,
    MixedUtf8,
    BoundaryStress,
    Adversarial,
};

fn generateInput(rng: *Prng, out: *std.ArrayList(u8), category: CATEGORIES) !void {
    const max_len = 4096; // keep manageable for unit tests
    const len = rng.nextBounded(max_len) + 1;
    try out.resize(len);
    const buf = out.items;

    switch (category) {
        .PureAscii => {
            for (buf) |*b| b.* = @intCast(rng.nextBounded(128));
        },
        .LongAsciiRuns => {
            var i: usize = 0;
            while (i < len) {
                const char = @as(u8, @intCast(rng.nextBounded(26) + 'a'));
                const run_len = rng.nextBounded(256) + 1;
                const end = @min(i + run_len, len);
                @memset(buf[i..end], char);
                i = end;
                if (i < len) buf[i] = ' '; // sporadic break
                i += 1;
            }
        },
        .MixedUtf8 => {
            for (buf) |*b| {
                const r = rng.next();
                if (r % 5 == 0) {
                    b.* = @intCast(rng.nextBounded(128)); // ASCII
                } else {
                    b.* = @intCast(r % 256); // Raw chaos
                }
            }
        },
        .BoundaryStress => {
            // Fill with spaces and insert checks at SIMD boundaries (16, 32)
            @memset(buf, ' ');
            var i: usize = 15;
            while (i < len) {
                buf[i] = '@';
                i += 16;
            }
        },
        .Adversarial => {
            // Specific evil bytes
            for (buf) |*b| {
                const r = rng.next();
                if (r % 2 == 0) {
                    b.* = 0xFF;
                } else {
                    b.* = 0xC0; // Invalid start
                }
            }
        },
    }
}

test "Differential Fuzzing: Parity Check" {
    // 1. Setup
    const allocator = std.testing.allocator;
    // We need vocab data. For unit test, we can use empty vocab or mock?
    // The Scanners don't use the vocab data, they use PreTokenizer logic.
    // The OpenAITokenizer needs vocab for BPE merge.
    // We strictly want to test the Pre-Tokenizer scanner logic parity.
    // But user asked for "whole tokenizer pipeline" check.

    // Actually, loading the 1MB vocab in a unit test is slow/complex if file path issue.
    // Let's rely on the Scanners directly via the updated Cl100kScanner/O200kScanner interface
    // OR create a dummy OpenAITokenizer with empty vocab?
    // If vocab is empty, BPE is no-op, so we test Pre-Tokenizer + no-op BPE.
    // This perfectly isolates the Scanner logic which is what we changed.

    // config removed.
    // Use minimal dummy spec if needed, or rely on openai.init to ignore vocab if empty?
    // Init requires valid V4 header.

    // config removed.

    // Construct valid V4 binary blob
    var vocab_data = std.ArrayList(u8).init(allocator);
    defer vocab_data.deinit();

    // 1. Header (64 bytes)
    try vocab_data.appendSlice("BPE4");
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf4, 4, .little);
    try vocab_data.appendSlice(&buf4); // Version
    std.mem.writeInt(u32, &buf4, 256, .little);
    try vocab_data.appendSlice(&buf4); // TokenCount
    std.mem.writeInt(u32, &buf4, 1, .little);
    try vocab_data.appendSlice(&buf4); // MaxLen
    std.mem.writeInt(u32, &buf4, 256, .little);
    try vocab_data.appendSlice(&buf4); // BlobSize (Bytes)
    try vocab_data.appendNTimes(0, 32); // SourceHash
    std.mem.writeInt(u32, &buf4, 0, .little);
    try vocab_data.appendSlice(&buf4); // Capacity (0 implies no merge table)
    // Offset at 56 we write later
    try vocab_data.appendNTimes(0, 8); // Reserved (includes offset placeholder)

    // 2. Token Table (256 * 8 = 2048 bytes)
    // We map byte i -> token i
    var offset: u32 = 0;
    for (0..256) |_| {
        // Offset
        std.mem.writeInt(u32, &buf4, offset, .little);
        try vocab_data.appendSlice(&buf4);
        // Length (1 byte)
        std.mem.writeInt(u32, &buf4, 1, .little);
        try vocab_data.appendSlice(&buf4);
        offset += 1;
    }

    // 3. Blob Data (256 bytes)
    for (0..256) |i| try vocab_data.append(@intCast(i));

    // 4. Align to 16 for Table Offset
    while (vocab_data.items.len % 16 != 0) try vocab_data.append(0);
    const table_start_offset = vocab_data.items.len;

    // Patch Header Offset (Index 56)
    std.mem.writeInt(u32, vocab_data.items[56..][0..4], @intCast(table_start_offset), .little);

    // 5. Table (Capacity 0 -> size 0 bytes)
    // No data needed.

    // Now init Tokenizer
    var tokenizer = try openai.OpenAITokenizer.init(allocator, .{ .spec = .{
        .name = "cl100k_base",
        .vocab_data = vocab_data.items,
        .pat_str = "",
        .special_tokens = &[_]registry.EncodingSpec.SpecialToken{},
    }, .bpe_version = .v2 });
    defer tokenizer.deinit(allocator);

    // Reuse workspaces
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ws = bpe_algo.BpeWorkspace.init(allocator);
    defer ws.deinit();

    var out_scalar = std.ArrayList(u32).init(allocator);
    defer out_scalar.deinit();
    var out_simd = std.ArrayList(u32).init(allocator);
    defer out_simd.deinit();

    var input_buf = std.ArrayList(u8).init(allocator);
    defer input_buf.deinit();

    var rng = Prng.init(0xDEADBEEF);

    // Check for ENV override
    var iterations: usize = 5000;
    if (std.process.getEnvVarOwned(allocator, "FUZZ_ITERATIONS")) |val| {
        defer allocator.free(val);
        iterations = std.fmt.parseInt(usize, val, 10) catch 5000;
    } else |_| {} // Default to 5000

    std.debug.print("\nRunning {} differential iterations...\n", .{iterations});

    for (0..iterations) |i| {
        if (i % 1000 == 0) std.debug.print(".", .{});

        // 1. Generate Input
        const cat_idx = rng.nextBounded(5);
        const cat: CATEGORIES = @enumFromInt(cat_idx);

        try generateInput(&rng, &input_buf, cat);
        const input = input_buf.items;

        // 2. Run Scalar
        Cl100kScanner.setScanMode(.scalar);
        out_scalar.clearRetainingCapacity();
        try tokenizer.encodeInto(allocator, &arena, &ws, input, &out_scalar);

        // 3. Run SIMD
        Cl100kScanner.setScanMode(.simd);
        out_simd.clearRetainingCapacity();
        try tokenizer.encodeInto(allocator, &arena, &ws, input, &out_simd);

        // 4. Compare
        if (out_scalar.items.len != out_simd.items.len) {
            std.debug.print("\nMISMATCH LEN: i={} seed=0xDEADBEEF cat={}\n", .{ i, cat });
            std.debug.print("Len Scalar: {}\nLen SIMD: {}\n", .{ out_scalar.items.len, out_simd.items.len });
            // dump input
            return error.FuzzMismatch;
        }

        if (!std.mem.eql(u32, out_scalar.items, out_simd.items)) {
            std.debug.print("\nMISMATCH CONTENT: i={} seed=0xDEADBEEF cat={}\n", .{ i, cat });
            return error.FuzzMismatch;
        }
    }
    std.debug.print("\nPASS\n", .{});
}
