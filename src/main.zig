const std = @import("std");

// Module imports
pub const tokenizer = @import("tokenizer/mod.zig");
pub const pricing = @import("pricing.zig");
pub const engine = @import("core/engine.zig");
pub const pipe = @import("pipe.zig");
pub const report = @import("report.zig");

/// llm-cost: Token counting and cost estimation for LLM API calls
///
/// Usage:
///   llm-cost count --model gpt-4 --text "Hello, world!"
///   llm-cost count --model gpt-4 --file input.txt
///   llm-cost estimate --model gpt-4 --input-tokens 1000 --output-tokens 500
///   cat file.txt | llm-cost count --model gpt-4
///
/// Commands:
///   count     Count tokens in text
///   estimate  Estimate cost for token counts
///   models    List supported models
///   version   Show version information
///
/// For more information: https://github.com/your-org/llm-cost
const version_str = "0.6.1";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(2);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printVersion();
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "pipe")) {
        try runPipe(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "tokenizer-report")) {
        try runReport(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "count")) {
        try runCount(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "estimate")) {
        try runEstimate(allocator, args[2..]);
        return;
    }
    // ...
    if (std.mem.eql(u8, command, "models")) {
        try runModels();
        return;
    }

    if (std.mem.eql(u8, command, "version")) {
        try printVersion();
        return;
    }

    std.debug.print("Unknown command: {s}\n", .{command});
    std.debug.print("Run 'llm-cost --help' for usage.\n", .{});
    std.process.exit(2);
}

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("llm-cost {s}\n", .{version_str});
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: llm-cost <command> [options]
        \\
        \\Commands:
        \\  count      Count tokens in text
        \\  pipe       Stream from stdin (NDJSON/Text)
        \\  tokenizer-report  Generate analytics report
        \\  estimate   Estimate cost for token counts
        \\  models     List supported models
        \\  version    Show version information
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -v, --version  Show version
        \\
        \\Examples:
        \\  llm-cost count --model gpt-4 --text "Hello, world!"
        \\  llm-cost count --model gpt-4 --file input.txt
        \\  llm-cost estimate --model gpt-4 --input-tokens 1000 --output-tokens 500
        \\  cat file.txt | llm-cost count --model gpt-4
        \\
        \\For more information: https://github.com/your-org/llm-cost
        \\
    );
}

fn runCount(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var format: []const u8 = "text";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                std.process.exit(2);
            }
            model = args[i];
        } else if (std.mem.eql(u8, arg, "--text") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --text requires a value\n", .{});
                std.process.exit(2);
            }
            text = args[i];
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --file requires a value\n", .{});
                std.process.exit(2);
            }
            file_path = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --format requires a value\n", .{});
                std.process.exit(2);
            }
            format = args[i];
        }
    }

    if (model == null) {
        std.debug.print("Error: --model is required\n", .{});
        std.process.exit(1);
    }

    // Get input text
    var input_text: []const u8 = undefined;
    var needs_free = false;

    if (text) |t| {
        input_text = t;
    } else if (file_path) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Error: Could not open file {s}: {}\n", .{ path, err });
            std.process.exit(3);
        };
        defer file.close();
        input_text = file.readToEndAlloc(allocator, 1024 * 1024 * 10) catch |err| {
            std.debug.print("Error: Could not read file: {}\n", .{err});
            std.process.exit(3);
        };
        needs_free = true;
    } else {
        // Read from stdin
        const stdin = std.io.getStdIn();
        input_text = stdin.readToEndAlloc(allocator, 1024 * 1024 * 10) catch |err| {
            std.debug.print("Error: Could not read stdin: {}\n", .{err});
            std.process.exit(3);
        };
        needs_free = true;
    }
    defer if (needs_free) allocator.free(input_text);

    // Resolve encoding for model
    const spec = tokenizer.registry.Registry.getEncodingForModel(model.?);
    var is_approximate = false;

    // Count tokens using engine
    const result = engine.estimateTokens(allocator, .{
        .spec = spec,
        .model_name = model.?,
        .bpe_version = .v2_1,
    }, input_text, .ordinary) catch |err| {
        // Fallback to approximate count on error
        is_approximate = true;
        const approx_tokens = @max(1, input_text.len / 4);
        const stdout = std.io.getStdOut().writer();

        if (std.mem.eql(u8, format, "json")) {
            try stdout.print("{{\"model\":\"{s}\",\"tokens\":{d},\"bytes\":{d},\"approximate\":true,\"error\":\"{}\"}}\n", .{
                model.?,
                approx_tokens,
                input_text.len,
                err,
            });
        } else {
            try stdout.print("Model: {s}\n", .{model.?});
            try stdout.print("Tokens: {d} (approximate, error: {})\n", .{ approx_tokens, err });
            try stdout.print("Bytes: {d}\n", .{input_text.len});
        }
        return;
    };

    const stdout = std.io.getStdOut().writer();

    if (std.mem.eql(u8, format, "json")) {
        try stdout.print("{{\"model\":\"{s}\",\"tokens\":{d},\"bytes\":{d},\"approximate\":{}}}\n", .{
            model.?,
            result.tokens,
            input_text.len,
            is_approximate,
        });
    } else {
        try stdout.print("Model: {s}\n", .{model.?});
        if (spec != null) {
            try stdout.print("Encoding: {s}\n", .{spec.?.name});
        }
        try stdout.print("Tokens: {d}\n", .{result.tokens});
        try stdout.print("Bytes: {d}\n", .{input_text.len});
    }
}

fn runEstimate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;

    var model: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;
    var reasoning_tokens: u64 = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                std.process.exit(2);
            }
            model = args[i];
        } else if (std.mem.eql(u8, arg, "--input-tokens")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --input-tokens requires a value\n", .{});
                std.process.exit(2);
            }
            input_tokens = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: Invalid number for --input-tokens\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--output-tokens")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output-tokens requires a value\n", .{});
                std.process.exit(2);
            }
            output_tokens = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: Invalid number for --output-tokens\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--reasoning-tokens")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --reasoning-tokens requires a value\n", .{});
                std.process.exit(2);
            }
            reasoning_tokens = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: Invalid number for --reasoning-tokens\n", .{});
                std.process.exit(2);
            };
        }
    }

    if (model == null) {
        std.debug.print("Error: --model is required\n", .{});
        std.process.exit(1);
    }

    const in_tok = input_tokens orelse 0;
    const out_tok = output_tokens orelse 0;

    // Use pricing database
    const db = &pricing.DEFAULT_PRICING;
    const result = engine.estimateCost(db, model.?, in_tok, out_tok, reasoning_tokens) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        if (err == engine.EngineError.ModelNotFound) {
            std.debug.print("Unknown model: {s}\n", .{model.?});
            std.debug.print("Run 'llm-cost models' to see supported models.\n", .{});
        }
        std.process.exit(1);
    };

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Model: {s}\n", .{result.model_name});
    try stdout.print("Input tokens: {d}\n", .{result.input_tokens});
    try stdout.print("Output tokens: {d}\n", .{result.output_tokens});
    if (result.reasoning_tokens > 0) {
        try stdout.print("Reasoning tokens: {d}\n", .{result.reasoning_tokens});
    }
    try stdout.print("\n", .{});
    try stdout.print("Input cost:  ${d:.6}\n", .{result.cost_input});
    try stdout.print("Output cost: ${d:.6}\n", .{result.cost_output});
    if (result.cost_reasoning > 0) {
        try stdout.print("Reasoning cost: ${d:.6}\n", .{result.cost_reasoning});
    }
    try stdout.print("Total cost:  ${d:.6}\n", .{result.cost_total});
}

fn runModels() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Supported models:
        \\
        \\OpenAI GPT-4o:
        \\  gpt-4o              $2.50/$10.00 per 1M tokens (o200k_base)
        \\  gpt-4o-mini         $0.15/$0.60 per 1M tokens (o200k_base)
        \\
        \\OpenAI GPT-4:
        \\  gpt-4-turbo         $10.00/$30.00 per 1M tokens (cl100k_base)
        \\  gpt-4               $30.00/$60.00 per 1M tokens (cl100k_base)
        \\
        \\OpenAI GPT-3.5:
        \\  gpt-3.5-turbo       $0.50/$1.50 per 1M tokens (cl100k_base)
        \\
        \\OpenAI Reasoning:
        \\  o1                  $15.00/$60.00 per 1M tokens (o200k_base)
        \\  o1-mini             $3.00/$12.00 per 1M tokens (o200k_base)
        \\  o3-mini             $1.10/$4.40 per 1M tokens (o200k_base)
        \\
        \\OpenAI Embeddings:
        \\  text-embedding-3-small  $0.02 per 1M tokens (cl100k_base)
        \\  text-embedding-3-large  $0.13 per 1M tokens (cl100k_base)
        \\
        \\Anthropic Claude:
        \\  claude-3-5-sonnet   $3.00/$15.00 per 1M tokens
        \\  claude-3-opus       $15.00/$75.00 per 1M tokens
        \\  claude-3-sonnet     $3.00/$15.00 per 1M tokens
        \\  claude-3-haiku      $0.25/$1.25 per 1M tokens
        \\
        \\Encodings:
        \\  cl100k_base - GPT-4, GPT-3.5, embeddings
        \\  o200k_base  - GPT-4o, o1/o3 reasoning models
        \\
    );
}

// =============================================================================
// Tests
// =============================================================================

fn runPipe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model: ?[]const u8 = null;
    var json_field: []const u8 = "content";
    var input_mode: pipe.InputMode = .Auto;
    // Actually better to cast or use the public definition.
    // pipe.PipeConfig.input_mode is an enum.

    // Let's use var config = pipe.PipeConfig{...} pattern
    var max_tokens: ?u64 = null;
    var max_cost: ?f64 = null;
    const output_format: pipe.OutputFormat = .NdJson;
    var fail_on_error: bool = false;
    var summary: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                std.process.exit(2);
            }
            model = args[i];
        } else if (std.mem.eql(u8, arg, "--field")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --field requires a value\n", .{});
                std.process.exit(2);
            }
            json_field = args[i];
            input_mode = .JsonField;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            input_mode = .Raw;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-tokens requires a value\n", .{});
                std.process.exit(2);
            }
            max_tokens = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: Invalid number for --max-tokens\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--max-cost")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-cost requires a value\n", .{});
                std.process.exit(2);
            }
            max_cost = std.fmt.parseFloat(f64, args[i]) catch {
                std.debug.print("Error: Invalid number for --max-cost\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_on_error = true;
        }
    }

    if (model == null) {
        std.debug.print("Error: --model is required\n", .{});
        std.process.exit(1);
    }

    // Initialize config
    const config = pipe.PipeConfig{
        .input_mode = input_mode,
        .json_field = json_field,
        .output_format = output_format,
        .max_tokens = max_tokens,
        .max_cost = max_cost,
        .fail_on_error = fail_on_error,
        .summary = summary,
        .model_name = model.?,
    };

    // Initialize Tokenizer
    const spec = tokenizer.registry.Registry.getEncodingForModel(model.?);
    if (spec == null) {
        std.debug.print("Error: Unknown model '{s}'\n", .{model.?});
        std.process.exit(1);
    }

    // Use engine's OpenAI tokenizer logic.
    // We need to allow approximate_ok=true because BPE v2.
    // The TokenizerWrapper expects an initialized OpenAITokenizer impl.
    // But OpenAITokenizer is in `tokenizer.openai`.
    var tok_impl = try tokenizer.openai.OpenAITokenizer.init(allocator, .{
        .spec = spec.?,
        .approximate_ok = true,
        .bpe_version = .v2_1,
    });
    // We do NOT defer tok_impl.deinit() here because StreamProcessor might take ownership?
    // StreamProcessor takes TokenizerWrapper by value, which has copy of impl?
    // OpenAITokenizer struct has pointers to map. We should keep it alive.
    // We can define it here and pass it.
    defer tok_impl.deinit(allocator);

    // Setup Wrapper
    const wrapper = pipe.TokenizerWrapper{
        .impl = tok_impl,
        .allocator = allocator,
        .pricing_db = &pricing.DEFAULT_PRICING,
    };

    // Process Pipe
    var processor = pipe.StreamProcessor.init(allocator, wrapper, config);

    // Run
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    processor.process(stdin, stdout) catch |err| {
        if (err == error.QuotaExceeded) {
            std.process.exit(64);
        }
        std.debug.print("Stream Error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn runReport(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var json_field: []const u8 = "content";
    var input_mode: pipe.InputMode = .Auto;
    var top_k: usize = 10;
    var format: []const u8 = "json"; // Only json supported for now per spec, keeping arg for future

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                std.process.exit(2);
            }
            model = args[i];
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --file requires a value\n", .{});
                std.process.exit(2);
            }
            file_path = args[i];
        } else if (std.mem.eql(u8, arg, "--field")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --field requires a value\n", .{});
                std.process.exit(2);
            }
            json_field = args[i];
            input_mode = .JsonField;
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --top-k requires a value\n", .{});
                std.process.exit(2);
            }
            top_k = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Error: Invalid number for --top-k\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --format requires a value\n", .{});
                std.process.exit(2);
            }
            format = args[i];
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            // Explicit stdin (default behavior if no --file, but good to have)
            file_path = null;
        }
    }

    if (model == null) {
        std.debug.print("Error: --model is required\n", .{});
        std.process.exit(1);
    }

    // Config
    const config = report.ReportConfig{
        .input_mode = input_mode,
        .json_field = json_field,
        .model_name = model.?,
        .top_k = top_k,
    };

    // Initialize Tokenizer
    const spec = tokenizer.registry.Registry.getEncodingForModel(model.?);
    if (spec == null) {
        std.debug.print("Error: Unknown model '{s}'\n", .{model.?});
        std.process.exit(1);
    }

    // Init Tokenizer
    // We try to load vocab data if available, allowing approximation if not found (though report is analytics, better be precise?)
    // User didn't specify strict mode for report, but usually analytics implies precise.
    // However, keeping consistent with pipe/count defaults.
    var tok_impl = try tokenizer.openai.OpenAITokenizer.init(allocator, .{
        .spec = spec.?,
        .approximate_ok = true,
        .bpe_version = .v2_1,
    });
    defer tok_impl.deinit(allocator);

    // Init Processor
    var processor = try report.ReportProcessor.init(allocator, tok_impl, config);
    defer processor.deinit();

    // Run
    if (file_path) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Error: Could not open file {s}: {}\n", .{ path, err });
            std.process.exit(3);
        };
        defer file.close();
        try processor.processStream(file.reader());
    } else {
        const stdin = std.io.getStdIn().reader();
        try processor.processStream(stdin);
    }

    // Finalize
    const stdout = std.io.getStdOut().writer();
    try processor.printReport(stdout);
}

test "tokenizer module imports" {
    // Verify all tokenizer modules compile
    _ = tokenizer.bpe_v2_1;
    _ = tokenizer.registry;
    _ = tokenizer.openai;
    _ = report.ReportProcessor;
}

test "pricing module imports" {
    _ = pricing.DEFAULT_PRICING;
}

test "engine module imports" {
    _ = engine.estimateTokens;
    _ = engine.estimateCost;
}

test "version string format" {
    // Version should be semver-ish
    const v = version_str;
    try std.testing.expect(v.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, v, ".") != null);
}
