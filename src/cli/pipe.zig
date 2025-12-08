const std = @import("std");
const engine = @import("../core/engine.zig");
const pricing = @import("../pricing.zig");

pub const PipeMode = enum { tokens, price };

pub const PipeError = error{
    PipeFatal,
    StreamTooLong,
    QueueClosed,
    QuotaExceeded, // New error
} || std.fs.File.WriteError || std.fs.File.ReadError || std.mem.Allocator.Error || std.Thread.SpawnError;

pub const PipeQuota = struct {
    max_tokens: usize = 0, // 0 = unlimited
    max_cost_usd: f64 = 0.0,
};

pub const PipeSummary = struct {
    lines_processed: usize = 0,
    lines_failed: usize = 0,
    total_tokens_in: usize = 0,
    total_tokens_out: usize = 0,
    total_tokens: usize = 0,
    total_cost_usd: f64 = 0.0,
    quota_hit: bool = false,
};

pub const PipeOptions = struct {
    allocator: std.mem.Allocator,
    stdin: std.io.AnyReader,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,

    // Config
    model: []const u8,
    field: []const u8,
    mode: PipeMode,
    fail_on_error: bool,
    max_line_bytes: usize = 10 * 1024 * 1024, // 10MB default limit
    special_mode: engine.SpecialMode = .strict,
    workers: usize = 1,

    // Engine Config
    cfg: engine.TokenizerConfig,
    db: *pricing.PricingDB,
    accuracy: []const u8 = "unknown",

    // Output Field Names
    field_tokens_in: []const u8 = "tokens_in",
    field_tokens_out: []const u8 = "tokens_out",
    field_cost: []const u8 = "cost_usd",
    field_accuracy: []const u8 = "accuracy",

    // Quota & Summary
    quota: PipeQuota = .{},
    show_summary: bool = false,
};

const ProcessResult = struct {
    rc: enum { ok, skip, fatal },
    tokens_in: usize = 0,
    tokens_out: usize = 0,
    cost: f64 = 0.0,
};

// --- Parallel Infrastructure ---

const Job = struct {
    line_no: usize,
    line: []u8, // owned heap copy
};

const JobQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    jobs: std.ArrayList(Job),
    closed: bool,

    pub fn init(allocator: std.mem.Allocator) JobQueue {
        return .{
            .jobs = std.ArrayList(Job).init(allocator),
            .closed = false,
        };
    }

    pub fn deinit(self: *JobQueue, alloc: std.mem.Allocator) void {
        // Free any remaining queued jobs (e.g. on early exit).
        // In the normal success path the queue is empty here.
        for (self.jobs.items) |job| {
            alloc.free(job.line);
        }
        self.jobs.deinit();
    }

    pub fn push(self: *JobQueue, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return error.QueueClosed;

        try self.jobs.append(job);
        self.cond.signal();
    }

    pub fn pop(self: *JobQueue) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.jobs.items.len == 0 and !self.closed) {
            self.cond.wait(&self.mutex);
        }
        if (self.jobs.items.len == 0) {
            return null; // empty + closed
        }

        return self.jobs.pop();
    }

    pub fn close(self: *JobQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.closed = true;
        self.cond.broadcast();
    }
};

const SharedIo = struct {
    stdout_mutex: std.Thread.Mutex = .{},
    stderr_mutex: std.Thread.Mutex = .{},
};

const WorkerContext = struct {
    opts: *const PipeOptions,
    queue: *JobQueue,
    io: *SharedIo,
    summary: *PipeSummary,
    summary_mutex: *std.Thread.Mutex,
};

// --- Execution ---

pub fn run(opts: PipeOptions) PipeError!void {
    // Quota requires single threaded deterministic enforcement
    const has_quota = (opts.quota.max_tokens > 0 or opts.quota.max_cost_usd > 0.0);
    if (opts.workers <= 1 or has_quota) {
        return runSingleThreaded(opts);
    } else {
        return runParallel(opts);
    }
}

fn runSingleThreaded(opts: PipeOptions) PipeError!void {
    var buf_reader = std.io.bufferedReader(opts.stdin);
    var in_stream = buf_reader.reader();

    var buf_writer = std.io.bufferedWriter(opts.stdout);
    var out_stream = buf_writer.writer();

    var line_buf = std.ArrayList(u8).init(opts.allocator);
    defer line_buf.deinit();

    var line_number: usize = 0;

    // Reuse arena for per-line parsing logic
    var line_arena = std.heap.ArenaAllocator.init(opts.allocator);
    defer line_arena.deinit();

    var summary = PipeSummary{};

    while (true) {
        line_buf.clearRetainingCapacity();
        _ = line_arena.reset(.retain_capacity);

        const read_result = in_stream.streamUntilDelimiter(line_buf.writer(), '\n', opts.max_line_bytes);
        var is_eof = false;

        if (read_result) {
            // success
        } else |err| {
            if (err == error.EndOfStream) {
                is_eof = true;
                if (line_buf.items.len == 0) break;
            } else if (err == error.StreamTooLong) {
                logErrorSingleThread(opts.stderr, line_number + 1, "line too long", err);
                summary.lines_failed += 1; // Count as failed/processed?

                if (opts.fail_on_error) return error.PipeFatal;

                // Skip logic
                var dump_buf: [1024]u8 = undefined;
                while (true) {
                    const n = in_stream.read(&dump_buf) catch break;
                    if (n == 0) break;
                    if (std.mem.indexOfScalar(u8, dump_buf[0..n], '\n')) |_| break;
                }
                line_number += 1;
                continue;
            } else {
                return error.PipeFatal;
            }
        }

        line_number += 1;
        if (line_buf.items.len == 0) {
            if (is_eof) break;
            continue;
        }

        const res = processLine(opts, line_arena.allocator(), line_buf.items, line_number, out_stream, opts.stderr, false);
        summary.lines_processed += 1;

        switch (res.rc) {
            .ok => {
                out_stream.writeByte('\n') catch return error.PipeFatal;
                summary.total_tokens_in += res.tokens_in;
                summary.total_tokens_out += res.tokens_out;
                summary.total_tokens += res.tokens_in + res.tokens_out;
                summary.total_cost_usd += res.cost;
            },
            .skip => {
                // Skipped lines tellen we mee als failed, zodat summary aangeeft hoeveel
                // records niet succesvol verrijkt zijn (bijv. invalid JSON).
                summary.lines_failed += 1;
            },
            .fatal => return error.PipeFatal,
        }

        // Quota Check
        if (opts.quota.max_tokens > 0 and summary.total_tokens >= opts.quota.max_tokens) {
            summary.quota_hit = true;
            if (opts.show_summary) {
                 opts.stderr.print(
                    "summary (partial, quota exceeded): lines={d} (failed={d}) tokens={d} (in={d} out={d}) cost=${d:.6}\n",
                    .{ summary.lines_processed, summary.lines_failed, summary.total_tokens, summary.total_tokens_in, summary.total_tokens_out, summary.total_cost_usd }
                ) catch {};
            }
            return error.QuotaExceeded;
        }
        if (opts.quota.max_cost_usd > 0.0 and summary.total_cost_usd >= opts.quota.max_cost_usd) {
            summary.quota_hit = true;
            if (opts.show_summary) {
                 opts.stderr.print(
                    "summary (partial, quota exceeded): lines={d} (failed={d}) tokens={d} (in={d} out={d}) cost=${d:.6}\n",
                    .{ summary.lines_processed, summary.lines_failed, summary.total_tokens, summary.total_tokens_in, summary.total_tokens_out, summary.total_cost_usd }
                ) catch {};
            }
            return error.QuotaExceeded;
        }

        if (is_eof) break;
    }
    buf_writer.flush() catch return error.PipeFatal;

    if (opts.show_summary) {
        opts.stderr.print(
            "summary: lines={d} (failed={d}) tokens={d} (in={d} out={d}) cost=${d:.6}\n",
            .{ summary.lines_processed, summary.lines_failed, summary.total_tokens, summary.total_tokens_in, summary.total_tokens_out, summary.total_cost_usd }
        ) catch {};
    }
}

fn runParallel(opts: PipeOptions) PipeError!void {
    var queue = JobQueue.init(opts.allocator);
    defer queue.deinit(opts.allocator);

    var io = SharedIo{};
    var summary = PipeSummary{};
    var summary_mutex = std.Thread.Mutex{};

    const worker_count = opts.workers;
    var workers = try opts.allocator.alloc(std.Thread, worker_count);
    defer opts.allocator.free(workers);

    var contexts = try opts.allocator.alloc(WorkerContext, worker_count);
    defer opts.allocator.free(contexts);

    // Spawn workers
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        contexts[i] = .{
            .opts = &opts,
            .queue = &queue,
            .io = &io,
            .summary = &summary,
            .summary_mutex = &summary_mutex,
        };
        workers[i] = try std.Thread.spawn(.{}, workerMain, .{ &contexts[i] });
    }

    // Producer Loop
    var buf_reader = std.io.bufferedReader(opts.stdin);
    var in_stream = buf_reader.reader();

    var line_buf = std.ArrayList(u8).init(opts.allocator);
    defer line_buf.deinit();

    var line_number: usize = 0;

    // Use a small local arena for temporary buffers if needed, or main allocator?
    // Main allocator is fine for reading lines.

    producer_loop: while (true) {
        line_buf.clearRetainingCapacity();

        const read_result = in_stream.streamUntilDelimiter(line_buf.writer(), '\n', opts.max_line_bytes);
        var is_eof = false;

        if (read_result) {
            // success
        } else |err| {
            if (err == error.EndOfStream) {
                is_eof = true;
                if (line_buf.items.len == 0) break :producer_loop;
            } else if (err == error.StreamTooLong) {
                logError(&io, opts.stderr, line_number + 1, "line too long", err);

                summary_mutex.lock();
                summary.lines_failed += 1;
                summary_mutex.unlock();

                if (opts.fail_on_error) return error.PipeFatal;

                // Skip remainder
                var dump_buf: [1024]u8 = undefined;
                while (true) {
                    const n = in_stream.read(&dump_buf) catch break;
                    if (n == 0) break;
                    if (std.mem.indexOfScalar(u8, dump_buf[0..n], '\n')) |_| break;
                }
                line_number += 1;
                continue :producer_loop;
            } else {
                return error.PipeFatal;
            }
        }

        if (line_buf.items.len > 0) {
            line_number += 1;
            // Provide owned copy to worker
            const line_copy = try opts.allocator.dupe(u8, line_buf.items);
            // Push to queue
            try queue.push(.{ .line_no = line_number, .line = line_copy });
        }

        if (is_eof) break :producer_loop;
    }

    // Close queue to signal workers
    queue.close();

    // Join workers
    i = 0;
    while (i < worker_count) : (i += 1) {
        workers[i].join();
    }

    if (opts.show_summary) {
        opts.stderr.print(
            "summary: lines={d} (failed={d}) tokens={d} (in={d} out={d}) cost=${d:.6}\n",
            .{ summary.lines_processed, summary.lines_failed, summary.total_tokens, summary.total_tokens_in, summary.total_tokens_out, summary.total_cost_usd }
        ) catch {};
    }
}


fn workerMain(ctx: *WorkerContext) void {
    var arena = std.heap.ArenaAllocator.init(ctx.opts.allocator);
    defer arena.deinit();

    while (true) {
        const maybe_job = ctx.queue.pop();
        if (maybe_job == null) break;

        const job = maybe_job.?;
        // Ensure line is freed (it was duped by producer)
        defer ctx.opts.allocator.free(job.line);
        const line = job.line;

        // Reset arena for this job
        _ = arena.reset(.retain_capacity);

        // Prep output buffer
        var out_buf = std.ArrayList(u8).init(arena.allocator());
        // No deinit needed as it's arena allocated?
        // Wait, ArrayList internal memory is allocator-bound.
        // If we init with arena.allocator(), deinit is optional if we reset arena.
        // But explicit deinit doesn't hurt.
        defer out_buf.deinit();

        const out_writer = out_buf.writer();

        // Process
        const res = processLine(
            ctx.opts.*,
            arena.allocator(),
            line,
            job.line_no,
            out_writer,
            ctx.io,
            true // is_parallel
        );

        // Update summary
        ctx.summary_mutex.lock();
        defer ctx.summary_mutex.unlock();

        ctx.summary.lines_processed += 1;

        switch (res.rc) {
            .ok => {
                // Stats bijwerken voordat we de IO-lock pakken, zodat we de stdout-mutex
                // zo kort mogelijk vasthouden. Minder kans dat writers elkaar blokkeren.
                ctx.summary.total_tokens_in += res.tokens_in;
                ctx.summary.total_tokens_out += res.tokens_out;
                ctx.summary.total_tokens += res.tokens_in + res.tokens_out;
                ctx.summary.total_cost_usd += res.cost;
                // unlocked via defer

                ctx.io.stdout_mutex.lock();
                defer ctx.io.stdout_mutex.unlock();

                // out_buf has proper JSON. Add newline.
                _ = ctx.opts.stdout.write(out_buf.items) catch {};
                _ = ctx.opts.stdout.writeByte('\n') catch {};
            },
            .skip => {
                ctx.summary.lines_failed += 1;
            },
            .fatal => {
                ctx.summary.lines_failed += 1;
                // In parallel mode, we treat fatal errors as "hard failure for this line",
                // but we do not abort the entire stream to keep the batch processing active.
                // --fail-on-error only guarantees abort in single-threaded mode.
            }
        }
    }
}

// Unified process line for both modes
// For single threaded: io_ctx is opts.stderr (writer), is_parallel=false
// For parallel: io_ctx is *SharedIo, is_parallel=true
fn processLine(
    opts: PipeOptions,
    line_alloc: std.mem.Allocator,
    line: []const u8,
    line_number: usize,
    out_stream: anytype,
    io_ctx: anytype,
    comptime is_parallel: bool,
) ProcessResult {
    // 1. Parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, line_alloc, line, .{}) catch |err| {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "invalid JSON", err)
        else logErrorSingleThread(io_ctx, line_number, "invalid JSON", err);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "JSON root is not object", null)
        else logErrorSingleThread(io_ctx, line_number, "JSON root is not object", null);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    }

    // 2. Extract Text Field
    const text_val = parsed.value.object.get(opts.field) orelse {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "missing required field", null)
        else logErrorSingleThread(io_ctx, line_number, "missing required field", null);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    };

    if (text_val != .string) {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "field is not a string", null)
        else logErrorSingleThread(io_ctx, line_number, "field is not a string", null);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    }
    const text = text_val.string;

    // 3. Process (Tokenize)
    const tok_res = engine.estimateTokens(
        opts.allocator, // Main allocator for engine tables
        opts.cfg,
        text,
        opts.special_mode,
    ) catch |err| {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "tokenization failed", err)
        else logErrorSingleThread(io_ctx, line_number, "tokenization failed", err);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    };

    // 4. Augment JSON
    parsed.value.object.put(opts.field_tokens_in, std.json.Value{ .integer = @intCast(tok_res.tokens) }) catch |err| {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "JSON mutate failed (tokens_in)", err)
        else logErrorSingleThread(io_ctx, line_number, "JSON mutate failed (tokens_in)", err);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    };

    // Inject accuracy
    parsed.value.object.put(opts.field_accuracy, std.json.Value{ .string = opts.accuracy }) catch |err| {
         if (is_parallel) logError(io_ctx, opts.stderr, line_number, "JSON mutate failed (accuracy)", err)
         else logErrorSingleThread(io_ctx, line_number, "JSON mutate failed (accuracy)", err);

         if (opts.fail_on_error) return .{ .rc = .fatal };
         return .{ .rc = .skip };
    };

    var total_tokens_usage: usize = tok_res.tokens;
    const total_tokens_in: usize = tok_res.tokens;
    var total_tokens_out: usize = 0;
    var total_cost: f64 = 0.0;

    if (opts.mode == .price) {
        if (parsed.value.object.get(opts.field_tokens_out)) |val| {
            switch (val) {
                .integer => |i| total_tokens_out = @intCast(i),
                else => {},
            }
        }
        total_tokens_usage += total_tokens_out;

        parsed.value.object.put(opts.field_tokens_out, std.json.Value{ .integer = @intCast(total_tokens_out) }) catch |err| {
            if (is_parallel) logError(io_ctx, opts.stderr, line_number, "JSON mutate failed (tokens_out)", err)
            else logErrorSingleThread(io_ctx, line_number, "JSON mutate failed (tokens_out)", err);

            if (opts.fail_on_error) return .{ .rc = .fatal };
            return .{ .rc = .skip };
        };

        const cost_res = engine.estimateCost(opts.db, opts.model, total_tokens_in, total_tokens_out, 0) catch |err| {
             if (is_parallel) logError(io_ctx, opts.stderr, line_number, "pricing failed", err)
             else logErrorSingleThread(io_ctx, line_number, "pricing failed", err);

             if (opts.fail_on_error) return .{ .rc = .fatal };
             return .{ .rc = .skip };
        };
        total_cost = cost_res.cost_total;

        parsed.value.object.put(opts.field_cost, std.json.Value{ .float = cost_res.cost_total }) catch |err| {
            if (is_parallel) logError(io_ctx, opts.stderr, line_number, "JSON mutate failed (cost)", err)
            else logErrorSingleThread(io_ctx, line_number, "JSON mutate failed (cost)", err);

            if (opts.fail_on_error) return .{ .rc = .fatal };
            return .{ .rc = .skip };
        };
    }

    // 5. Write JSON
    std.json.stringify(parsed.value, .{}, out_stream) catch |err| {
        if (is_parallel) logError(io_ctx, opts.stderr, line_number, "JSON encode failed", err)
        else logErrorSingleThread(io_ctx, line_number, "JSON encode failed", err);

        if (opts.fail_on_error) return .{ .rc = .fatal };
        return .{ .rc = .skip };
    };

    return .{
        .rc = .ok,
        .tokens_in = total_tokens_in,
        .tokens_out = total_tokens_out,
        .cost = total_cost
    };
}

// Thread-safe logging
fn logError(io: *SharedIo, stderr: std.io.AnyWriter, line_number: usize, msg: []const u8, err: ?anyerror) void {
    io.stderr_mutex.lock();
    defer io.stderr_mutex.unlock();
    if (err) |e| {
        stderr.print("line {d}: error: {s} ({s})\n", .{line_number, msg, @errorName(e)}) catch {};
    } else {
        stderr.print("line {d}: error: {s}\n", .{line_number, msg}) catch {};
    }
}

// Single thread logging
fn logErrorSingleThread(stderr: std.io.AnyWriter, line_number: usize, msg: []const u8, err: ?anyerror) void {
    if (err) |e| {
        stderr.print("line {d}: error: {s} ({s})\n", .{line_number, msg, @errorName(e)}) catch {};
    } else {
        stderr.print("line {d}: error: {s}\n", .{line_number, msg}) catch {};
    }
}
