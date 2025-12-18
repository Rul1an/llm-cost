const std = @import("std");
const schema = @import("schema.zig"); // For PriceDef types

pub const MAGIC = "COST";
pub const VERSION: u32 = 1;

pub const HEADER_SIZE: usize = 64;
pub const RECORD_SIZE: usize = 64;

// Offsets within a Record (bytes)
const OFF_HASH: usize = 0;
const OFF_MODEL_STR: usize = 8;
const OFF_PROV_STR: usize = 12;
const OFF_INPUT: usize = 16;
const OFF_OUTPUT: usize = 24;
const OFF_CTX: usize = 32;
const OFF_MAX_OUT: usize = 36;
const OFF_FLAGS: usize = 40;

pub const ValidationErr = error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    InvalidOffsets,
    ChecksumMismatch, // optional check
};

pub const PAGE_SIZE = 4096;

pub const BinaryView = struct {
    data: []align(PAGE_SIZE) const u8,

    // Parsed from header for quick access
    record_count: u32,
    string_table_offset: u32,
    created_timestamp: u64,
    source_checksum: u64,

    pub fn init(data: []align(PAGE_SIZE) const u8) ValidationErr!BinaryView {
        if (data.len < HEADER_SIZE) return error.Truncated;

        // 1. Header Validation
        const magic = data[0..4];
        if (!std.mem.eql(u8, magic, MAGIC)) return error.InvalidMagic;

        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != VERSION) return error.UnsupportedVersion;

        const created = std.mem.readInt(u64, data[8..16], .little);
        const count = std.mem.readInt(u32, data[16..20], .little);
        const str_offset = std.mem.readInt(u32, data[20..24], .little);
        const checksum = std.mem.readInt(u64, data[24..32], .little);

        // 2. Bounds Check
        // Strict overflow check: count * RECORD_SIZE
        const records_bytes = std.math.mul(usize, @as(usize, count), RECORD_SIZE) catch return error.InvalidOffsets;

        // P1: Hardening - Bounds Check
        // Header + Records must not exceed String Table start
        if (HEADER_SIZE + records_bytes > str_offset) return error.InvalidOffsets;

        // String Table start must be within file
        if (str_offset > data.len) return error.Truncated;

        return BinaryView{
            .data = data,
            .record_count = count,
            .string_table_offset = str_offset,
            .created_timestamp = created,
            .source_checksum = checksum,
        };
    }

    pub fn lookup(self: BinaryView, model_id: []const u8) ?schema.PriceDef {
        const hash = std.hash.Wyhash.hash(0, model_id);

        var left: usize = 0;
        var right: usize = @as(usize, self.record_count);

        while (left < right) {
            const mid = left + (right - left) / 2;
            const rec_hash = self.readRecordHash(mid);

            switch (std.math.order(hash, rec_hash)) {
                .lt => right = mid,
                .gt => left = mid + 1,
                .eq => {
                    // Match. Validate String.
                    if (self.matchesId(mid, model_id)) {
                        return self.readRecord(mid);
                    }
                    // Handle Collisions: Scan left then right
                    var i = mid;
                    while (i > 0) {
                        i -= 1;
                        if (self.readRecordHash(i) != hash) break;
                        if (self.matchesId(i, model_id)) return self.readRecord(i);
                    }
                    i = mid + 1;
                    while (i < @as(usize, self.record_count)) {
                        if (self.readRecordHash(i) != hash) break;
                        if (self.matchesId(i, model_id)) return self.readRecord(i);
                        i += 1;
                    }
                    return null;
                },
            }
        }
        return null;
    }

    // Unsafe internal helpers (bounds checked by init + indices < record_count)

    fn getRecordStart(self: BinaryView, index: usize) usize {
        _ = self;
        return HEADER_SIZE + (index * RECORD_SIZE);
    }

    fn readIntAt(self: BinaryView, comptime T: type, offset: usize) T {
        // Safe because init checked bounds for records, and header is safe.
        // Assuming offset + size <= len.
        const size = @divExact(@typeInfo(T).int.bits, 8);
        const ptr = self.data.ptr + offset;
        const array_ptr = @as(*const [size]u8, @ptrCast(ptr));
        return std.mem.readInt(T, array_ptr, .little);
    }

    fn readRecordHash(self: BinaryView, index: usize) u64 {
        const start = self.getRecordStart(index);
        return self.readIntAt(u64, start + OFF_HASH);
    }

    fn matchesId(self: BinaryView, index: usize, model_id: []const u8) bool {
        const start = self.getRecordStart(index);
        const str_off = self.readIntAt(u32, start + OFF_MODEL_STR);
        const str = self.getString(str_off);
        return std.mem.eql(u8, str, model_id);
    }

    fn getString(self: BinaryView, offset: u32) []const u8 {
        // P1 Hardening: Enforce offset is within String Table region
        if (offset < self.string_table_offset) return "";
        if (offset >= self.data.len) return "";

        // Find null
        const ptr = self.data.ptr + offset;
        // P1 Hardening: Null terminator mandatory
        const len = std.mem.indexOfScalar(u8, self.data[offset..], 0) orelse return "";
        return ptr[0..len];
    }

    fn readRecord(self: BinaryView, index: usize) schema.PriceDef {
        const start = self.getRecordStart(index);

        const prov_off = self.readIntAt(u32, start + OFF_PROV_STR);
        const input = self.readIntAt(i64, start + OFF_INPUT);
        const output = self.readIntAt(i64, start + OFF_OUTPUT);
        const ctx = self.readIntAt(u32, start + OFF_CTX);
        // Flags/MaxOut unused for Cost Calc currently but available

        const p_str = self.getString(prov_off);

        // Using i128 MicroUsd directly from i64
        return schema.PriceDef{
            .provider = schema.Provider.fromString(p_str),
            .input_price_per_mtok = @intCast(input),
            .output_price_per_mtok = @intCast(output),
            .output_reasoning_price_per_mtok = 0,
            .cache_read_price_per_mtok = 0,
            .cache_write_price_per_mtok = 0,
            .context_window = ctx,
        };
    }

    // Iterator Interface for Registry
    pub const Iterator = struct {
        view: BinaryView,
        idx: usize = 0,

        pub const Entry = struct {
            key: []const u8,
            value: schema.PriceDef,
        };

        pub fn next(self: *Iterator) ?Entry {
            while (self.idx < @as(usize, self.view.record_count)) {
                const i = self.idx;
                self.idx += 1;

                const start = self.view.getRecordStart(i);
                const str_off = std.mem.readInt(u32, self.view.data[start + OFF_MODEL_STR ..][0..4], .little);
                const key = self.view.getString(str_off);

                // P1 Hardening: Skip invalid/empty keys
                if (key.len == 0) continue;

                const val = self.view.readRecord(i);
                return Entry{ .key = key, .value = val };
            }
            return null;
        }
    };

    pub fn iterator(self: BinaryView) Iterator {
        return Iterator{ .view = self };
    }
};
