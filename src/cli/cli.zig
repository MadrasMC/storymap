//! Storymap's commands, which put the program together from the game's reader (`vs`) and the
//! renderers.
const std = @import("std");

pub const prepare = @import("prepare.zig");
pub const render = @import("render.zig");

test {
    std.testing.refAllDecls(@This());
}
