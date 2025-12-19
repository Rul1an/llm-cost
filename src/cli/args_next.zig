const std = @import("std");

/// v1.10 Plan: Global Flags Anywhere
///
/// Current status: Deferred to v1.10.
///
/// Goal: Allow global flags (e.g. `--quiet`, `--verbose`) to appear anywhere
/// in the command line arguments, wrapping the subcommand args.
///
/// Strategy: Two-Pass Parsing
/// 1. Pass 1: Scan all arguments for global flags.
///    - If found, set global state (Verbosity, Help).
///    - Filter them out or mark indices.
/// 2. Pass 2: Parse remaining arguments as Command.
///    - If `--` is encountered, stop scanning for globals after it (standard convention).
///
/// Example:
///   `llm-cost calibrate --quiet --estimates ...` -> Valid
///   `llm-cost --quiet calibrate ...` -> Valid
///   `llm-cost calibrate ... --quiet` -> Valid
///
/// Ref: docs/v1.10_PLAN.md
pub const NextArgs = struct {
    // Placeholder for future implementation
};
