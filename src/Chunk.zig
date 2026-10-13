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
/// Bit planes, not layers: see `getBlock`.
blocks: ?[]const []const i32 = null,
blockPalette: ?[]const i32 = null,
liquids: ?[]const []const i32 = null,
liquidPalette: ?[]const i32 = null,
blockEntities: []BlockEntity,
/// Owns `blockEntities` and everything in them.
blockEntityArena: std.heap.ArenaAllocator,

/// Returns the block id at chunk-local (x, y, z). 0 is air.
///
/// Blocks are numbered x first, then z, then y. Each block's palette index is split
/// into bits, and bit `b` of every block is stored together in `blocks[b]`: a bit plane
/// of 32768 bits packed into 1024 i32s.
pub fn getBlock(self: Chunk, x: u5, y: u5, z: u5) i32 {
    const palette = self.blockPalette orelse return 0;
    const planes = self.blocks orelse return 0;
    const n = (@as(usize, y) * 32 + z) * 32 + x;
    var index: usize = 0;
    for (planes[0..std.math.log2_int(usize, palette.len)], 0..) |plane, b| {
        const bit: usize = @intCast((plane[n / 32] >> @intCast(n % 32)) & 1);
        index |= bit << @intCast(b);
    }
    return palette[index];
}

test {
    _ = BlockEntity;
}

test getBlock {
    // palette index 3 (0b11) at (1, 2, 3): block 2145, word 67, bit 1, set in both planes
    // palette index 2 (0b10) at (0, 0, 0): block 0, word 0, bit 0, set in plane 1 only
    var plane0: [1024]i32 = @splat(0);
    var plane1: [1024]i32 = @splat(0);
    plane0[67] = 0b10;
    plane1[67] = 0b10;
    plane1[0] = 0b1;
    const chunk: Chunk = .{
        .allocator = std.testing.allocator,
        .position = @bitCast(@as(u64, 0)),
        .blocks = &.{ &plane0, &plane1 },
        .blockPalette = &.{ 0, 5, 7, 9 },
        .blockEntities = &.{},
        .blockEntityArena = .init(std.testing.allocator),
    };
    try std.testing.expectEqual(9, chunk.getBlock(1, 2, 3));
    try std.testing.expectEqual(7, chunk.getBlock(0, 0, 0));
    try std.testing.expectEqual(0, chunk.getBlock(1, 0, 0));
}

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
    self.blockEntityArena.deinit();
}

pub fn from(allocator: std.mem.Allocator, position: u64, data: []const u8) !Chunk {
    var _blocks: ?[][]i32 = null;
    var _blockPalette: ?[]const i32 = null;

    var _liquids: ?[][]i32 = null;
    var _liquidPalette: ?[]const i32 = null;

    var blockEntityArena: std.heap.ArenaAllocator = .init(allocator);
    errdefer blockEntityArena.deinit();
    const arena = blockEntityArena.allocator();
    var blockEntitiesArray: std.ArrayList(BlockEntity) = .empty;

    var parser = Protobuf{ .buf = data };
    while (try parser.next()) |msg| {
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
                    // One unreadable block entity shouldn't stop the whole map.
                    const blockEntity = BlockEntity.parse(arena, msg.data.LEN) catch |err| {
                        const pos: Position = @bitCast(position);
                        std.log.warn("chunk ({}, {}, {}): skipping a block entity ({s})", .{ pos.x, pos.y, pos.z, @errorName(err) });
                        continue;
                    };
                    try blockEntitiesArray.append(arena, blockEntity);
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
        .blockEntities = try blockEntitiesArray.toOwnedSlice(arena),
        .blockEntityArena = blockEntityArena,
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
