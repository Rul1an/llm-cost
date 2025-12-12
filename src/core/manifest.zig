const std = @import("std");

pub const PromptDef = struct {
    path: []const u8,
    prompt_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    tags: ?std.StringHashMap([]const u8) = null,

    pub fn deinit(self: *PromptDef, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.prompt_id) |id| allocator.free(id);
        if (self.model) |m| allocator.free(m);
        if (self.tags) |*t| {
            var it = t.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            t.deinit();
        }
    }
};

pub const Policy = struct {
    // Budget Section
    max_cost_usd: ?f64 = null,
    warn_threshold: f64 = 0.8,

    // Policy Section
    allowed_models: ?[][]const u8 = null,

    // Defaults Section (v0.10)
    default_model: ?[]const u8 = null, // [defaults].model

    // Prompts (v0.10)
    prompts: ?[]PromptDef = null,

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        if (self.allowed_models) |models| {
            for (models) |m| allocator.free(m);
            allocator.free(models);
        }
        if (self.default_model) |m| allocator.free(m);
        if (self.prompts) |prompts| {
            for (prompts) |*p| p.deinit(allocator);
            allocator.free(prompts);
        }
    }
};

/// Minimalist Config Parser (TOML Subset) v2
/// Supports: [section], [[array_of_tables]], key = value, inline_tables { k="v" }
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Policy {
    var policy = Policy{};
    errdefer policy.deinit(allocator);

    // Temporary storage for accumulating prompts
    var prompts_list = std.ArrayList(PromptDef).init(allocator);
    // Be careful with errdefer here; policy.deinit handles self.prompts, but prompts_list is local until assigned.
    // Strategy: only assign to policy at the end. For now, manual cleanup on error.
    errdefer {
        for (prompts_list.items) |*p| p.deinit(allocator);
        prompts_list.deinit();
    }

    var current_state: enum { None, Budget, Models, Defaults, Prompt } = .None;

    // Pointer to the prompt currently being built (if in Prompt state)
    // We append a generic PromptDef when entering [[prompts]], then modify the last item.

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        // Strip whitespace and comments
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |comment_idx| {
            line = std.mem.trim(u8, line[0..comment_idx], " \t\r");
        }
        if (line.len == 0) continue;

        // 1. Array of Tables Detection [[prompts]]
        if (line.len >= 4 and line[0] == '[' and line[1] == '[' and line[line.len - 1] == ']' and line[line.len - 2] == ']') {
            const section_name = line[2 .. line.len - 2];
            if (std.mem.eql(u8, section_name, "prompts")) {
                current_state = .Prompt;
                // Start a new prompt. Path is required and must be owned memory for deinit; initialize with an allocated empty string.
                try prompts_list.append(PromptDef{ .path = "" });
                prompts_list.items[prompts_list.items.len - 1].path = try allocator.dupe(u8, "");
            }
            continue;
        }

        // 2. Section Detection [section] (Standard Table)
        if (line[0] == '[' and line[1] != '[' and line[line.len - 1] == ']') {
            const section_name = line[1 .. line.len - 1];
            if (std.mem.eql(u8, section_name, "budget")) {
                current_state = .Budget;
            } else if (std.mem.eql(u8, section_name, "policy")) {
                current_state = .Models;
            } else if (std.mem.eql(u8, section_name, "defaults")) {
                current_state = .Defaults;
            } else {
                current_state = .None;
            }
            continue;
        }

        // 3. Key-Value Parsing
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

            switch (current_state) {
                .Budget => {
                    if (std.mem.eql(u8, key, "max_cost_usd")) {
                        policy.max_cost_usd = std.fmt.parseFloat(f64, val) catch null;
                    } else if (std.mem.eql(u8, key, "warn_threshold")) {
                        policy.warn_threshold = std.fmt.parseFloat(f64, val) catch 0.8;
                    }
                },
                .Models => {
                    if (std.mem.eql(u8, key, "allowed_models")) {
                        if (policy.allowed_models) |m| {
                            for (m) |item| allocator.free(item);
                            allocator.free(m);
                        }
                        policy.allowed_models = try parseStringArray(allocator, val);
                    }
                },
                .Defaults => {
                    if (std.mem.eql(u8, key, "model")) {
                        if (policy.default_model) |m| allocator.free(m);
                        policy.default_model = try parseString(allocator, val);
                    }
                },
                .Prompt => {
                    if (prompts_list.items.len == 0) continue; // Should not happen if well-formed
                    var prompt = &prompts_list.items[prompts_list.items.len - 1];

                    if (std.mem.eql(u8, key, "path")) {
                        allocator.free(prompt.path); // Free the initial empty string or previous overwrite
                        prompt.path = try parseString(allocator, val);
                    } else if (std.mem.eql(u8, key, "prompt_id")) {
                        if (prompt.prompt_id) |id| allocator.free(id);
                        prompt.prompt_id = try parseString(allocator, val);
                    } else if (std.mem.eql(u8, key, "model")) {
                        if (prompt.model) |m| allocator.free(m);
                        prompt.model = try parseString(allocator, val);
                    } else if (std.mem.eql(u8, key, "tags")) {
                        if (prompt.tags) |*t| {
                            // Clear existing tags logic?
                            var it = t.iterator();
                            while (it.next()) |entry| {
                                allocator.free(entry.key_ptr.*);
                                allocator.free(entry.value_ptr.*);
                            }
                            t.deinit();
                        }
                        prompt.tags = try parseInlineTable(allocator, val);
                    }
                },
                .None => {},
            }
        }
    }

    if (prompts_list.items.len > 0) {
        policy.prompts = try prompts_list.toOwnedSlice();
    } else {
        prompts_list.deinit();
    }

    return policy;
}

fn parseString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\"'");
    return allocator.dupe(u8, trimmed);
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
        const clean = std.mem.trim(u8, token, " \t\"'");
        try list.append(try allocator.dupe(u8, clean));
    }
    return list.toOwnedSlice();
}

fn parseInlineTable(allocator: std.mem.Allocator, raw_val: []const u8) !std.StringHashMap([]const u8) {
    // Expected format: { key = "value", k2 = "v2" }
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    const trimmed = std.mem.trim(u8, raw_val, "{}");
    var it = std.mem.tokenizeScalar(u8, trimmed, ',');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_idx| {
            const key = std.mem.trim(u8, pair[0..eq_idx], " \t");
            const val = std.mem.trim(u8, pair[eq_idx + 1 ..], " \t");

            const key_dupe = try allocator.dupe(u8, key);
            const val_dupe = try parseString(allocator, val);

            if (try map.put(key_dupe, val_dupe)) |old_entry| {
                allocator.free(old_entry.key_ptr.*);
                allocator.free(old_entry.value_ptr.*);
            }
        }
    }
    return map;
}
