//! A chunk column's NBT, read in place: its place, its status and its sections, each 16 × 16 × 16
//! blocks and 4 × 4 × 4 biomes, as a palette and packed indexes into it.
const Chunk = @This();

const std = @import("std");
const nbt = @import("nbt");

pub const Error = nbt.Error || error{
    /// A chunk without a field it must have, or with one of another type.
    InvalidChunk,
};

/// The blocks along a side of a section.
pub const side = 16;
pub const blocks = side * side * side;
/// The biomes along a side of a section.
pub const biomeSide = 4;
pub const biomes = biomeSide * biomeSide * biomeSide;

/// The least bits an index takes in a section: more than its palette needs, for blocks.
const blockBits = 4;
const biomeBits = 1;

/// In chunks, block x / 16 and z / 16.
x: i32,
z: i32,
/// Whether `Status` is generation's last stage. A chunk at an earlier one isn't finished, and the
/// game doesn't show it.
full: bool,
sections: nbt.List,
/// The section at the bottom of the world, in sections.
bottom: i32 = 0,
/// Each column's `WORLD_SURFACE` height, packed as `Section`'s indexes are.
surface: ?nbt.Array(i64) = null,

pub fn parse(bytes: []const u8) Error!Chunk {
    const root = try nbt.parse(bytes);
    var chunk: Chunk = .{ .x = 0, .z = 0, .full = false, .sections = undefined };
    var found: u4 = 0;
    var fields = root.iterator();
    while (try fields.next()) |field| {
        if (std.mem.eql(u8, field.name, "xPos")) {
            if (field.value != .int) return error.InvalidChunk;
            chunk.x = field.value.int;
            found |= 1;
        } else if (std.mem.eql(u8, field.name, "zPos")) {
            if (field.value != .int) return error.InvalidChunk;
            chunk.z = field.value.int;
            found |= 2;
        } else if (std.mem.eql(u8, field.name, "Status")) {
            if (field.value != .string) return error.InvalidChunk;
            chunk.full = std.mem.eql(u8, field.value.string, "minecraft:full");
            found |= 4;
        } else if (std.mem.eql(u8, field.name, "sections")) {
            if (field.value != .list) return error.InvalidChunk;
            chunk.sections = field.value.list;
            found |= 8;
        } else if (std.mem.eql(u8, field.name, "yPos")) {
            if (field.value != .int) return error.InvalidChunk;
            chunk.bottom = field.value.int;
        } else if (std.mem.eql(u8, field.name, "Heightmaps")) {
            if (field.value != .compound) return error.InvalidChunk;
            const surface = try field.value.compound.get("WORLD_SURFACE") orelse continue;
            if (surface != .longArray) return error.InvalidChunk;
            chunk.surface = surface.longArray;
        }
    }
    if (found != 0xF) return error.InvalidChunk;
    return chunk;
}

pub const Section = struct {
    /// In sections, block y / 16.
    y: i8,
    /// `block_states`'s palette, a compound for each `Block`, and its indexes.
    blockPalette: nbt.List,
    blockData: ?nbt.Array(i64),
    /// `biomes`'s palette, a string for each, and its indexes.
    biomePalette: nbt.List,
    biomeData: ?nbt.Array(i64),

    /// Null for a section at the edge of the world, kept for its light, with no blocks.
    pub fn of(compound: nbt.Compound) Error!?Section {
        const y = try compound.get("Y") orelse return error.InvalidChunk;
        if (y != .byte) return error.InvalidChunk;
        const states = try compound.get("block_states") orelse return null;
        const biomeStates = try compound.get("biomes") orelse return null;
        if (states != .compound or biomeStates != .compound) return error.InvalidChunk;
        return .{
            .y = y.byte,
            .blockPalette = try paletteOf(states.compound),
            .blockData = try dataOf(states.compound),
            .biomePalette = try paletteOf(biomeStates.compound),
            .biomeData = try dataOf(biomeStates.compound),
        };
    }

    /// Each block's index in `blockPalette`, at `(y * side + z) * side + x`.
    pub fn unpackBlocks(self: Section, out: *[blocks]u16) Error!void {
        try unpack(out, self.blockPalette.count, blockBits, self.blockData);
    }

    /// Each biome's index in `biomePalette`, at `(y * biomeSide + z) * biomeSide + x`.
    pub fn unpackBiomes(self: Section, out: *[biomes]u16) Error!void {
        try unpack(out, self.biomePalette.count, biomeBits, self.biomeData);
    }
};

fn paletteOf(container: nbt.Compound) Error!nbt.List {
    const palette = try container.get("palette") orelse return error.InvalidChunk;
    if (palette != .list or palette.list.count == 0) return error.InvalidChunk;
    return palette.list;
}

fn dataOf(container: nbt.Compound) Error!?nbt.Array(i64) {
    const data = try container.get("data") orelse return null;
    if (data != .longArray) return error.InvalidChunk;
    return data.longArray;
}

/// A palette entry: a block, and the values of its properties, as strings. Null properties mean
/// its default state, or that it has none. A default state may be saved as the block's id alone.
/// An NBT list holds one type, so in a palette with compounds too, that string is wrapped in a
/// compound, as the field named "".
pub const Block = struct {
    id: []const u8,
    properties: ?nbt.Compound,

    pub fn of(entry: nbt.Value) Error!Block {
        if (entry == .string) return .{ .id = entry.string, .properties = null };
        if (entry != .compound) return error.InvalidChunk;
        if (try entry.compound.get("")) |wrapped| {
            if (wrapped != .string) return error.InvalidChunk;
            return .{ .id = wrapped.string, .properties = null };
        }
        const id = try entry.compound.get("id") orelse return error.InvalidChunk;
        if (id != .string) return error.InvalidChunk;
        const properties = try entry.compound.get("properties");
        if (properties) |value| if (value != .compound) return error.InvalidChunk;
        return .{ .id = id.string, .properties = if (properties) |value| value.compound else null };
    }
};

/// Each column's height from `surface`, at `z * side + x`: the block above its highest, counted
/// from the world's bottom, for a world `height` blocks high; 0 for a column with no blocks.
pub fn unpackSurface(self: Chunk, out: *[side * side]u16, height: usize) Error!void {
    const longs = self.surface orelse return error.InvalidChunk;
    try unpack(out, height + 1, 1, longs);
}

/// Indexes into a palette of `count` entries: without `data`, all 0, the palette's one entry.
/// Otherwise each takes as many bits as the largest does, at least `minBits`, as many as fit in
/// each long, from its lowest bits up, none across two longs.
fn unpack(out: []u16, count: usize, minBits: u16, data: ?nbt.Array(i64)) Error!void {
    const longs = data orelse {
        if (count != 1) return error.InvalidChunk;
        @memset(out, 0);
        return;
    };
    const bits: u16 = @max(minBits, std.math.log2_int_ceil(usize, count));
    if (bits > 16) return error.InvalidChunk;
    const perLong = 64 / bits;
    if (longs.len() != std.math.divCeil(usize, out.len, perLong) catch unreachable) return error.InvalidChunk;
    const mask = (@as(u64, 1) << @intCast(bits)) - 1;
    var at: usize = 0;
    for (0..longs.len()) |i| {
        var long: u64 = @bitCast(longs.get(i));
        for (0..@min(perLong, out.len - at)) |_| {
            const index: u16 = @intCast(long & mask);
            if (index >= count) return error.InvalidChunk;
            out[at] = index;
            at += 1;
            long >>= @intCast(bits);
        }
    }
}

test unpack {
    var out: [10]u16 = undefined;
    // 4 bits each, 16 to a long, the first in the lowest bits.
    var longBytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &longBytes, 0x0000_0000_0432_1032, .big);
    try unpack(out[0..8], 5, 4, .{ .bytes = &longBytes });
    try std.testing.expectEqualSlices(u16, &.{ 2, 3, 0, 1, 2, 3, 4, 0 }, out[0..8]);

    // 5 bits each, 12 to a long, the 4 bits left over unused.
    var two: [16]u8 = undefined;
    std.mem.writeInt(u64, two[0..8], (@as(u64, 0xF) << 60) | (@as(u64, 17) << 55) | 16, .big);
    std.mem.writeInt(u64, two[8..16], 3, .big);
    var thirteen: [13]u16 = undefined;
    try unpack(&thirteen, 18, 4, .{ .bytes = &two });
    try std.testing.expectEqual(16, thirteen[0]);
    try std.testing.expectEqual(17, thirteen[11]);
    try std.testing.expectEqual(3, thirteen[12]);

    // One entry and no data, an index past the palette, and data of the wrong length.
    try unpack(out[0..8], 1, 4, null);
    try std.testing.expectEqual(0, out[7]);
    try std.testing.expectError(error.InvalidChunk, unpack(out[0..8], 2, 4, null));
    try std.testing.expectError(error.InvalidChunk, unpack(out[0..8], 3, 4, .{ .bytes = &longBytes }));
    try std.testing.expectError(error.InvalidChunk, unpack(out[0..8], 5, 4, .{ .bytes = &two }));
}

test parse {
    const bytes = [_]u8{ 10, 0, 0 } ++
        [_]u8{ 8, 0, 6 } ++ "Status".* ++ [_]u8{ 0, 14 } ++ "minecraft:full".* ++
        [_]u8{ 3, 0, 4 } ++ "xPos".* ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFE } ++
        [_]u8{ 3, 0, 4 } ++ "zPos".* ++ [_]u8{ 0, 0, 0, 3 } ++
        [_]u8{ 9, 0, 8 } ++ "sections".* ++ [_]u8{ 10, 0, 0, 0, 2 } ++
        // Light only, then a section of one block and one biome.
        [_]u8{ 1, 0, 1, 'Y', 0xFB, 0 } ++
        [_]u8{ 1, 0, 1, 'Y', 2 } ++
        [_]u8{ 10, 0, 12 } ++ "block_states".* ++ [_]u8{ 9, 0, 7 } ++ "palette".* ++ [_]u8{ 10, 0, 0, 0, 1 } ++
        [_]u8{ 8, 0, 2 } ++ "id".* ++ [_]u8{ 0, 5 } ++ "stone".* ++
        [_]u8{ 10, 0, 10 } ++ "properties".* ++ [_]u8{ 8, 0, 1, 'a', 0, 1, 'b', 0 } ++ [_]u8{ 0, 0 } ++
        [_]u8{ 10, 0, 6 } ++ "biomes".* ++ [_]u8{ 9, 0, 7 } ++ "palette".* ++ [_]u8{ 8, 0, 0, 0, 1, 0, 5 } ++ "plain".* ++ [_]u8{0} ++
        [_]u8{ 0, 0 };
    const chunk = try parse(&bytes);
    try std.testing.expectEqual(-2, chunk.x);
    try std.testing.expectEqual(3, chunk.z);
    try std.testing.expect(chunk.full);
    var sections = chunk.sections.iterator();
    try std.testing.expectEqual(null, try Section.of((try sections.next()).?.compound));
    const section = (try Section.of((try sections.next()).?.compound)).?;
    try std.testing.expectEqual(2, section.y);
    var indexes: [blocks]u16 = undefined;
    try section.unpackBlocks(&indexes);
    try std.testing.expectEqual(0, indexes[blocks - 1]);
    var palette = section.blockPalette.iterator();
    const block: Block = try .of((try palette.next()).?);
    try std.testing.expectEqualStrings("stone", block.id);
    try std.testing.expectEqualStrings("b", (try block.properties.?.get("a")).?.string);

    // A default state saved as its id alone.
    const default: Block = try .of(.{ .string = "minecraft:deepslate" });
    try std.testing.expectEqualStrings("minecraft:deepslate", default.id);
    try std.testing.expectEqual(null, default.properties);
    try std.testing.expectError(error.InvalidChunk, Block.of(.{ .int = 1 }));

    // The same in a palette with compounds too, wrapped.
    const wrapped = [_]u8{ 10, 0, 0, 8, 0, 0, 0, 5 } ++ "stone".* ++ [_]u8{ 0, 0 };
    const unwrapped: Block = try .of(.{ .compound = try nbt.parse(&wrapped) });
    try std.testing.expectEqualStrings("stone", unwrapped.id);
    try std.testing.expectEqual(null, unwrapped.properties);

    // Without its sections, it isn't a chunk.
    try std.testing.expectError(error.InvalidChunk, parse(&.{ 10, 0, 0, 0 }));
}
