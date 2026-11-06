//! Reads Minecraft: its saves, and its client jar.
const std = @import("std");

pub const Jar = @import("Jar.zig");
pub const BlockStates = @import("BlockStates.zig");
pub const Models = @import("Models.zig");
pub const Blocks = @import("Blocks.zig");
pub const Prepared = @import("Prepared.zig");
pub const Region = @import("Region.zig");
pub const Chunk = @import("Chunk.zig");
pub const World = @import("World.zig");

pub const game = Prepared.game;

test {
    std.testing.refAllDecls(@This());
    _ = @import("names.zig");
}
