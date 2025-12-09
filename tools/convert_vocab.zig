const std = @import("std");

// --- Output Binary Format ---
// Layout:
// [Header]
// [IndexEntry * count]         (Sorted by token bytes)
// [String Data Blob]

const MAGIC: u32 = 0xAABBCCDD;

const Header = extern struct {
    magic: u32,
    count: u32,
    strings_len: u32,
    // data_offset calculated implicitly as sizeof(Header) + count * sizeof(IndexEntry) (+ alignment padding if any)
};

const IndexEntry = extern struct {
    offset: u32,
    rank: u32,
    len: u16,
    // 10 bytes packed.
    // We might want alignment, but packed is fine for disk format if we read carefully.
    // Actually for mmap/embed usage, aligned structs are better.
    // Let's use u32 for everything to be safe and C-like cache friendly (AES).
    // offset(4), rank(4), len(4) = 12 bytes. Nice stride.
};

const IndexEntryAligned = extern struct {
    offset: u32,
    rank: u32,
    len: u32,
};

// --- Intermediate representation for sorting ---
const VocabItem = struct {
    token: []const u8,
    rank: u32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 3) {
        std.debug.print("Usage: {s} <input.tiktoken> <output.bin>\n", .{args[0]});
        return;
    }

    const in_path = args[1];
    const out_path = args[2];

    std.debug.print("Reading {s}...\n", .{in_path});

    // 1. Read all items
    var items = try std.ArrayList(VocabItem).initCapacity(alloc, 200500);
    defer items.deinit();

    // We need an arena for the token strings we decode
    var string_arena = std.heap.ArenaAllocator.init(alloc);
    defer string_arena.deinit();
    const str_alloc = string_arena.allocator();

    const in_file = try std.fs.cwd().openFile(in_path, .{});
    defer in_file.close();

    const file_content = try in_file.readToEndAlloc(alloc, 20_000_000);
    defer alloc.free(file_content);

    var count: usize = 0;
    var line_it = std.mem.splitScalar(u8, file_content, '\n');

    while (line_it.next()) |line| {
        if (line.len == 0) continue;

        // Line format: <base64_token> <space> <rank>
        var it = std.mem.splitScalar(u8, line, ' ');
        const b64 = it.next() orelse continue;
        const rank_str = it.next() orelse continue;

        const rank = std.fmt.parseInt(u32, rank_str, 10) catch continue;

        // Decode base64
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
        const decoded = try str_alloc.alloc(u8, decoded_len);
        try std.base64.standard.Decoder.decode(decoded, b64);

        try items.append(VocabItem{ .token = decoded, .rank = rank });
        count += 1;
    }
    std.debug.print("Loaded {d} items. Sorting...\n", .{items.items.len});

    // 2. Sort by token content (for binary search)
    std.mem.sort(VocabItem, items.items, {}, sortVocab);

    // 3. Write binary (Header -> Index -> Strings)
    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();

    var writer = BufferedWriter.init(out_file);

    var strings_len: u32 = 0;
    for (items.items) |item| {
        strings_len += @as(u32, @intCast(item.token.len));
    }

    const header = Header{
        .magic = MAGIC,
        .count = @as(u32, @intCast(items.items.len)),
        .strings_len = strings_len,
    };

    try writer.writeAll(std.mem.asBytes(&header));

    // Write Index
    var current_offset: u32 = 0;
    for (items.items) |item| {
        const entry = IndexEntryAligned{
            .offset = current_offset,
            .rank = item.rank,
            .len = @as(u32, @intCast(item.token.len)),
        };
        try writer.writeAll(std.mem.asBytes(&entry));
        current_offset += entry.len;
    }

    // Write Strings
    for (items.items) |item| {
        try writer.writeAll(item.token);
    }

    try writer.flush();
    std.debug.print("Done. Wrote to {s}\n", .{out_path});
}

const BufferedWriter = struct {
    file: std.fs.File,
    buf: [65536]u8 = undefined,
    index: usize = 0,

    pub fn init(file: std.fs.File) BufferedWriter {
        return .{ .file = file };
    }

    pub fn writeAll(self: *BufferedWriter, data: []const u8) !void {
        var data_idx: usize = 0;
        while (data_idx < data.len) {
            const space = self.buf.len - self.index;
            const copylen = @min(space, data.len - data_idx);

            @memcpy(self.buf[self.index..][0..copylen], data[data_idx..][0..copylen]);
            self.index += copylen;
            data_idx += copylen;

            if (self.index == self.buf.len) {
                try self.flush();
            }
        }
    }

    pub fn flush(self: *BufferedWriter) !void {
        if (self.index > 0) {
            try self.file.writeAll(self.buf[0..self.index]);
            self.index = 0;
        }
    }
};

fn sortVocab(_: void, a: VocabItem, b: VocabItem) bool {
    return std.mem.lessThan(u8, a.token, b.token);
}
