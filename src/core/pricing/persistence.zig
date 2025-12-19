const std = @import("std");

pub const PersistenceError = error{
    IoError,
    NoBackup,
    InvalidState,
    OutOfMemory,
    AccessDenied,
    // Collapsed unused variants
    // WriteManifest, RenameDatabase, SwapFailed, Unexpected removed
    NoBackupsFound, // Kept for CLI mapping convenience? Or map NoBackup -> NoBackupsFound in CLI.
    RollbackFailed,
};

pub const Options = struct {
    keep_backups: usize = 5,
};

pub const BackupInfo = struct {
    name: []const u8,
};

/// Install new current version, rotating old to backup.
pub fn install(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    temp_name: []const u8,
    current_name: []const u8,
    opts: Options,
) PersistenceError!void {
    const now = std.time.timestamp();
    try installAt(allocator, dir, temp_name, current_name, opts, now);
}

/// Testable install with explicit timestamp and recovery
pub fn installAt(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    temp_name: []const u8,
    current_name: []const u8,
    opts: Options,
    epoch_seconds: i64,
) PersistenceError!void {
    // 1) Ensure temp exists
    _ = dir.statFile(temp_name) catch return PersistenceError.InvalidState;

    var created_backup_name: ?[]u8 = null;
    defer if (created_backup_name) |n| allocator.free(n);

    // 2) If current exists, move to backup
    if (dir.statFile(current_name)) |_| {
        const backup_name = try makeUniqueName(allocator, dir, "backup", epoch_seconds);
        created_backup_name = backup_name; // Take ownership for cleanup/recovery tracking context
        // But we need to keep the name allocated for recovery logic?
        // makeUniqueName returns allocated slice.

        dir.rename(current_name, backup_name) catch return PersistenceError.IoError;
    } else |_| {
        // no current: ok
    }

    // 3) temp -> current (atomic in same dir)
    dir.rename(temp_name, current_name) catch |install_err| {
        // RECOVERY: If we moved current -> backup, try to move it back
        if (created_backup_name) |bk_name| {
            // Best effort recovery
            dir.rename(bk_name, current_name) catch |rec_err| {
                std.log.err("CRITICAL: Install failed and recovery (restore backup) also failed! DB may be missing. Install Error: {}, Recovery Error: {}", .{ install_err, rec_err });
            };
        }
        return PersistenceError.IoError;
    };

    // 4) prune old backups
    try pruneBackups(allocator, dir, opts.keep_backups);
    // 4) prune old backups
    try pruneBackups(allocator, dir, opts.keep_backups);
}

pub fn rollback(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    current_name: []const u8,
) PersistenceError!void {
    const now = std.time.timestamp();
    try rollbackAt(allocator, dir, current_name, now);
}

pub fn rollbackAt(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    current_name: []const u8,
    epoch_seconds: i64,
) PersistenceError!void {
    const latest = findLatestBackup(allocator, dir) catch |err| {
        if (err == PersistenceError.NoBackup) return PersistenceError.NoBackupsFound;
        return err;
    };
    defer allocator.free(latest);

    // Make unique broken name logic same as backups
    const broken_name = try makeUniqueName(allocator, dir, "broken", epoch_seconds);
    defer allocator.free(broken_name);

    // Move current -> broken (best-effort)
    var current_stashed = false;
    if (dir.statFile(current_name)) |_| {
        if (dir.rename(current_name, broken_name)) |_| {
            current_stashed = true;
        } else |_| {}
    } else |_| {}

    // Restore backup -> current
    dir.rename(latest, current_name) catch |e| {
        // Attempt to restore broken -> current if we have it
        if (current_stashed) {
            dir.rename(broken_name, current_name) catch |err_restore| {
                std.log.err("CRITICAL: Failed to restore broken backup during rollback failure: {}", .{err_restore});
            };
        }
        std.log.err("Rollback failed (rename backup->current): {}", .{e});
        return PersistenceError.RollbackFailed;
    };
}

pub fn listBackups(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
) PersistenceError![]BackupInfo {
    var list = std.ArrayList(BackupInfo).init(allocator);
    errdefer {
        for (list.items) |it| allocator.free(it.name);
        list.deinit();
    }

    var itdir = dir.iterate();
    while (itdir.next() catch return PersistenceError.IoError) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.startsWith(u8, ent.name, "backup.")) continue;

        const dup = try allocator.dupe(u8, ent.name);
        try list.append(.{ .name = dup });
    }

    // Sort newest-first
    std.mem.sort(BackupInfo, list.items, {}, struct {
        fn lessThan(_: void, a: BackupInfo, b: BackupInfo) bool {
            return std.mem.order(u8, a.name, b.name) == .gt;
        }
    }.lessThan);

    return try list.toOwnedSlice();
}

// -------------------- internals --------------------

fn pruneBackups(allocator: std.mem.Allocator, dir: std.fs.Dir, keep: usize) PersistenceError!void {
    const backups = try listBackups(allocator, dir);
    defer {
        for (backups) |b| allocator.free(b.name);
        allocator.free(backups);
    }

    if (backups.len <= keep) return;

    for (backups[keep..]) |b| {
        dir.deleteFile(b.name) catch {}; // Ignore delete errors
    }
}

fn findLatestBackup(allocator: std.mem.Allocator, dir: std.fs.Dir) PersistenceError![]u8 {
    const backups = try listBackups(allocator, dir);
    defer {
        for (backups) |b| allocator.free(b.name);
        allocator.free(backups);
    }

    if (backups.len == 0) return PersistenceError.NoBackup;
    return try allocator.dupe(u8, backups[0].name);
}

// Unified Unique Name Generator (for backup.* and broken.*)
fn makeUniqueName(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, epoch_seconds: i64) PersistenceError![]u8 {
    var buf: [32]u8 = undefined;
    const ts = formatTimestamp(epoch_seconds, &buf);

    // Try without suffix first
    const base = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, ts });
    errdefer allocator.free(base);

    if (dir.statFile(base)) |_| {
        allocator.free(base);
    } else |_| {
        return base;
    }

    // Collision: add -NN
    var n: u8 = 1;
    while (n < 100) : (n += 1) {
        const name = std.fmt.allocPrint(allocator, "{s}.{s}-{d:02}", .{ prefix, ts, n }) catch return PersistenceError.OutOfMemory;
        if (dir.statFile(name)) |_| {
            allocator.free(name);
            continue;
        } else |_| {
            return name;
        }
    }
    return PersistenceError.InvalidState; // Too many collisions?
}

/// Format seconds since epoch into "YYYYMMDD_HHMMSS" (UTC)
fn formatTimestamp(epoch_seconds: i64, out: *[32]u8) []const u8 {
    const secs = epoch_seconds;
    const day = divFloor(secs, 86_400);
    const sod = secs - day * 86_400; // 0..86399
    const hh = @divTrunc(sod, 3600);
    const mm = @divTrunc(sod - hh * 3600, 60);
    const ss = sod - hh * 3600 - mm * 60;

    const ymd = civilFromDays(day);

    return std.fmt.bufPrint(out, "{d:04}{d:02}{d:02}_{d:02}{d:02}{d:02}", .{
        @as(u32, @intCast(ymd.y)), @as(u32, ymd.m), @as(u32, ymd.d), @as(u32, @intCast(hh)), @as(u32, @intCast(mm)), @as(u32, @intCast(ss)),
    }) catch "00000000_000000";
}

fn divFloor(a: i64, b: i64) i64 {
    var q = @divTrunc(a, b);
    const r = a - q * b;
    if (r != 0 and ((r > 0) != (b > 0))) q -= 1;
    return q;
}

fn civilFromDays(days_since_1970_01_01: i64) struct { y: i32, m: u8, d: u8 } {
    const z: i64 = days_since_1970_01_01 + 719468;
    const era = divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const offset: i64 = if (mp < 10) 3 else -9;
    const m = mp + offset;
    y += if (m <= 2) 1 else 0;

    return .{
        .y = @intCast(y),
        .m = @intCast(m),
        .d = @intCast(d),
    };
}
