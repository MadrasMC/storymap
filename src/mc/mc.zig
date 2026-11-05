//! Reads Minecraft: its saves, for now.
const std = @import("std");

pub const Region = @import("Region.zig");
pub const Chunk = @import("Chunk.zig");
pub const World = @import("World.zig");

/// The game, as `--game` names it.
pub const game = "minecraft";

test {
    std.testing.refAllDecls(@This());
}
