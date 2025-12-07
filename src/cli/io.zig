const std = @import("std");

const posix = std.posix;

/// --- STDIN / STDOUT / STDERR via raw fds ---

fn stdinRead(_: *const anyopaque, buf: []u8) anyerror!usize {
    return posix.read(posix.STDIN_FILENO, buf);
}

pub fn getStdinReader() std.io.AnyReader {
    return .{
        .context = undefined,
        .readFn = stdinRead,
    };
}

fn stdoutWrite(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return posix.write(posix.STDOUT_FILENO, bytes);
}

pub fn getStdoutWriter() std.io.AnyWriter {
    return .{
        .context = undefined,
        .writeFn = stdoutWrite,
    };
}

fn stderrWrite(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return posix.write(posix.STDERR_FILENO, bytes);
}

pub fn getStderrWriter() std.io.AnyWriter {
    return .{
        .context = undefined,
        .writeFn = stderrWrite,
    };
}

/// --- Files via std.fs.File (correctly opened with modes) ---

fn fileRead(ctx: *const anyopaque, buf: []u8) anyerror!usize {
    const file: *const std.fs.File = @ptrCast(@alignCast(ctx));
    return file.read(buf);
}

pub fn getFileReader(file: *const std.fs.File) std.io.AnyReader {
    return .{
        .context = file,
        .readFn = fileRead,
    };
}
