const Chunk = @This();

// these should really be read from "servermagicnumbers.json" in the server's Data directory
pub const MagicNumbers = struct {
    .ServerChunkSize = 32,
};

pub const fieldNames = [_][]const u8{
    "<unused>",
    "compressed_blocks",
    "compressed_light",
    "compressed_light_sat",
    "<unused>",
    "entities_count",
    "entities_serialized",
    "block_entities_count",
    "block_entities",
    "moddata",
    "lights",
    "serverside_moddata",
    "game_version",
    "empty",
    "decors",
    "saved_compression_version",
    "compressed_liquids",
    "blocks_placed",
    "blocks_removed",
};

pub const Position = packed struct(u64) {
    x: u27,
    z: u27,
    y: u10,
};

position: Position,

pub fn from(position: u64) Chunk {
    return .{ .position = @bitCast(position) };
}

pub fn position64(self: Chunk) u64 {
    return @bitCast(self.position);
}
