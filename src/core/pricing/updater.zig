const std = @import("std");
const Manifest = @import("manifest.zig");
const UpdateState = @import("state.zig").UpdateState;
const fetcher = @import("fetcher.zig");
const atomic = @import("atomic.zig");
const paths = @import("paths.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const UpdateError = error{
    NetworkUnreachable,
    Timeout,
    ServerError,
    RateLimited,
    ManifestInvalid,
    ManifestExpired,
    ManifestRollback,
    SignatureInvalid,
    HashMismatch,
    DownloadFailed,
    InstallFailed,
    StateFailed,
    SchemaVersionMismatch,
    // FS
    AccessDenied,
    Unexpected,
    OutOfMemory,
};

pub const UpdateResult = union(enum) {
    success: struct {
        version: u64,
        model_count: ?u32,
    },
    already_current: void,
    failure: UpdateError,
};

pub const UpdateOptions = struct {
    endpoint: []const u8 = "https://api.llm-cost.dev/v1",
    auth_token: ?[]const u8 = null,
    force: bool = false,
    allow_downgrade: bool = false,
};

/// Check for updates and install if available.
pub fn checkAndUpdate(
    allocator: std.mem.Allocator,
    options: UpdateOptions,
    writer: anytype,
) !UpdateResult {
    // 1. Setup paths & state
    const cache_path = try paths.getCacheDir(allocator);
    defer allocator.free(cache_path);

    // 55: Ensure cache dir exists
    std.fs.makeDirAbsolute(cache_path) catch |err| {
        if (err != error.PathAlreadyExists) return UpdateError.AccessDenied;
    };

    var cache_dir = std.fs.openDirAbsolute(cache_path, .{ .iterate = true }) catch return UpdateError.AccessDenied;
    defer cache_dir.close();

    // 1.1 Concurrency Lock
    const lock_file = cache_dir.createFile(".lock", .{ .truncate = false }) catch return UpdateError.AccessDenied;
    defer lock_file.close();
    // Try to lock (non-blocking)
    if (lock_file.lock(.exclusive)) {
        // Acquired
    } else |err| {
        if (err == error.WouldBlock) {
            try writer.writeAll("⚠️ Another update process is running. Exiting.\n");
            return .already_current; // Or specific error
        }
        return UpdateError.AccessDenied;
    }
    defer lock_file.unlock();

    var state = UpdateState.load(allocator) catch blk: {
        // Recovery: Try to read current manifest version if state is missing/corrupt
        if (cache_dir.openFile("current/manifest.json", .{})) |m_file| {
            defer m_file.close();
            const m_bytes = m_file.readToEndAlloc(allocator, 1024 * 1024) catch break :blk UpdateState{};
            defer allocator.free(m_bytes);
            if (std.json.parseFromSlice(Manifest.ManifestContainer, allocator, m_bytes, .{})) |parsed| {
                defer parsed.deinit();
                var recovered = UpdateState{};
                recovered.recordSuccess(parsed.value.body.version, parsed.value.body.generated_at);
                break :blk recovered;
            } else |_| {}
        } else |_| {}
        break :blk UpdateState{};
    };
    defer state.deinit(allocator); // Free etag strings if any

    const now = std.time.timestamp();

    // 2. Fetch Manifest
    try writer.print("Fetching manifest from {s}...\n", .{options.endpoint});
    const manifest_url = try std.fmt.allocPrint(allocator, "{s}/pricing/manifest.json", .{options.endpoint});
    defer allocator.free(manifest_url);

    // Use state.etag for If-None-Match unless forced
    const etag_header = if (options.force) null else state.etag;

    const manifest_res = fetcher.fetch(allocator, manifest_url, .{
        .auth_token = options.auth_token,
        .max_size = 64 * 1024,
        .if_none_match = etag_header,
    }) catch |err| return mapFetchError(err);
    defer {
        // cast to mutable to call deinit
        var mut_res = manifest_res;
        mut_res.deinit(allocator);
    }

    if (manifest_res.status == .not_modified) {
        try writer.print("✓ Already up to date (cached)\n", .{});
        return .already_current;
    }

    // 3. Verify Manifest
    var manifest_container = std.json.parseFromSlice(Manifest.ManifestContainer, allocator, manifest_res.data, .{}) catch return UpdateError.ManifestInvalid;
    defer manifest_container.deinit();

    // Verify signature & logic
    Manifest.verify(allocator, manifest_container.value, Manifest.EMBEDDED_PUB_KEY_STR_HEX, now, state.highest_version_seen) catch |err| {
        switch (err) {
            error.Expired => {
                try writer.writeAll("❌ Manifest expired (anti-freeze protection)\n");
                return UpdateError.ManifestExpired;
            },
            error.RollbackDetected => {
                if (options.allow_downgrade) {
                    try writer.writeAll("⚠️ Rollback detected but allowed via flag\n");
                } else {
                    try writer.writeAll("❌ Rollback detected (anti-rollback protection)\n");
                    return UpdateError.ManifestRollback;
                }
            },
            error.SignatureInvalid => {
                try writer.writeAll("❌ Signature invalid\n");
                return UpdateError.SignatureInvalid;
            },
            error.SchemaVersionMismatch => {
                try writer.writeAll("❌ Schema version mismatch\n");
                return UpdateError.SchemaVersionMismatch;
            },
            else => return UpdateError.ManifestInvalid,
        }
    };

    // Check if version == highest_seen (and not forced)
    // verify() handles < logic.
    if (!options.force and manifest_container.value.body.version == state.highest_version_seen) {
        try writer.print("✓ Already at latest version (v{d})\n", .{manifest_container.value.body.version});
        return .already_current;
    }

    // 4. Download DB to temp file with On-the-fly Hashing
    // Ensure temp dir
    cache_dir.makePath("temp") catch return UpdateError.AccessDenied;

    const db_temp_name = "temp/pricing_db.part";
    const db_file = cache_dir.createFile(db_temp_name, .{ .read = true }) catch return UpdateError.AccessDenied;
    defer db_file.close();

    try writer.print("Downloading pricing database v{d}...\n", .{manifest_container.value.body.version});

    var stream_hash = Sha256.init(.{});
    var hashing_struct = HashingWriter(@TypeOf(db_file.writer())){
        .child_writer = db_file.writer(),
        .sha = &stream_hash,
    };

    _ = fetcher.fetchToFile(allocator, manifest_container.value.body.db.url, hashing_struct.writer(), .{
        .auth_token = options.auth_token,
        // Add safety buffer
        .max_size = manifest_container.value.body.db.size_bytes + 4096,
    }) catch |err| return mapFetchError(err);

    try db_file.sync();

    // 5. Verify Hash & Size (On-the-fly result)
    var hash: [32]u8 = undefined;
    stream_hash.final(&hash);

    var expected_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_hash, manifest_container.value.body.db.sha256) catch return UpdateError.ManifestInvalid;

    if (!std.mem.eql(u8, &hash, &expected_hash)) {
        try writer.writeAll("❌ Hash mismatch\n");
        return UpdateError.HashMismatch;
    }

    // Verify size
    const stat = try db_file.stat();
    if (stat.size != manifest_container.value.body.db.size_bytes) {
        try writer.print("❌ Size mismatch: expected {d}, got {d}\n", .{ manifest_container.value.body.db.size_bytes, stat.size });
        return UpdateError.HashMismatch;
    }

    // 6. Atomic Install
    try writer.writeAll("Installing...\n");
    const compression = manifest_container.value.body.db.compression;
    const target_filename = if (std.mem.eql(u8, compression, "zstd")) "pricing_db.json.zst" else "pricing_db.json";

    atomic.install(cache_dir, manifest_res.data, db_temp_name, target_filename) catch return UpdateError.InstallFailed;

    // 7. Update State
    state.recordSuccess(manifest_container.value.body.version, now);
    if (manifest_res.etag) |e| {
        // Free old etag?
        if (state.etag) |old| allocator.free(old);
        state.etag = try allocator.dupe(u8, e);
    }
    state.save(allocator) catch {
        try writer.writeAll("⚠️ Failed to save state\n");
    };

    try writer.print("✓ Updated to v{d}\n", .{manifest_container.value.body.version});

    return UpdateResult{ .success = .{
        .version = manifest_container.value.body.version,
        .model_count = manifest_container.value.body.db.model_count,
    } };
}

fn mapFetchError(err: fetcher.FetchError) UpdateError {
    return switch (err) {
        error.NetworkUnreachable => UpdateError.NetworkUnreachable,
        error.Timeout => UpdateError.Timeout,
        error.ServerError => UpdateError.ServerError,
        error.RateLimited => UpdateError.RateLimited,
        else => UpdateError.DownloadFailed,
    };
}

pub fn HashingWriter(comptime ChildWriter: type) type {
    return struct {
        child_writer: ChildWriter,
        sha: *Sha256,

        pub const Error = ChildWriter.Error;
        pub const Writer = std.io.Writer(*Self, Error, write);

        const Self = @This();

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            const n = try self.child_writer.write(bytes);
            if (n > 0) {
                self.sha.update(bytes[0..n]);
            }
            return n;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}
