const std = @import("std");

// Module imports
// Module imports
pub const tokenizer = @import("tokenizer/mod.zig");

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
const version = "0.1.0-dev";

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

    if (std.mem.eql(u8, command, "count")) {
        try runCount(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "estimate")) {
        try runEstimate(allocator, args[2..]);
        return;
    }

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
    try stdout.print("llm-cost {s}\n", .{version});
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: llm-cost <command> [options]
        \\
        \\Commands:
        \\  count      Count tokens in text
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

    // TODO: Actual tokenization
    // For now, estimate based on bytes (roughly 4 chars per token)
    const estimated_tokens = @max(1, input_text.len / 4);

    const stdout = std.io.getStdOut().writer();

    if (std.mem.eql(u8, format, "json")) {
        try stdout.print("{{\"model\":\"{s}\",\"tokens\":{d},\"bytes\":{d}}}\n", .{
            model.?,
            estimated_tokens,
            input_text.len,
        });
    } else {
        try stdout.print("Model: {s}\n", .{model.?});
        try stdout.print("Tokens: {d} (estimated)\n", .{estimated_tokens});
        try stdout.print("Bytes: {d}\n", .{input_text.len});
    }
}

fn runEstimate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;

    var model: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

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
        }
    }

    if (model == null) {
        std.debug.print("Error: --model is required\n", .{});
        std.process.exit(1);
    }

    const in_tok = input_tokens orelse 0;
    const out_tok = output_tokens orelse 0;

    // TODO: Look up actual pricing from pricing table
    // Placeholder: GPT-4 pricing ($0.03/$0.06 per 1K tokens)
    const input_cost = @as(f64, @floatFromInt(in_tok)) * 0.03 / 1000.0;
    const output_cost = @as(f64, @floatFromInt(out_tok)) * 0.06 / 1000.0;
    const total_cost = input_cost + output_cost;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Model: {s}\n", .{model.?});
    try stdout.print("Input tokens: {d}\n", .{in_tok});
    try stdout.print("Output tokens: {d}\n", .{out_tok});
    try stdout.print("Estimated cost: ${d:.6}\n", .{total_cost});
}

fn runModels() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Supported models:
        \\
        \\OpenAI:
        \\  gpt-4, gpt-4-turbo, gpt-4o, gpt-4o-mini
        \\  gpt-3.5-turbo
        \\  text-embedding-3-small, text-embedding-3-large
        \\
        \\Anthropic:
        \\  claude-3-opus, claude-3-sonnet, claude-3-haiku
        \\  claude-3.5-sonnet
        \\
        \\Google:
        \\  gemini-pro, gemini-1.5-pro, gemini-1.5-flash
        \\
        \\Encodings:
        \\  cl100k_base (GPT-4, GPT-3.5)
        \\  o200k_base (GPT-4o)
        \\
    );
}

// =============================================================================
// Tests
// =============================================================================

test "tokenizer module imports" {
    // Verify all tokenizer modules compile
    _ = tokenizer.bpe_v2;
    _ = tokenizer.bpe_v2_1;
    _ = tokenizer.pre_tokenizer;
    _ = tokenizer.cl100k_scanner;
    _ = tokenizer.o200k_scanner;
    _ = tokenizer.vocab_loader;
}

test "version string format" {
    // Version should be semver-ish
    const v = version;
    try std.testing.expect(v.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, v, ".") != null);
}
