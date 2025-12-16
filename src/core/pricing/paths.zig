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
    if (std.posix.getenv("LLM_COST_CACHE_DIR")) |custom| {
        if (custom.len > 0) return allocator.dupe(u8, custom);
    }

    // 2. XDG_CACHE_HOME
    if (std.posix.getenv("XDG_CACHE_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(allocator, &.{ xdg, "llm-cost" });
    }

    // 3. Platform Defaults
    if (builtin.cpu.arch == .wasm32) return error.NotSupported;

    if (builtin.os.tag == .windows) {
        if (std.posix.getenv("LOCALAPPDATA")) |appdata| {
            return std.fs.path.join(allocator, &.{ appdata, "llm-cost" });
        }
        // Fallback if LOCALAPPDATA missing? Unlikely on Windows.
        return error.NoHomeDirectory;
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".cache", "llm-cost" });
}
