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
    @"export": ExportArgs, // Added export
    init: InitArgs, // Added init
    pipe: PipeArgs, // Added pipe
    report: ReportArgs, // Added report
    analytics: AnalyticsArgs, // Added analytics
    upgrade: UpgradeArgs, // Added upgrade
    verify: VerifyArgs, // Added verify
    verify_license: VerifyLicenseArgs, // Added verify-license
    models: ModelsArgs, // Added models
    count: CountArgs, // Added count
    run_models: ModelsArgs, // Alias
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

    var i: usize = 0;

    // Parse global flags first
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            result.global.verbosity = .quiet;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            result.global.verbosity = .verbose;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.global.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            result.global.version = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // If it looks like a flag but we don't recognize it as global, it MIGHT be a command flag
            // But we are parsing globals BEFORE command.
            // If we encounter a command (non-flag), we switch to command parsing.
            // If we encounter a flag here, it must be global OR we are in a weird state.
            // However, `llm-cost estimate -m gpt-4` -> `estimate` is at index 0 (after program name).
            // My logic below handles command at first non-flag.
            return ParseError.UnknownFlag;
        } else {
            // First non-flag is the command
            result.command = try parseCommand(arg, args[i + 1 ..]);
            break;
        }
    }

    // Handle --version and --help as commands if no command given
    if (result.command == .none) {
        if (result.global.version) {
            result.command = .version;
        } else if (result.global.help) {
            result.command = .help;
        }
    }

    return result;
}

fn parseCommand(cmd: []const u8, remaining: []const []const u8) ParseError!Command {
    if (std.mem.eql(u8, cmd, "calibrate")) return parseCalibrate(remaining);

    // Legacy/Pass-through commands
    if (std.mem.eql(u8, cmd, "estimate") or std.mem.eql(u8, cmd, "price") or std.mem.eql(u8, cmd, "cost")) return .{ .estimate = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "check")) return .{ .check = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "diff")) return .{ .diff = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "update-db")) return .{ .update_db = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "ci-action")) return .{ .ci_action = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "export")) return .{ .@"export" = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "init")) return .{ .init = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "pipe")) return .{ .pipe = .{ .args = remaining } };
    if (std.mem.eql(u8, cmd, "report") or std.mem.eql(u8, cmd, "tokenizer-report")) return .{ .report = .{ .args = remaining } };
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

    while (i < args.len) : (i += 1) {
        const arg = args[i];

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
            if (std.mem.eql(u8, val, "warn")) result.fail_on_drift = .warn else if (std.mem.eql(u8, val, "error")) result.fail_on_drift = .@"error" else if (std.mem.eql(u8, val, "never")) result.fail_on_drift = .never else return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--cardinality-policy")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            const val = args[i];
            if (std.mem.eql(u8, val, "degrade")) result.cardinality_policy = 0 else if (std.mem.eql(u8, val, "error")) result.cardinality_policy = 1 else return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Assume it's a calibrate specific flag? Or error?
            // For now error, to be safe.
            return ParseError.UnknownFlag;
        }
    }

    // Validate conflicting flags
    if (result.apply and result.rollback) {
        return ParseError.ConflictingFlags;
    }

    return .{ .calibrate = result };
}
