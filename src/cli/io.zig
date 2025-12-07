const std = @import("std");

pub const ReadError = anyerror;
pub const WriteError = anyerror;

/// Simple reader abstraction, decoupled from std.io
pub const Reader = struct {
    context: *const anyopaque,
    readFn: *const fn (ctx: *const anyopaque, buffer: []u8) ReadError!usize,

    pub fn read(self: Reader, buffer: []u8) ReadError!usize {
        return self.readFn(self.context, buffer);
    }
};

/// Simple writer abstraction, decoupled from std.io
pub const Writer = struct {
    context: *const anyopaque,
    writeFn: *const fn (ctx: *const anyopaque, bytes: []const u8) WriteError!usize,

    pub fn write(self: Writer, bytes: []const u8) WriteError!usize {
        return self.writeFn(self.context, bytes);
    }

    pub fn writeAll(self: Writer, bytes: []const u8) WriteError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            const n = try self.write(bytes[index..]);
            if (n == 0) return error.DiskQuota; // or similar
            index += n;
        }
    }

    pub fn print(self: Writer, comptime format: []const u8, args: anytype) WriteError!void {
        return std.fmt.format(self, format, args);
    }
};

fn stdinRead(_: *const anyopaque, buffer: []u8) ReadError!usize {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    return stdin.read(buffer);
}

pub fn getStdinReader() Reader {
    return Reader{
        .context = undefined,
        .readFn = stdinRead,
    };
}

fn stdoutWrite(_: *const anyopaque, bytes: []const u8) WriteError!usize {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    return stdout.write(bytes);
}

pub fn getStdoutWriter() Writer {
    return Writer{
        .context = undefined,
        .writeFn = stdoutWrite,
    };
}

fn stderrWrite(_: *const anyopaque, bytes: []const u8) WriteError!usize {
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    return stderr.write(bytes);
}

pub fn getStderrWriter() Writer {
    return Writer{
        .context = undefined,
        .writeFn = stderrWrite,
    };
}

fn fileRead(ctx: *const anyopaque, buffer: []u8) ReadError!usize {
    const file: *const std.fs.File = @ptrCast(@alignCast(ctx));
    return file.read(buffer);
}

pub fn getFileReader(file: *const std.fs.File) Reader {
    return Reader{
        .context = file,
        .readFn = fileRead,
    };
}
