const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Repo = struct {
    owner: []const u8,
    name: []const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (
            ctx: *anyopaque,
            allocator: Allocator,
            method: std.http.Method,
            url: []const u8,
            headers: []const Header,
            body: ?[]const u8,
            max_body_bytes: usize,
        ) anyerror!Response,
        deinit: ?*const fn (ctx: *anyopaque) void = null,
    };

    pub fn request(
        self: Transport,
        allocator: Allocator,
        method: std.http.Method,
        url: []const u8,
        headers: []const Header,
        body: ?[]const u8,
        max_body_bytes: usize,
    ) !Response {
        return self.vtable.request(self.ctx, allocator, method, url, headers, body, max_body_bytes);
    }

    pub fn deinit(self: Transport) void {
        if (self.vtable.deinit) |f| f(self.ctx);
    }
};

pub const Options = struct {
    /// For GitHub Enterprise Server you can override this.
    api_base: []const u8 = "https://api.github.com",
    /// GitHub recommends setting a UA; also helps with debugging on their side.
    user_agent: []const u8 = "llm-cost",
    /// GitHub currently recommends this API version header.
    api_version: []const u8 = "2022-11-28",

    /// Safety limits
    max_body_bytes: usize = 1024 * 1024, // 1 MiB per response
    max_pages: u8 = 10, // up to 1000 comments with per_page=100
};

pub const ApiError = error{
    NoToken,
    Unauthorized,
    Forbidden,
    NotFound,
    ValidationFailed, // 422 (spam/validation)
    RateLimited, // 429 (rare) or secondary limits surfaced as 403 text
    BadResponse,
    Network,
};

pub const Comment = struct {
    id: u64,
    body: []const u8, // owned

    pub fn deinit(self: *Comment, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

pub const UpsertResult = struct {
    action: enum { created, updated },
    comment_id: u64,
};

pub const GitHubApi = struct {
    allocator: Allocator,
    repo: Repo,
    token: []const u8, // borrowed (caller owns)
    opts: Options,
    transport: Transport,

    pub fn init(
        allocator: Allocator,
        repo: Repo,
        token: []const u8,
        transport: Transport,
        opts: Options,
    ) GitHubApi {
        return .{
            .allocator = allocator,
            .repo = repo,
            .token = token,
            .transport = transport,
            .opts = opts,
        };
    }

    pub fn deinit(self: *GitHubApi) void {
        self.transport.deinit();
    }

    fn authHeader(self: *GitHubApi, allocator: Allocator) ![]const u8 {
        if (self.token.len == 0) return ApiError.NoToken;
        return try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.token});
    }

    fn buildUrl(
        self: *GitHubApi,
        allocator: Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) ![]const u8 {
        _ = self;
        return try std.fmt.allocPrint(allocator, "{s}" ++ fmt, args);
    }

    fn commonHeaders(
        self: *GitHubApi,
        allocator: Allocator,
        has_json_body: bool,
    ) !struct { headers: []Header, auth_alloc: []const u8 } {
        const auth = try self.authHeader(allocator);

        var list = std.ArrayList(Header).init(allocator);
        errdefer list.deinit();

        try list.append(.{ .name = "Accept", .value = "application/vnd.github+json" });
        try list.append(.{ .name = "X-GitHub-Api-Version", .value = self.opts.api_version });

        try list.append(.{ .name = "Authorization", .value = auth });
        try list.append(.{ .name = "User-Agent", .value = self.opts.user_agent });

        if (has_json_body) {
            try list.append(.{ .name = "Content-Type", .value = "application/json" });
        }

        return .{ .headers = try list.toOwnedSlice(), .auth_alloc = auth };
    }

    fn mapStatus(self: *GitHubApi, status: u16, body: []const u8) ApiError!void {
        _ = self;
        switch (status) {
            200, 201 => return,
            401 => return ApiError.Unauthorized,
            403 => {
                // Secondary limits sometimes surface as 403 with explanatory text.
                if (std.mem.indexOf(u8, body, "secondary rate") != null) return ApiError.RateLimited;
                return ApiError.Forbidden;
            },
            404 => return ApiError.NotFound,
            422 => return ApiError.ValidationFailed,
            429 => return ApiError.RateLimited,
            else => return ApiError.BadResponse,
        }
    }

    fn jsonBodyWithFieldBody(allocator: Allocator, markdown: []const u8) ![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();

        var jw = std.json.writeStream(out.writer(), .{});
        try jw.beginObject();
        try jw.objectField("body");
        try jw.write(markdown);
        try jw.endObject();

        return try out.toOwnedSlice();
    }

    fn parseComment(allocator: Allocator, json_bytes: []const u8) !Comment {
        const T = struct {
            id: u64,
            body: []const u8,
        };
        var parsed = try std.json.parseFromSlice(T, allocator, json_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        return .{
            .id = parsed.value.id,
            .body = try allocator.dupe(u8, parsed.value.body),
        };
    }

    fn parseCommentList(allocator: Allocator, json_bytes: []const u8) ![]Comment {
        const Item = struct {
            id: u64,
            body: []const u8,
        };

        var parsed = try std.json.parseFromSlice([]Item, allocator, json_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var out = try allocator.alloc(Comment, parsed.value.len);
        errdefer {
            for (out) |*c| c.deinit(allocator);
            allocator.free(out);
        }

        for (parsed.value, 0..) |it, i| {
            out[i] = .{
                .id = it.id,
                .body = try allocator.dupe(u8, it.body),
            };
        }
        return out;
    }

    pub fn listIssueCommentsPage(
        self: *GitHubApi,
        allocator: Allocator,
        issue_number: u32,
        page: u32,
    ) ![]Comment {
        const url = try self.buildUrl(
            allocator,
            "/repos/{s}/{s}/issues/{d}/comments?per_page=100&page={d}",
            .{ self.opts.api_base, self.repo.owner, self.repo.name, issue_number, page },
        );
        defer allocator.free(url);

        const hdr = try self.commonHeaders(allocator, false);
        defer allocator.free(hdr.auth_alloc);
        defer allocator.free(hdr.headers);

        var resp = self.transport.request(
            allocator,
            .GET,
            url,
            hdr.headers,
            null,
            self.opts.max_body_bytes,
        ) catch return ApiError.Network;
        defer resp.deinit(allocator);

        try self.mapStatus(resp.status, resp.body);

        return try parseCommentList(allocator, resp.body);
    }

    pub const StickyRef = struct {
        comment_id: u64,
    };

    /// Finds the last comment containing `marker` (sticky marker).
    /// GitHub returns comments in ascending ID by default.
    pub fn findStickyIssueComment(
        self: *GitHubApi,
        allocator: Allocator,
        issue_number: u32,
        marker: []const u8,
    ) !?StickyRef {
        var page: u32 = 1;
        var found: ?u64 = null;

        var pages_left: u8 = self.opts.max_pages;
        while (pages_left > 0) : (pages_left -= 1) {
            const comments = try self.listIssueCommentsPage(allocator, issue_number, page);
            defer {
                for (comments) |*c| c.deinit(allocator);
                allocator.free(comments);
            }

            if (comments.len == 0) break;

            for (comments) |c| {
                if (std.mem.indexOf(u8, c.body, marker) != null) {
                    found = c.id; // keep last seen
                }
            }

            page += 1;
        }

        if (found) |id| return .{ .comment_id = id };
        return null;
    }

    /// POST /repos/{owner}/{repo}/issues/{issue_number}/comments
    pub fn createIssueComment(
        self: *GitHubApi,
        allocator: Allocator,
        issue_number: u32,
        markdown: []const u8,
    ) !Comment {
        const url = try self.buildUrl(
            allocator,
            "/repos/{s}/{s}/issues/{d}/comments",
            .{ self.opts.api_base, self.repo.owner, self.repo.name, issue_number },
        );
        defer allocator.free(url);

        const body_json = try jsonBodyWithFieldBody(allocator, markdown);
        defer allocator.free(body_json);

        const hdr = try self.commonHeaders(allocator, true);
        defer allocator.free(hdr.auth_alloc);
        defer allocator.free(hdr.headers);

        var resp = self.transport.request(
            allocator,
            .POST,
            url,
            hdr.headers,
            body_json,
            self.opts.max_body_bytes,
        ) catch return ApiError.Network;
        defer resp.deinit(allocator);

        try self.mapStatus(resp.status, resp.body);

        return try parseComment(allocator, resp.body);
    }

    /// PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}
    pub fn updateIssueComment(
        self: *GitHubApi,
        allocator: Allocator,
        comment_id: u64,
        markdown: []const u8,
    ) !Comment {
        const url = try self.buildUrl(
            allocator,
            "/repos/{s}/{s}/issues/comments/{d}",
            .{ self.opts.api_base, self.repo.owner, self.repo.name, comment_id },
        );
        defer allocator.free(url);

        const body_json = try jsonBodyWithFieldBody(allocator, markdown);
        defer allocator.free(body_json);

        const hdr = try self.commonHeaders(allocator, true);
        defer allocator.free(hdr.auth_alloc);
        defer allocator.free(hdr.headers);

        var resp = self.transport.request(
            allocator,
            .PATCH,
            url,
            hdr.headers,
            body_json,
            self.opts.max_body_bytes,
        ) catch return ApiError.Network;
        defer resp.deinit(allocator);

        try self.mapStatus(resp.status, resp.body);

        return try parseComment(allocator, resp.body);
    }

    /// Upserts a single sticky comment by marker.
    pub fn upsertStickyIssueComment(
        self: *GitHubApi,
        allocator: Allocator,
        issue_number: u32,
        marker: []const u8,
        markdown: []const u8,
    ) !UpsertResult {
        const existing = try self.findStickyIssueComment(allocator, issue_number, marker);
        if (existing) |ref| {
            var updated = try self.updateIssueComment(allocator, ref.comment_id, markdown);
            defer updated.deinit(allocator);
            return .{ .action = .updated, .comment_id = updated.id };
        } else {
            var created = try self.createIssueComment(allocator, issue_number, markdown);
            defer created.deinit(allocator);
            return .{ .action = .created, .comment_id = created.id };
        }
    }
};

/// ------------------------------
/// Default std.http-based transport
/// ------------------------------
pub const StdHttpTransport = struct {
    allocator: Allocator,
    client: std.http.Client,
    server_header_buffer: []u8,

    pub fn init(allocator: Allocator, header_buf_bytes: usize) !StdHttpTransport {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
            .server_header_buffer = try allocator.alloc(u8, header_buf_bytes),
        };
    }

    pub fn deinit(self: *StdHttpTransport) void {
        self.client.deinit();
        self.allocator.free(self.server_header_buffer);
    }

    fn requestImpl(
        ctx: *anyopaque,
        allocator: Allocator,
        method: std.http.Method,
        url: []const u8,
        headers: []const Header,
        body: ?[]const u8,
        max_body_bytes: usize,
    ) anyerror!Response {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ctx));

        // Convert Header -> std.http.Header
        var extra = try allocator.alloc(std.http.Header, headers.len);
        defer allocator.free(extra);
        for (headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

        var resp_body = std.ArrayList(u8).init(allocator);
        errdefer resp_body.deinit();

        // NOTE: Uses std.http.Client.fetch with dynamic response storage.
        const result = try self.client.fetch(.{
            .method = method,
            .location = .{ .url = url },
            .extra_headers = extra,
            .payload = body,
            .response_storage = .{ .dynamic = &resp_body },
            .server_header_buffer = self.server_header_buffer,
        });

        const status_u16: u16 = @intFromEnum(result.status);
        const owned = try resp_body.toOwnedSlice();

        // Enforce upper bound (dynamic storage may overrun if caller sets too high)
        if (owned.len > max_body_bytes) {
            allocator.free(owned);
            return ApiError.BadResponse;
        }

        return .{ .status = status_u16, .body = owned };
    }

    pub fn transport(self: *StdHttpTransport) Transport {
        return .{
            .ctx = self,
            .vtable = &.{
                .request = requestImpl,
                .deinit = struct {
                    fn f(p: *anyopaque) void {
                        const s: *StdHttpTransport = @ptrCast(@alignCast(p));
                        s.deinit();
                    }
                }.f,
            },
        };
    }
};

/// ------------------------------
/// Unit tests via MockTransport
/// ------------------------------
const MockTransport = struct {
    pub const Call = struct {
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,

        pub fn deinit(self: *Call, a: Allocator) void {
            a.free(self.url);
            if (self.body) |b| a.free(b);
        }
    };

    pub const MockResponse = struct {
        status: u16,
        body: []const u8,
    };

    allocator: Allocator,
    calls: std.ArrayList(Call),
    responses: std.ArrayList(MockResponse),

    pub fn init(allocator: Allocator) MockTransport {
        return .{
            .allocator = allocator,
            .calls = std.ArrayList(Call).init(allocator),
            .responses = std.ArrayList(MockResponse).init(allocator),
        };
    }

    pub fn deinit(self: *MockTransport) void {
        for (self.calls.items) |*c| c.deinit(self.allocator);
        self.calls.deinit();
        self.responses.deinit();
    }

    pub fn pushResponse(self: *MockTransport, status: u16, body: []const u8) !void {
        try self.responses.append(.{ .status = status, .body = body });
    }

    fn requestImpl(
        ctx: *anyopaque,
        allocator: Allocator,
        method: std.http.Method,
        url: []const u8,
        _: []const Header,
        body: ?[]const u8,
        _: usize,
    ) anyerror!Response {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));

        const url_dup = try allocator.dupe(u8, url);
        const body_dup = if (body) |b| try allocator.dupe(u8, b) else null;

        try self.calls.append(.{
            .method = method,
            .url = url_dup,
            .body = body_dup,
        });

        if (self.responses.items.len == 0) return ApiError.BadResponse;

        const spec = self.responses.orderedRemove(0);
        return .{
            .status = spec.status,
            .body = try allocator.dupe(u8, spec.body),
        };
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{
            .ctx = self,
            .vtable = &.{
                .request = requestImpl,
                .deinit = null,
            },
        };
    }
};

test "GitHubApi.upsertStickyIssueComment creates when missing" {
    const a = std.testing.allocator;

    var mock = MockTransport.init(a);
    defer mock.deinit();

    // 1) list comments -> empty array
    try mock.pushResponse(200, "[]");
    // 2) create -> returns comment
    try mock.pushResponse(201, "{\"id\":123,\"body\":\"ok\"}");

    var api = GitHubApi.init(
        a,
        .{ .owner = "o", .name = "r" },
        "tok",
        mock.transport(),
        .{ .api_base = "https://api.github.com" },
    );

    const marker = "<!-- llm-cost-action-comment -->";
    const body = marker ++ "\nhello";

    const res = try api.upsertStickyIssueComment(a, 77, marker, body);
    try std.testing.expect(res.action == .created);
    try std.testing.expectEqual(@as(u64, 123), res.comment_id);

    try std.testing.expectEqual(@as(usize, 2), mock.calls.items.len);
    try std.testing.expect(mock.calls.items[0].method == .GET);
    try std.testing.expect(mock.calls.items[1].method == .POST);
}

test "GitHubApi.upsertStickyIssueComment updates when present" {
    const a = std.testing.allocator;

    var mock = MockTransport.init(a);
    defer mock.deinit();

    const marker = "<!-- llm-cost-action-comment -->";

    // 1) list comments -> contains marker (id 999)
    try mock.pushResponse(200, "[{\"id\":999,\"body\":\"hi " ++ marker ++ "\"}]");
    // 1b) list comments page 2 -> empty (signals end)
    try mock.pushResponse(200, "[]");
    // 2) patch -> returns updated comment
    try mock.pushResponse(200, "{\"id\":999,\"body\":\"updated\"}");

    var api = GitHubApi.init(
        a,
        .{ .owner = "o", .name = "r" },
        "tok",
        mock.transport(),
        .{ .api_base = "https://api.github.com" },
    );

    const res = try api.upsertStickyIssueComment(a, 77, marker, marker ++ "\nnew");
    try std.testing.expect(res.action == .updated);
    try std.testing.expectEqual(@as(u64, 999), res.comment_id);

    try std.testing.expectEqual(@as(usize, 3), mock.calls.items.len);
    try std.testing.expect(mock.calls.items[0].method == .GET);
    try std.testing.expect(mock.calls.items[1].method == .GET);
    try std.testing.expect(mock.calls.items[2].method == .PATCH);
    try std.testing.expect(std.mem.indexOf(u8, mock.calls.items[2].url, "/issues/comments/999") != null);
}
