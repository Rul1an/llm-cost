const std = @import("std");

pub fn getStdinReader() std.io.AnyReader {
    return std.io.getStdIn().reader().any();
}

pub fn getStdoutWriter() std.io.AnyWriter {
    return std.io.getStdOut().writer().any();
}

pub fn getStderrWriter() std.io.AnyWriter {
    return std.io.getStdErr().writer().any();
}

pub fn getFileReader(file: *const std.fs.File) std.io.AnyReader {
    return file.reader().any();
}
