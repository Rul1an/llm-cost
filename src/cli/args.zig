const std = @import("std");
const Verbosity = @import("verbosity.zig").Verbosity;

pub const GlobalFlags = struct {
    verbosity: Verbosity = .normal,
    help: bool = false,
    version: bool = false,
};

pub const Command = union(enum) {
    estimate: EstimateArgs,
    check: CheckArgs,
    diff: DiffArgs,
    calibrate: CalibrateArgs,
    update_db: UpdateDbArgs,
    ci_action: CiActionArgs,
    @"export": ExportArgs,
    init: InitArgs,
    pipe: PipeArgs,
    report: ReportArgs,
    analytics: AnalyticsArgs,
    upgrade: UpgradeArgs,
    verify: VerifyArgs,
    verify_license: VerifyLicenseArgs,
    models: ModelsArgs,
    count: CountArgs,

    version: void,
    help: void,
    none: void,
};

pub const CalibrateArgs = struct {
    estimates: ?[]const u8 = null,
    actuals: ?[]const u8 = null,
    apply: bool = false,
    rollback: bool = false,
    dry_run: bool = true, // Default: dry-run
    format: OutputFormat = .table,
    max_resources: usize = 10_000,
    min_samples: usize = 100,
    fail_on_drift: FailDrift = .never,
    cardinality_policy: isize = 0,
    help: bool = false,
};

pub const OutputFormat = enum {
    table,
    json,
    toml, // Added TOML support

    pub fn fromString(s: []const u8) ?OutputFormat {
        const map = std.StaticStringMap(OutputFormat).initComptime(.{
            .{ "table", .table },
            .{ "json", .json },
            .{ "toml", .toml },
        });
        return map.get(s);
    }
};

pub const FailDrift = enum { never, warn, @"error" };

// Placeholder types for other commands (using generic args slice for now where complex parsing is needed in sub-commands)
// ideally we fully parse them here, but for PR7.6 we focus on calibrate.
// For existing commands, we might need to pass raw args or implement parsing here.
// User plan suggests implementing `parseCalibrate` fully, others stubbed or basic.
// I will implement basic stubs that can hold raw args if needed, or just specific fields if simpler.
// Actually, `main.zig` dispatches based on string. If I use `args.zig`, I should probably pass raw arg slice to legacy commands for now to minimize risk?
// BUT `args.zig` returns `Command` union. If I use `none` or a raw variant, it might work.
// Let's implement full parsing logic for `calibrate` and basic/raw for others.

pub const EstimateArgs = struct { args: []const []const u8 };
pub const CheckArgs = struct { args: []const []const u8 };
pub const DiffArgs = struct { args: []const []const u8 };
pub const UpdateDbArgs = struct { args: []const []const u8 };
pub const CiActionArgs = struct { args: []const []const u8 };
pub const ExportArgs = struct { args: []const []const u8 };
pub const InitArgs = struct { args: []const []const u8 };
pub const PipeArgs = struct { args: []const []const u8 };
pub const ReportArgs = struct { args: []const []const u8 };
pub const AnalyticsArgs = struct { args: []const []const u8 };
pub const UpgradeArgs = struct { args: []const []const u8 };
pub const VerifyArgs = struct { args: []const []const u8 };
pub const VerifyLicenseArgs = struct { args: []const []const u8 };
pub const ModelsArgs = struct { args: []const []const u8 };
pub const CountArgs = struct { args: []const []const u8 };

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidValue,
    ConflictingFlags,
};

pub const ParseResult = struct {
    global: GlobalFlags,
    command: Command,
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!ParseResult {
    _ = allocator;

    var result = ParseResult{
        .global = .{},
        .command = .none,
    };

    var cmd_idx: ?usize = null;
    var term_idx: ?usize = null;

    // Pass 1: Scan for command and terminator
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            term_idx = i;
            // Next arg is command if we haven't found one
            if (i + 1 < args.len) {
                cmd_idx = i + 1;
            } else {
                // Trailing terminator with no command: "llm-cost --"
                // Effectively no command.
            }
            break;
        }
        if (arg.len > 0 and arg[0] != '-') {
            cmd_idx = i;
            break;
        }
    }

    // Pass 2: Extract Globals
    for (args, 0..) |arg, i| {
        // Stop at global terminator
        if (term_idx) |t| {
            if (i == t) break;
        }
        // Stop if we encounter terminator explicitly (even if not found in Pass 1)
        if (std.mem.eql(u8, arg, "--")) break;

        if (cmd_idx) |c| {
            if (i == c) continue;
        }

        const is_zone2 = if (cmd_idx) |c| i > c else false;

        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            result.global.verbosity = .quiet;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            result.global.verbosity = .verbose;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            if (!is_zone2) result.global.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            if (!is_zone2) result.global.version = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Zone 1: Error (typo hazard). Zone 2: Ignore (command parsing).
            if (!is_zone2) return ParseError.UnknownFlag;
        }
    }

    // Global Help/Version Early Exit
    if (result.global.version) {
        return .{ .global = result.global, .command = .version };
    }
    if (result.global.help) {
        return .{ .global = result.global, .command = .help };
    }

    // Dispatch Command
    if (cmd_idx) |c| {
        if (c < args.len) {
            const cmd_str = args[c];
            const tail = args[c + 1 ..];
            result.command = try parseCommand(cmd_str, tail);
        }
    } else {
        // No command found.
    }

    return result;
}

fn parseCommand(cmd: []const u8, remaining: []const []const u8) ParseError!Command {
    if (std.mem.eql(u8, cmd, "calibrate")) return parseCalibrate(remaining);

    // Legacy/Pass-through commands
    if (std.mem.eql(u8, cmd, "estimate")) return .{ .estimate = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "price")) {
        std.log.warn("⚠️ 'price' is deprecated, use 'estimate' instead", .{});
        return .{ .estimate = .{ .args = remaining } };
    }
    if (std.mem.eql(u8, cmd, "cost")) {
        std.log.warn("⚠️ 'cost' is deprecated, use 'estimate' instead", .{});
        return .{ .estimate = .{ .args = remaining } };
    }
    if (std.mem.eql(u8, cmd, "check")) return .{ .check = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "diff")) return .{ .diff = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "update-db")) return .{ .update_db = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "ci-action")) return .{ .ci_action = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "export")) return .{ .@"export" = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "init")) return .{ .init = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "pipe")) return .{ .pipe = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "report")) return .{ .report = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "tokenizer-report")) {
        std.log.warn("⚠️ 'tokenizer-report' is deprecated, use 'report' instead", .{});
        return .{ .report = .{ .args = remaining } };
    }
    if (std.mem.eql(u8, cmd, "analyze-fairness")) return .{ .analytics = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "upgrade")) return .{ .upgrade = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "verify")) return .{ .verify = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "verify-license")) return .{ .verify_license = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "models")) return .{ .models = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "tokens") or std.mem.eql(u8, cmd, "count")) return .{ .count = .{ .args = remaining } };

    if (std.mem.eql(u8, cmd, "version")) return .version;
    if (std.mem.eql(u8, cmd, "help")) return .help;

    return ParseError.UnknownCommand;
}

fn parseCalibrate(args: []const []const u8) ParseError!Command {
    var result = CalibrateArgs{};
    var i: usize = 0;
    var stop_flags = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (stop_flags) {
            // Positional args are not allowed for calibrate
            return ParseError.UnknownFlag;
        }

        if (std.mem.eql(u8, arg, "--")) {
            stop_flags = true;
            continue;
        }

        // Ignore global flags in pass 2 (Zone 2)
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose") or
            std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet"))
        {
            continue;
        }

        if (std.mem.eql(u8, arg, "--estimates")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            result.estimates = args[i];
        } else if (std.mem.eql(u8, arg, "--actuals")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            result.actuals = args[i];
        } else if (std.mem.eql(u8, arg, "--apply")) {
            result.apply = true;
            result.dry_run = false;
        } else if (std.mem.eql(u8, arg, "--rollback")) {
            result.rollback = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            result.dry_run = true;
            result.apply = false;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            result.format = OutputFormat.fromString(args[i]) orelse
                return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--max-resources")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            result.max_resources = std.fmt.parseInt(usize, args[i], 10) catch
                return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--min-samples")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            result.min_samples = std.fmt.parseInt(usize, args[i], 10) catch
                return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--fail-on-drift")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            const val = args[i];
            if (std.mem.eql(u8, val, "warn")) {
                result.fail_on_drift = .warn;
            } else if (std.mem.eql(u8, val, "error")) {
                result.fail_on_drift = .@"error";
            } else if (std.mem.eql(u8, val, "never")) {
                result.fail_on_drift = .never;
            } else {
                return ParseError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--cardinality-policy")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            const val = args[i];
            if (std.mem.eql(u8, val, "degrade")) {
                result.cardinality_policy = 0;
            } else if (std.mem.eql(u8, val, "error")) {
                result.cardinality_policy = 1;
            } else {
                return ParseError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Assume it's a calibrate specific flag? Or error?
            // For now error, to be safe.
            return ParseError.UnknownFlag;
        } else {
            // Unexpected positional argument
            return ParseError.UnknownFlag;
        }
    }

    // Validate conflicting flags
    if (result.apply and result.rollback) {
        return ParseError.ConflictingFlags;
    }

    return .{ .calibrate = result };
}
