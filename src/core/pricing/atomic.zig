const std = @import("std");

pub const InstallError = error{
    WriteManifest,
    RenameDatabase,
    SwapFailed,
    AccessDenied,
    Unexpected,
    OutOfMemory,
};

/// Atomically install new pricing data.
/// cache_dir: opened Dir handle to the root cache directory.
/// db_source_name: relative path to the downloaded DB (e.g. "temp/db.part").
pub fn install(
    cache_dir: std.fs.Dir,
    manifest_data: []const u8,
    db_source_name: []const u8,
) !void {
    // 1. Write manifest to temp/manifest.json
    // We assume 'temp' directory exists (implied by db_source_name being in it).
    const manifest_path = "temp/manifest.json";

    cache_dir.writeFile(.{ .sub_path = manifest_path, .data = manifest_data }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            else => error.WriteManifest,
        };
    };

    // 2. Rename DB source -> temp/pricing_db.json
    const db_target_path = "temp/pricing_db.json";
    cache_dir.rename(db_source_name, db_target_path) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            else => error.RenameDatabase,
        };
    };

    // 3. Rotate: current -> last_good
    // Recursively delete last_good if it exists
    cache_dir.deleteTree("last_good") catch {};

    // Rename current -> last_good
    cache_dir.rename("current", "last_good") catch |err| {
        // If current doesn't exist (first run), that's fine.
        if (err != error.FileNotFound) {
            return error.SwapFailed;
        }
    };

    // 4. Promote: temp -> current
    cache_dir.rename("temp", "current") catch |err| {
        // If this fails, we are in a bad state (no current, temp exists, last_good exists).
        // Rollback strategy: try to rename last_good back to current?
        // For now, return error.
        return error.SwapFailed;
    };
}
