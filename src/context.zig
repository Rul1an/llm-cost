const std = @import("std");
const Pricing = @import("core/pricing/mod.zig");

pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    registry: *Pricing.Registry,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
};
