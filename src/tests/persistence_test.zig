const std = @import("std");
const testing = std.testing;
const persistence = @import("persistence");

test "Persistence: InstallAt rotates current to timestamped backup" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Setup
    const temp_name = "current.tmp";
    const current_name = "pricing_db.json";

    try tmp.dir.writeFile(.{ .sub_path = current_name, .data = "OLD_DATA" });
    try tmp.dir.writeFile(.{ .sub_path = temp_name, .data = "NEW_DATA" });

    // 1000s = 0 days, 16 mins, 40 secs -> 19700101_001640
    try persistence.installAt(testing.allocator, tmp.dir, temp_name, current_name, .{}, 1000);

    // Verify current is NEW
    try expectFileContent(tmp.dir, current_name, "NEW_DATA");

    // Verify backup name and content
    const backups = try persistence.listBackups(testing.allocator, tmp.dir);
    defer {
        for (backups) |b| testing.allocator.free(b.name);
        testing.allocator.free(backups);
    }

    try testing.expectEqual(@as(usize, 1), backups.len);
    try testing.expectEqualStrings("backup.19700101_001640", backups[0].name);
    try expectFileContent(tmp.dir, backups[0].name, "OLD_DATA");
}

test "Persistence: Naming collision handling (suffix support)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const temp_name = "current.tmp";
    const current_name = "pricing_db.json";
    const ts: i64 = 2000; // 19700101_003320

    // Install #1
    try tmp.dir.writeFile(.{ .sub_path = current_name, .data = "DATA_1" });
    try tmp.dir.writeFile(.{ .sub_path = temp_name, .data = "NEXT" });
    try persistence.installAt(testing.allocator, tmp.dir, temp_name, current_name, .{}, ts);

    // Install #2 (Same TS)
    // current now has "NEXT". We want to back it up.
    // Existing backup: backup.19700101_003320 (contains DATA_1)
    // New backup should avoid collision -> backup.19700101_003320-01
    try tmp.dir.writeFile(.{ .sub_path = temp_name, .data = "FINAL" });
    try persistence.installAt(testing.allocator, tmp.dir, temp_name, current_name, .{}, ts);

    const backups = try persistence.listBackups(testing.allocator, tmp.dir);
    defer {
        for (backups) |b| testing.allocator.free(b.name);
        testing.allocator.free(backups);
    }

    try testing.expectEqual(@as(usize, 2), backups.len);
    // listBackups sorts newest first (lexicographical descending).
    // "backup...-01" > "backup..."
    try testing.expectEqualStrings("backup.19700101_003320-01", backups[0].name);
    try testing.expectEqualStrings("backup.19700101_003320", backups[1].name);

    try expectFileContent(tmp.dir, backups[0].name, "NEXT");
    try expectFileContent(tmp.dir, backups[1].name, "DATA_1");
}

test "Persistence: Pruning keeps newest backups (Order Verification)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const current_name = "pricing_db.json";
    const temp_name = "current.tmp";

    // We will install 6 versions. Keep 3.
    // Versions 0..5.
    // Backups created:
    // 1. Install 0: No backup (fresh). Payload=V0.
    // 2. Install 1: Backup V0. Payload=V1.
    // 3. Install 2: Backup V1. Payload=V2.
    // ...
    // 6. Install 5: Backup V4. Payload=V5.
    // Total backups created: V0, V1, V2, V3, V4. (5 backups).
    // Wait, prune limit is 3.
    // So we expect to keep V4, V3, V2.
    // V0 and V1 should be deleted.

    // 0. Init
    try tmp.dir.writeFile(.{ .sub_path = temp_name, .data = "V0" });
    try persistence.installAt(testing.allocator, tmp.dir, temp_name, current_name, .{ .keep_backups = 3 }, 100);

    // 1..5
    for (1..6) |i| {
        // Current has V(i-1).
        const payload = try std.fmt.allocPrint(testing.allocator, "V{d}", .{i});
        defer testing.allocator.free(payload);
        try tmp.dir.writeFile(.{ .sub_path = temp_name, .data = payload });

        const ts: i64 = @intCast(100 + i * 10);
        try persistence.installAt(testing.allocator, tmp.dir, temp_name, current_name, .{ .keep_backups = 3 }, ts);
    }

    const backups = try persistence.listBackups(testing.allocator, tmp.dir);
    defer {
        for (backups) |b| testing.allocator.free(b.name);
        testing.allocator.free(backups);
    }

    // Installed V0..V5 (6 installs).
    // Backups should cover V0..V4.
    // Latest backups kept: V4, V3, V2.
    // Length should be 3.
    try testing.expectEqual(@as(usize, 3), backups.len);

    // Verify contents
    // backups[0] is newest (V4)
    try expectFileContent(tmp.dir, backups[0].name, "V4");
    // backups[1] (V3)
    try expectFileContent(tmp.dir, backups[1].name, "V3");
    // backups[2] (V2)
    try expectFileContent(tmp.dir, backups[2].name, "V2");
}

test "Persistence: Rollback restores backup and stashes current" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const current_name = "pricing_db.json";

    // Setup: Backup exists, Current exists (broken)
    const backup_name = "backup.20251218_120000";
    try tmp.dir.writeFile(.{ .sub_path = backup_name, .data = "GOOD" });
    try tmp.dir.writeFile(.{ .sub_path = current_name, .data = "BAD" });

    // Rollback
    try persistence.rollback(testing.allocator, tmp.dir, current_name);

    // Verify current is GOOD
    try expectFileContent(tmp.dir, current_name, "GOOD");

    // Verify backup file is gone (it was renamed to current)
    // Wait, is it?
    // Implementation: dir.rename(latest, current_name).
    // Yes, 'latest' is the path to the backup file. Rename moves it.
    // So backup file should not exist anymore at 'backup.20251218_120000'.

    // However, listBackups might still find it if we don't check file existence?
    // statFile should fail.

    if (tmp.dir.statFile(backup_name)) |_| {
        return error.TestUnexpectedResult; // Should be gone
    } else |err| {
        try testing.expectEqual(error.FileNotFound, err);
    }

    // Verify broken stashed
    var found_broken = false;
    var it = tmp.dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "broken.")) {
            found_broken = true;
            try expectFileContent(tmp.dir, entry.name, "BAD");
        }
    }
    try testing.expect(found_broken);
}

test "Persistence: Broken file collision handling during rollback" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const current_name = "pricing_db.json";
    const ts: i64 = 5000; // 19700101_012320

    // Setup:
    // 1. A backup exists (so rollback can work).
    try tmp.dir.writeFile(.{ .sub_path = "backup.000", .data = "BACKUP_DATA" });

    // 2. Current exists (broken state 1).
    try tmp.dir.writeFile(.{ .sub_path = current_name, .data = "BROKEN_1" });

    // 3. A 'broken.X' file ALREADY exists (collision).
    // X = 5000s -> 19700101_012320
    const broken_base = "broken.19700101_012320";
    try tmp.dir.writeFile(.{ .sub_path = broken_base, .data = "PREVIOUS_BROKEN" });

    // 4. Do rollback at TS=5000.
    // Should detect 'broken.X' exists and use 'broken.X-01'.
    try persistence.rollbackAt(testing.allocator, tmp.dir, current_name, ts);

    // Verify:
    // - Current restored to "BACKUP_DATA".
    try expectFileContent(tmp.dir, current_name, "BACKUP_DATA");

    // - Original broken file untouched.
    try expectFileContent(tmp.dir, broken_base, "PREVIOUS_BROKEN");

    // - New broken file created with suffix -01.
    const broken_suffix = "broken.19700101_012320-01";
    try expectFileContent(tmp.dir, broken_suffix, "BROKEN_1");
}

fn expectFileContent(dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    const data = try dir.readFileAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(expected, data);
}
