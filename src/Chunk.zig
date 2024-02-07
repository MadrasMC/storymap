const Chunk = @This();

const std = @import("std");
const Protobuf = @import("./ProtoBuf.zig");
const Compression = @import("./Compression.zig").Compression;
const BlockEntity = @import("./BlockEntity.zig");

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

    pub fn position64(self: Position) u64 {
        return @bitCast(self);
    }
};

allocator: std.mem.Allocator,
position: Position,
blocks: ?[][]const i32 = null,
blockPalette: ?[]const i32 = null,
liqids: ?[][]const i32 = null,
liquidPalette: ?[]const i32 = null,
blockEntities: []BlockEntity,

pub fn deinit(self: Chunk) void {
    const allocator = self.allocator;

    if (self.blocks) |blocks| {
        for (blocks) |row| {
            allocator.free(row);
        }
        allocator.free(blocks);
    }
    if (self.liqids) |liqids| {
        for (liqids) |row| {
            allocator.free(row);
        }
        allocator.free(liqids);
    }
    if (self.blockPalette) |blockPalette| allocator.free(blockPalette);
    if (self.liquidPalette) |liquidPalette| allocator.free(liquidPalette);
    allocator.free(self.blockEntities);
}

pub fn from(allocator: std.mem.Allocator, position: u64, data: []const u8) !Chunk {
    var _blocks: ?[][]i32 = null;
    var _blockPalette: ?[]const i32 = null;

    var _liqids: ?[][]i32 = null;
    var _liquidPalette: ?[]const i32 = null;

    var blockEntitiesArray = std.ArrayList(BlockEntity).init(allocator);

    var parser = Protobuf{ .buf = data };
    while (parser.next()) |msg| {
        if (msg.data == .LEN) {
            switch (msg.field_number) {
                1, 16 => {
                    var decompress_arena = std.heap.ArenaAllocator.init(allocator);
                    defer decompress_arena.deinit();
                    const decompress_allocator = decompress_arena.allocator();

                    var dataBits: [][]i32 = &.{};
                    var refCount: i32 = 0;
                    var palette = try Compression.DecompressCombined(
                        decompress_allocator,
                        msg.data.LEN,
                        &dataBits,
                        &refCount,
                    );

                    // dupe with outer allocator
                    const dupedData = try allocator.alloc([]i32, dataBits.len);
                    for (dataBits, dupedData) |bit, *dupe| {
                        dupe.* = try allocator.dupe(i32, bit);
                    }
                    if (palette) |p| palette = try allocator.dupe(i32, p);

                    if (msg.field_number == 1) {
                        _blocks = dupedData;
                        _blockPalette = palette;
                    } else {
                        _liqids = dupedData;
                        _liquidPalette = palette;
                    }
                },
                8 => {
                    try blockEntitiesArray.append(BlockEntity.from(msg.data.LEN));
                },
                12 => {
                    // version, ignore
                },
                else => {
                    // Not implemented
                },
            }
        }
    }

    return Chunk{
        .allocator = allocator,
        .position = @bitCast(position),
        .blocks = _blocks,
        .blockPalette = _blockPalette,
        .liqids = _liqids,
        .liquidPalette = _liquidPalette,
        .blockEntities = try blockEntitiesArray.toOwnedSlice(),
    };
}
