const std = @import("std");

fn stdinRead(_: *const anyopaque, buffer: []u8) anyerror!usize {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    return stdin.read(buffer);
}

pub fn getStdinReader() std.io.AnyReader {
    return std.io.AnyReader{ .context = undefined, .readFn = stdinRead };
}

fn stdoutWrite(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    return stdout.write(bytes);
}

pub fn getStdoutWriter() std.io.AnyWriter {
    return std.io.AnyWriter{ .context = undefined, .writeFn = stdoutWrite };
}

fn fileRead(ctx: *const anyopaque, buffer: []u8) anyerror!usize {
    const file: *const std.fs.File = @ptrCast(@alignCast(ctx));
    return file.read(buffer);
}

pub fn getFileReader(file: *const std.fs.File) std.io.AnyReader {
    return std.io.AnyReader{ .context = file, .readFn = fileRead };
}
