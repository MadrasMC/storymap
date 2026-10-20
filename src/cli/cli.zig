//! Storymap's commands, which put the program together from the game's reader (`vs`) and the
//! renderers.
const std = @import("std");

pub const bench = @import("bench.zig");
pub const prepare = @import("prepare.zig");
pub const render = @import("render.zig");

test {
    std.testing.refAllDecls(@This());
}
