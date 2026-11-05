//! Reads Minecraft: its saves, and its client jar.
const std = @import("std");

pub const Jar = @import("Jar.zig");
pub const Region = @import("Region.zig");
pub const Chunk = @import("Chunk.zig");
pub const World = @import("World.zig");

/// The game, as `--game` names it.
pub const game = "minecraft";

test {
    std.testing.refAllDecls(@This());
}
