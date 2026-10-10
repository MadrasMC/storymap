const Chunk = @This();

const std = @import("std");
const Protobuf = @import("./ProtoBuf.zig");
const Compression = @import("./Compression.zig").Compression;
const BlockEntity = @import("./BlockEntity.zig");

// NOTE: To keep in sync with the server per game version
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
    pub fn eql(self: Position, other: Position) bool {
        return self.position64() == other.position64();
    }
};

allocator: std.mem.Allocator,
position: Position,
blocks: ?[]const []const i32 = null,
blockPalette: ?[]const i32 = null,
liquids: ?[]const []const i32 = null,
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
    if (self.liquids) |liquids| {
        for (liquids) |row| {
            allocator.free(row);
        }
        allocator.free(liquids);
    }
    if (self.blockPalette) |blockPalette| allocator.free(blockPalette);
    if (self.liquidPalette) |liquidPalette| allocator.free(liquidPalette);
    allocator.free(self.blockEntities);
}

pub fn from(allocator: std.mem.Allocator, position: u64, data: []const u8) !Chunk {
    var _blocks: ?[][]i32 = null;
    var _blockPalette: ?[]const i32 = null;

    var _liquids: ?[][]i32 = null;
    var _liquidPalette: ?[]const i32 = null;

    var blockEntitiesArray: std.ArrayList(BlockEntity) = .empty;
    errdefer blockEntitiesArray.deinit(allocator);

    var parser = Protobuf{ .buf = data };
    while (parser.next()) |msg| {
        if (msg.data == .LEN) {
            switch (msg.field_number) {
                1, 16 => {
                    var dataBits: [][]i32 = &.{};
                    var refCount: usize = 0;
                    const palette = try Compression.DecompressCombined(
                        allocator,
                        msg.data.LEN,
                        &dataBits,
                        &refCount,
                    );

                    if (msg.field_number == 1) {
                        _blocks = dataBits;
                        _blockPalette = palette;
                    } else {
                        _liquids = dataBits;
                        _liquidPalette = palette;
                    }
                },
                8 => {
                    try blockEntitiesArray.append(allocator, BlockEntity.from(msg.data.LEN));
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
        .liquids = _liquids,
        .liquidPalette = _liquidPalette,
        .blockEntities = try blockEntitiesArray.toOwnedSlice(allocator),
    };
}

pub fn format(value: Chunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Chunk(x: {[x]}, z: {[z]}, y: {[y]}):\n", value.position);
    try value.formatBlocks(writer);
    try value.formatBlockPalette(writer);
    try value.formatLiquids(writer);
    try writer.print("Liquid palette: {any}\n\n", .{value.liquidPalette});
    try writer.print("Block entities:\n", .{});
    for (value.blockEntities) |blockEntity| {
        try writer.print("{}\n", .{blockEntity});
    }
}

pub fn formatBlocks(value: Chunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (value.blocks) |blocks| {
        try writer.print("Blocks ({}):\n", .{blocks.len});
        for (blocks, 0..) |block, i| if (block.len != 0) {
            try writer.print("{} ({}): {{ ", .{ i, block.len });
            var same: usize = 0;
            var first = true;
            for (block) |b| {
                if (b == 0) {
                    same += 1;
                } else {
                    if (same > 1) {
                        try writer.print("{s}\x1b[30m{} x \x1b[32m0\x1b[0m", .{ if (first) "" else ", ", same });
                        first = false;
                        same = 0;
                    }
                    try writer.print("{s}\x1b[32m{}\x1b[0m", .{ if (first) "" else ", ", b });
                    first = false;
                }
            }
            if (same > 1) {
                try writer.print("{s}\x1b[30m{} x \x1b[32m0\x1b[0m", .{ if (first) "" else ", ", same });
                first = false;
                same = 0;
            }
            try writer.print(" }}\n", .{});
        };
    }
}

pub fn formatLiquids(value: Chunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (value.liquids) |liquids| {
        try writer.print("Liquids ({}):\n", .{liquids.len});
        for (liquids, 0..) |block, i| if (block.len != 0) {
            try writer.print("{} ({}): {{ ", .{ i, block.len });
            var same: usize = 0;
            var first = true;
            for (block) |b| {
                if (b == 0) {
                    same += 1;
                } else {
                    if (same > 1) {
                        try writer.print("{s}\x1b[30m{} x \x1b[32m0\x1b[0m", .{ if (first) "" else ", ", same });
                        first = false;
                        same = 0;
                    }
                    try writer.print("{s}\x1b[32m{}\x1b[0m", .{ if (first) "" else ", ", b });
                    first = false;
                }
            }
            if (same > 1) {
                try writer.print("{s}\x1b[30m{} x \x1b[32m0\x1b[0m", .{ if (first) "" else ", ", same });
                first = false;
                same = 0;
            }
            try writer.print(" }}\n", .{});
        };
    }
}

pub fn formatBlockPalette(value: Chunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Block palette: ", .{});
    try writer.print("{{ ", .{});
    var first = true;
    if (value.blockPalette) |palette| for (palette) |p| {
        try writer.print("{s}\x1b[32m{}\x1b[0m", .{ if (first) "" else ", ", p });
        first = false;
    };
    try writer.print(" }}", .{});
    try writer.print("\n\n", .{});
}
