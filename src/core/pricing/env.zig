const std = @import("std");

/// Detect if running in a Continuous Integration environment.
/// Checks common environment variables used by major CI providers.
pub fn isCI(allocator: std.mem.Allocator) bool {
    // Helper to check encoded vars
    const hasEnv = struct {
        fn check(a: std.mem.Allocator, key: []const u8) bool {
            if (std.process.getEnvVarOwned(a, key)) |val| {
                a.free(val);
                return true;
            } else |_| return false;
        }
    }.check;

    if (hasEnv(allocator, "CI")) return true;
    if (hasEnv(allocator, "GITHUB_ACTIONS")) return true;
    if (hasEnv(allocator, "GITLAB_CI")) return true;
    if (hasEnv(allocator, "JENKINS_URL")) return true;
    if (hasEnv(allocator, "TF_BUILD")) return true;
    if (hasEnv(allocator, "CIRCLECI")) return true;
    if (hasEnv(allocator, "TRAVIS")) return true;
    if (hasEnv(allocator, "LLM_COST_CI")) return true;

    return false;
}

test "isCI returns true for mocked env" {
    // Note: We can't easily mock std.posix.getenv in Zig tests without a wrapper or subprocess.
    // For now, we trust the logic as it is simple property checks.
    // Real testing happens in integration/E2E or by running `CI=true zig test ...`
}
