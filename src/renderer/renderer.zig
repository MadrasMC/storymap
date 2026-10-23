//! The views of a map, drawn from `world` alone.
const std = @import("std");

pub const topdown = @import("topdown.zig");
pub const isometric = @import("isometric.zig");

test {
    std.testing.refAllDecls(@This());
}
