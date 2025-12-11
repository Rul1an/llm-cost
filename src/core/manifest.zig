const std = @import("std");

pub const Policy = struct {
    max_cost_usd: ?f64 = null,
    allowed_models: ?[][]const u8 = null, // null = allow all
    warn_threshold: f64 = 0.8,

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        if (self.allowed_models) |models| {
            for (models) |m| allocator.free(m);
            allocator.free(models);
        }
    }
};

/// Minimalist Config Parser (TOML Subset)
/// Supports: [sections], key = value, comments #, and string arrays ["a", "b"]
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Policy {
    var policy = Policy{};
    var current_section: enum { None, Budget, Models } = .None;

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        // Strip whitespace and comments
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |comment_idx| {
            line = std.mem.trim(u8, line[0..comment_idx], " \t\r");
        }
        if (line.len == 0) continue;

        // 1. Section Detection [section]
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section_name = line[1 .. line.len - 1];
            if (std.mem.eql(u8, section_name, "budget")) {
                current_section = .Budget;
            } else if (std.mem.eql(u8, section_name, "policy")) {
                current_section = .Models;
            } else {
                current_section = .None;
            }
            continue;
        }

        // 2. Key-Value Parsing
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

            switch (current_section) {
                .Budget => {
                    if (std.mem.eql(u8, key, "max_cost_usd")) {
                        policy.max_cost_usd = std.fmt.parseFloat(f64, val) catch null;
                    } else if (std.mem.eql(u8, key, "warn_threshold")) {
                        policy.warn_threshold = std.fmt.parseFloat(f64, val) catch 0.8;
                    }
                },
                .Models => {
                    if (std.mem.eql(u8, key, "allowed_models")) {
                        // Free old if duplicate key exists (edge case)
                        if (policy.allowed_models) |m| {
                            for (m) |item| allocator.free(item);
                            allocator.free(m);
                        }
                        policy.allowed_models = try parseStringArray(allocator, val);
                    }
                },
                .None => {},
            }
        }
    }
    return policy;
}

fn parseStringArray(allocator: std.mem.Allocator, raw_val: []const u8) ![][]const u8 {
    // Expected format: ["model-a", "model-b"]
    const trimmed = std.mem.trim(u8, raw_val, "[]");
    var list = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }

    var it = std.mem.tokenizeScalar(u8, trimmed, ',');
    while (it.next()) |token| {
        // Clean quotes and whitespace: " model " -> model
        const clean = std.mem.trim(u8, token, " \t\"'");
        try list.append(try allocator.dupe(u8, clean));
    }
    return list.toOwnedSlice();
}
