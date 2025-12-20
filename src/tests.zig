test {
    _ = @import("tests/security_test.zig");
    _ = @import("determinism_test.zig");
    _ = @import("tokenizer/vocab_loader.zig");
    _ = @import("tokenizer/openai.zig");
    _ = @import("tokenizer/property_test.zig");
    _ = @import("tests/cli_global_flags_test.zig");
    _ = @import("tests/init_test.zig");
    _ = @import("tests/tag_resolver_test.zig");
    _ = @import("tests/breakdown_test.zig");
    _ = @import("tests/agentic_gates_test.zig");
    _ = @import("tests/otel_convert_test.zig");
}
