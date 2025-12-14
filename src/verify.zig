const std = @import("std");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !void {
    if (args.len == 0) {
        try stderr.print("Usage: llm-cost verify <path-to-artifact> [options]\n", .{});
        return error.MissingArgument;
    }

    const artifact_path = args[0];
    const artifact_file = std.fs.cwd().openFile(artifact_path, .{}) catch |err| {
        try stderr.print("Error: Could not open artifact '{s}': {s}\n", .{ artifact_path, @errorName(err) });
        return err;
    };
    defer artifact_file.close();

    // 1. Compute SHA256
    try stdout.print("Verifying integrity of '{s}'...\n", .{artifact_path});

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try artifact_file.read(&buf);
        if (n == 0) break;
        sha256.update(buf[0..n]);
    }
    const digest = sha256.finalResult();
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    try stdout.print("SHA256: {s}\n", .{digest_hex});

    // 2. Check checksums.txt (optional but recommended)
    // Look in same dir as artifact, or CWD
    const artifact_dir = std.fs.path.dirname(artifact_path) orelse ".";
    const checksums_path = try std.fs.path.join(allocator, &[_][]const u8{ artifact_dir, "checksums.txt" });
    defer allocator.free(checksums_path);

    if (std.fs.cwd().openFile(checksums_path, .{})) |f| {
        defer f.close();
        try stdout.print("Found checksums.txt. Verifying...\n", .{});
        const content = try f.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        if (verifyChecksum(content, std.fs.path.basename(artifact_path), &digest_hex)) {
            try stdout.print("✅ Checksum MATCHed.\n", .{});
        } else {
            try stderr.print("❌ Checksum MISMATCH or entry not found for '{s}'!\n", .{std.fs.path.basename(artifact_path)});
            return error.ChecksumMismatch;
        }
    } else |_| {
        try stdout.print("⚠️  checksums.txt not found. Skipping checksum verification.\n", .{});
    }

    // 3. GitHub Attestations (Supply Chain)
    // Check if 'gh' CLI is available
    const gh_available = checkGhAvailable(allocator);

    if (gh_available) {
        try stdout.print("\nFound 'gh' CLI. Recommended verification:\n", .{});
        try stdout.print("  gh attestation verify {s} --owner Rul1an\n", .{artifact_path});
        // We could run it automatically? implementation_plan says "Print command and offer to run".
        // For CLI simplicity, just printing is safer/less interactive for now.
    } else {
        try stdout.print("\n'gh' CLI not found.\n", .{});
        try stdout.print("To verify build provenance, install gh and run:\n", .{});
        try stdout.print("  gh attestation verify {s} --owner Rul1an\n", .{artifact_path});
    }
}

fn verifyChecksum(content: []const u8, filename: []const u8, digest: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, content, "\n\r");
    while (it.next()) |line| {
        // Format: <hash>  <filename>
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const hash = parts.next() orelse continue;
        const name = parts.next() orelse continue;

        if (std.mem.eql(u8, name, filename) or std.mem.endsWith(u8, name, filename)) {
            // Compare hash
            if (std.mem.eql(u8, hash, digest)) return true;
        }
    }
    return false;
}

fn checkGhAvailable(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "gh", "--version" },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term.Exited == 0;
}
