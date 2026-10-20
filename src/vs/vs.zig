//! Vintage Story: its saves, its assets and its blocks. Everything that knows the game is in
//! this module; it tells the renderers what's on top of each block column (`columns`).
const std = @import("std");

pub const Assets = @import("Assets.zig");
pub const BlockEntity = @import("BlockEntity.zig");
pub const BlockTypes = @import("BlockTypes.zig");
pub const Chunk = @import("Chunk.zig");
pub const Compression = @import("Compression.zig");
pub const GameData = @import("GameData.zig");
pub const Json = @import("Json.zig");
pub const MapChunk = @import("MapChunk.zig");
pub const Prepared = @import("Prepared.zig");
pub const Save = @import("Save.zig");
pub const TextureColours = @import("TextureColours.zig");
pub const Tint = @import("Tint.zig");
pub const TreeAttribute = @import("TreeAttribute.zig");
pub const Wildcard = @import("Wildcard.zig");

test {
    std.testing.refAllDecls(@This());
}
