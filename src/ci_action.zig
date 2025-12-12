const std = @import("std");
const context = @import("context.zig");
const github_api = @import("core/github_api.zig");
const estimate_cmd = @import("commands/estimate.zig");
const diff_cmd = @import("diff.zig");
const file_provider = @import("core/file_provider.zig");
const git_show = @import("core/git_show.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 1,
    budget_exceeded = 2,
    policy_violation = 3,
    api_error = 4,
};

pub const ConfigError = error{
    MissingToken,
    MissingEventPath,
    MissingManifest,
    InvalidArg,
    InvalidBudget,
    UsageHelp,
};

pub const GitHubEvent = struct {
    number: ?u64 = null,
    pull_request: ?struct {
        number: u64,
    } = null,
    repository: struct {
        full_name: []const u8,
    },
};

pub const Env = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getOwned: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) ?[]u8,
    };

    pub fn getOwned(self: Env, allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
        return self.vtable.getOwned(self.ctx, allocator, key);
    }
};

pub const ProcessEnv = struct {
    pub fn env() Env {
        return .{
            .ctx = @constCast(@ptrCast(@alignCast(&@as(u8, 0)))),
            .vtable = &.{
                .getOwned = getOwned,
            },
        };
    }

    fn getOwned(_: *anyopaque, allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
        return std.process.getEnvVarOwned(allocator, key) catch null;
    }
};

pub const Config = struct {
    github_token: []const u8, // owned
    event_path: []const u8, // owned
    manifest_path: []const u8, // owned
    base_ref: ?[]const u8 = null, // owned

    budget_usd: ?f64 = null,
    fail_on_increase: bool = false,
    comment_threshold: f64 = 0.0,
    post_comment: bool = true,
    comment_marker: []const u8 = "<!-- llm-cost-action-comment -->",

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.github_token);
        allocator.free(self.event_path);
        allocator.free(self.manifest_path);
        if (self.base_ref) |b| allocator.free(b);
    }

    pub fn parseFrom(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env: Env,
    ) !Config {
        var token_owned: ?[]u8 = env.getOwned(allocator, "GITHUB_TOKEN");
        errdefer if (token_owned) |t| allocator.free(t);

        var event_owned: ?[]u8 = env.getOwned(allocator, "GITHUB_EVENT_PATH");
        errdefer if (event_owned) |p| allocator.free(p);

        var manifest_p: []const u8 = "llm-cost.toml";
        var base_ref_owned: ?[]u8 = env.getOwned(allocator, "GITHUB_BASE_REF");
        errdefer if (base_ref_owned) |b| allocator.free(b);

        var budget: ?f64 = null;
        var fail_on_increase: bool = false;
        var comment_threshold: f64 = 0.0;
        var post_comment: bool = true;
        var marker: []const u8 = "<!-- llm-cost-action-comment -->";

        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];

            if (std.mem.eql(u8, arg, "ci-action")) continue;

            if (std.mem.eql(u8, arg, "--github-token")) {
                i += 1;
                if (i >= argv.len) return ConfigError.MissingToken;
                if (token_owned) |t| allocator.free(t);
                token_owned = try allocator.dupe(u8, argv[i]);
            } else if (std.mem.eql(u8, arg, "--event-path")) {
                i += 1;
                if (i >= argv.len) return ConfigError.MissingEventPath;
                if (event_owned) |p| allocator.free(p);
                event_owned = try allocator.dupe(u8, argv[i]);
            } else if (std.mem.eql(u8, arg, "--manifest")) {
                i += 1;
                if (i >= argv.len) return ConfigError.MissingManifest;
                manifest_p = argv[i];
            } else if (std.mem.eql(u8, arg, "--base")) {
                i += 1;
                if (i >= argv.len) return ConfigError.InvalidArg;
                if (base_ref_owned) |b| allocator.free(b);
                base_ref_owned = try allocator.dupe(u8, argv[i]);
            } else if (std.mem.eql(u8, arg, "--budget")) {
                i += 1;
                if (i >= argv.len) return ConfigError.InvalidBudget;
                budget = try parseF64(argv[i]);
            } else if (std.mem.eql(u8, arg, "--fail-on-increase")) {
                fail_on_increase = true;
            } else if (std.mem.eql(u8, arg, "--comment-threshold")) {
                i += 1;
                if (i >= argv.len) return ConfigError.InvalidArg;
                comment_threshold = try parseF64(argv[i]);
            } else if (std.mem.eql(u8, arg, "--post-comment")) {
                post_comment = true;
            } else if (std.mem.eql(u8, arg, "--no-comment")) {
                post_comment = false;
            } else if (std.mem.eql(u8, arg, "--comment-marker")) {
                i += 1;
                if (i >= argv.len) return ConfigError.InvalidArg;
                marker = argv[i];
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return ConfigError.UsageHelp;
            } else {
                return ConfigError.InvalidArg;
            }
        }

        if (token_owned == null) return ConfigError.MissingToken;
        if (event_owned == null) return ConfigError.MissingEventPath;

        return .{
            .github_token = token_owned.?,
            .event_path = event_owned.?,
            .manifest_path = try allocator.dupe(u8, manifest_p),
            .base_ref = base_ref_owned,
            .budget_usd = budget,
            .fail_on_increase = fail_on_increase,
            .comment_threshold = comment_threshold,
            .post_comment = post_comment,
            .comment_marker = marker,
        };
    }

    fn parseF64(s: []const u8) !f64 {
        // Accept "10", "10.0", "0.01"
        return std.fmt.parseFloat(f64, s) catch return ConfigError.InvalidBudget;
    }
};

fn readFileBounded(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, max_bytes);
}

fn parseEvent(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !struct { owner: []const u8, repo: []const u8, pr_number: u64 } {
    var parsed = try std.json.parseFromSlice(
        GitHubEvent,
        allocator,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const full = parsed.value.repository.full_name;
    const slash = std.mem.indexOfScalar(u8, full, '/') orelse return error.InvalidRepoFullName;
    if (slash == 0 or slash + 1 >= full.len) return error.InvalidRepoFullName;

    const owner_slice = full[0..slash];
    const repo_slice = full[slash + 1 ..];

    const pr = if (parsed.value.pull_request) |p| p.number else parsed.value.number orelse return error.MissingPrNumber;

    return .{
        .owner = try allocator.dupe(u8, owner_slice),
        .repo = try allocator.dupe(u8, repo_slice),
        .pr_number = pr,
    };
}

fn buildCommentMarkdown(
    allocator: std.mem.Allocator,
    marker: []const u8,
    total_cost_usd: f64,
    budget: ?f64,
    budget_failed: bool,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const w = out.writer();

    try w.print("{s}\n", .{marker});
    try w.print("## 💰 LLM Cost Estimate\n\n", .{});
    try w.print("| Metric | Value |\n|---|---|\n", .{});
    try w.print("| **This run** | ${d:.6} |\n", .{total_cost_usd});

    if (budget) |b| {
        if (budget_failed) {
            try w.print("| **Budget** | ❌ ${d:.6} (exceeded) |\n", .{b});
        } else {
            try w.print("| **Budget** | ✅ ${d:.6} |\n", .{b});
        }
    }

    try w.print("\n<sub>Generated by llm-cost</sub>\n", .{});

    return try out.toOwnedSlice();
}

/// Minimal: we compute HEAD cost by calling existing estimate path as JSON and parsing the total.
/// This avoids duplicating the estimator here.
fn estimateHeadTotalUsd(state: context.GlobalState, manifest_path: []const u8) !f64 {
    var buf = std.ArrayList(u8).init(state.allocator);
    defer buf.deinit();

    // Create a temporary state that writes to our buffer instead of real stdout
    // We shallow copy the registry pointer and allocator
    const tmp_state = context.GlobalState{
        .allocator = state.allocator,
        .registry = state.registry,
        .stdout = buf.writer().any(),
        .stderr = state.stderr, // Keep stderr real so errors show up
    };

    // Assumption: estimate supports manifest scan when only --manifest is provided.
    // We implemented this update in commands/estimate.zig
    const args = [_][]const u8{ "--format=json", "--manifest", manifest_path };
    try estimate_cmd.run(tmp_state, &args);

    const Out = struct {
        summary: struct {
            total_cost_usd: f64,
        },
    };

    var parsed = try std.json.parseFromSlice(Out, state.allocator, buf.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return parsed.value.summary.total_cost_usd;
}

pub fn run(state: context.GlobalState, argv: []const []const u8) !u8 {
    var cfg = Config.parseFrom(state.allocator, argv, ProcessEnv.env()) catch |err| {
        switch (err) {
            ConfigError.UsageHelp => {
                try state.stderr.writeAll("Usage: llm-cost ci-action [--manifest <path>] [--budget <usd>] [--no-comment]\n" ++
                    "                      [--github-token <token>] [--event-path <path>] [--comment-marker <s>]\n");
                return @intFromEnum(ExitCode.usage);
            },
            else => {
                try state.stderr.print("ci-action config error: {}\n", .{err});
                return @intFromEnum(ExitCode.usage);
            },
        }
    };
    defer cfg.deinit(state.allocator);

    const ev_json = try readFileBounded(state.allocator, cfg.event_path, 1024 * 1024);
    defer state.allocator.free(ev_json);

    const ctx = parseEvent(state.allocator, ev_json) catch |err| {
        try state.stderr.print("ci-action event parse error: {}\n", .{err});
        return @intFromEnum(ExitCode.usage);
    };
    defer {
        state.allocator.free(ctx.owner);
        state.allocator.free(ctx.repo);
    }

    const total = estimateHeadTotalUsd(state, cfg.manifest_path) catch |err| {
        try state.stderr.print("ci-action estimate error: {}\n", .{err});
        return @intFromEnum(ExitCode.api_error);
    };

    var increase_violation = false;
    var total_delta_usd: f64 = 0.0;
    var diff_calculated = false;

    if (cfg.fail_on_increase or cfg.comment_threshold > 0) {
        if (cfg.base_ref) |base| {
            // Setup Providers
            // Base: GitShowProvider (using git show <base>:<path>)
            // Head: FileProvider (FS)
            const base_ctx = git_show.Context{ .repo_dir = ".", .revision = base };
            const base_p = file_provider.Provider{ .git_show = base_ctx };
            const head_p = file_provider.Provider{ .filesystem = .{ .repo_dir = "." } };

            // Compute Deltas
            const deltas = diff_cmd.computeDeltas(state.allocator, base_p, head_p, cfg.manifest_path, state.registry) catch |err| {
                try state.stderr.print("ci-action diff error: {}\n", .{err});
                return @intFromEnum(ExitCode.api_error);
            };
            defer {
                for (deltas) |*d| {
                    state.allocator.free(d.file_path);
                    state.allocator.free(d.resource_id);
                }
                state.allocator.free(deltas);
            }

            var sum_delta: i128 = 0;
            for (deltas) |d| {
                sum_delta += d.delta;
            }
            total_delta_usd = @as(f64, @floatFromInt(sum_delta)) / 1e12;
            diff_calculated = true;

            if (cfg.fail_on_increase and total_delta_usd > 0) {
                increase_violation = true;
            }
        } else {
            // Missing Base Ref -> Cannot compute diff -> Warn but don't crash?
            // Or fail if fail_on_increase is requested?
            // User provided fail-on-increase, so we should fail if we can't check it?
            try state.stderr.print("Warning: --fail-on-increase or --comment-threshold requested but no Base Ref found (set GITHUB_BASE_REF or --base).\n", .{});
        }
    }

    const budget_failed = if (cfg.budget_usd) |b| total > b else false;
    var exit_code: u8 = @intFromEnum(ExitCode.ok);

    if (budget_failed or increase_violation) {
        exit_code = @intFromEnum(ExitCode.budget_exceeded);
    }

    try state.stdout.print("ci-action: total_cost_usd={d:.6}", .{total});
    if (cfg.budget_usd) |b| try state.stdout.print(" budget_usd={d:.6}", .{b});
    if (diff_calculated) try state.stdout.print(" delta_usd={d:.6}", .{total_delta_usd});

    var status_str: []const u8 = "pass";
    if (budget_failed) status_str = "fail(budget)";
    if (increase_violation) status_str = "fail(increase)";

    try state.stdout.print(" status={s}\n", .{status_str});

    if (cfg.comment_threshold > 0 and diff_calculated) {
        if (@abs(total_delta_usd) < cfg.comment_threshold) {
            // Skip comment
            return exit_code;
        }
    }

    if (cfg.post_comment) {
        // Build comment body
        const comment = try buildCommentMarkdown(
            state.allocator,
            cfg.comment_marker,
            total,
            cfg.budget_usd,
            budget_failed,
        );
        defer state.allocator.free(comment);

        var http = try github_api.StdHttpTransport.init(state.allocator, 16 * 1024);
        defer http.deinit();

        var api = github_api.GitHubApi.init(
            state.allocator,
            .{ .owner = ctx.owner, .name = ctx.repo },
            cfg.github_token,
            http.transport(),
            .{},
        );

        const res = api.upsertStickyIssueComment(
            state.allocator,
            @intCast(ctx.pr_number),
            cfg.comment_marker,
            comment,
        ) catch |err| {
            // Don’t fail the budget gate just because comment failed.
            try state.stderr.print("ci-action: comment post failed: {}\n", .{err});
            return exit_code;
        };

        try state.stdout.print("ci-action: {s} comment #{d}\n", .{
            if (res.action == .created) "created" else "updated",
            res.comment_id,
        });
    }

    return exit_code;
}

test "GitHubEvent minimal parse extracts full_name + pr number" {
    const a = std.testing.allocator;

    const payload =
        \\{
        \\  "repository": {"full_name":"Rul1an/llm-cost"},
        \\  "pull_request": {"number": 19}
        \\}
    ;

    const ctx = try parseEvent(a, payload);
    defer {
        a.free(ctx.owner);
        a.free(ctx.repo);
    }

    try std.testing.expectEqualStrings("Rul1an", ctx.owner);
    try std.testing.expectEqualStrings("llm-cost", ctx.repo);
    try std.testing.expectEqual(@as(u64, 19), ctx.pr_number);
}

test "Config.parseFrom reads env defaults and supports overrides" {
    const a = std.testing.allocator;

    // Fake env
    const FakeEnv = struct {
        token: []const u8,
        event: []const u8,

        fn getOwned(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, key, "GITHUB_TOKEN")) return allocator.dupe(u8, self.token) catch null;
            if (std.mem.eql(u8, key, "GITHUB_EVENT_PATH")) return allocator.dupe(u8, self.event) catch null;
            return null;
        }
    };

    var fe = FakeEnv{ .token = "t0k", .event = "/tmp/event.json" };
    // Use *const fn cast
    const getOwnedPtr: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) ?[]u8 = FakeEnv.getOwned;

    const env: Env = .{
        .ctx = &fe,
        .vtable = &.{ .getOwned = getOwnedPtr },
    };

    const argv = [_][]const u8{ "ci-action", "--manifest", "x.toml", "--budget", "1.25", "--no-comment" };
    var cfg = try Config.parseFrom(a, &argv, env);
    defer cfg.deinit(a);

    try std.testing.expectEqualStrings("t0k", cfg.github_token);
    try std.testing.expectEqualStrings("/tmp/event.json", cfg.event_path);
    try std.testing.expectEqualStrings("x.toml", cfg.manifest_path);
    try std.testing.expect(cfg.budget_usd.? == 1.25);
    try std.testing.expect(cfg.post_comment == false);
}
