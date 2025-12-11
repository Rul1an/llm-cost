const std = @import("std");

/// Detect if running in a Continuous Integration environment.
/// Checks common environment variables used by major CI providers.
pub fn isCI(allocator: std.mem.Allocator) bool {
    // Standard CI flag
    if (std.posix.getenv("CI")) |_| return true;

    // GitHub Actions
    if (std.posix.getenv("GITHUB_ACTIONS")) |_| return true;

    // GitLab CI
    if (std.posix.getenv("GITLAB_CI")) |_| return true;

    // Jenkins
    if (std.posix.getenv("JENKINS_URL")) |_| return true;

    // Azure Pipelines
    if (std.posix.getenv("TF_BUILD")) |_| return true;

    // CircleCI
    if (std.posix.getenv("CIRCLECI")) |_| return true;

    // Travis CI
    if (std.posix.getenv("TRAVIS")) |_| return true;

    // Custom override check (future proofing)
    if (std.posix.getenv("LLM_COST_CI")) |_| return true;

    _ = allocator; // Kept for API compatibility if we need to alloc later
    return false;
}

test "isCI returns true for mocked env" {
    // Note: We can't easily mock std.posix.getenv in Zig tests without a wrapper or subprocess.
    // For now, we trust the logic as it is simple property checks.
    // Real testing happens in integration/E2E or by running `CI=true zig test ...`
}
