const std = @import("std");
const builtin = @import("builtin");

/// Returns the XDG-compliant cache directory for llm-cost.
/// The caller owns the returned memory.
///
/// Priority:
/// 1. $LLM_COST_CACHE_DIR
/// 2. $XDG_CACHE_HOME/llm-cost
/// 3. $HOME/.cache/llm-cost (or %LOCALAPPDATA%\llm-cost on Windows)
pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Explicit Override
    if (std.process.getEnvVarOwned(allocator, "LLM_COST_CACHE_DIR")) |custom| {
        if (custom.len > 0) return custom;
        allocator.free(custom);
    } else |_| {}

    // 2. XDG_CACHE_HOME
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg| {
        defer allocator.free(xdg);
        if (xdg.len > 0) return std.fs.path.join(allocator, &.{ xdg, "llm-cost" });
    } else |_| {}

    // 3. Platform Defaults
    if (builtin.cpu.arch == .wasm32) return error.NotSupported;

    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |appdata| {
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &.{ appdata, "llm-cost" });
        } else |_| {}
        // Fallback if LOCALAPPDATA missing? Unlikely on Windows.
        return error.NoHomeDirectory;
    }

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "llm-cost" });
    } else |_| return error.NoHomeDirectory;
}
