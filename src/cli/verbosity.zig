const std = @import("std");

pub const Verbosity = enum {
    quiet, // Errors only, exit code
    normal, // Progress + summary
    verbose, // Full debug output

    pub fn shouldShowProgress(self: Verbosity) bool {
        return self == .normal or self == .verbose;
    }

    pub fn shouldShowDebug(self: Verbosity) bool {
        return self == .verbose;
    }

    pub fn shouldShowSummary(self: Verbosity) bool {
        return self != .quiet;
    }
};
