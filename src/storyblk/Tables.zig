//! The six sections a game's block states are in (spec §3): `block_states`, and the tables a
//! BlockState points into, `materials`, `colour_codes`, `texture_colours`, `colour_maps` and
//! `domains`. Every game's prepared blocks file has them; its reader decides what's in them.
//!
//! Block states are written and read one at a time, so neither side keeps a list of them that
//! it doesn't need.
const Tables = @This();

const std = @import("std");
const Io = std.Io;
const storyblk = @import("storyblk.zig");
const Section = storyblk.Section;
const Reader = storyblk.Reader;

materials: []const []const u8,
colourCodes: []const []const u8,
textureColours: []const TextureColours,
colourMaps: []const ColourMap,
domains: []const []const u8,

/// The sections, in the order Storymap writes them.
pub const names = [_][]const u8{ "block_states", "materials", "colour_codes", "texture_colours", "colour_maps", "domains" };
/// Each section's layout (spec §7), by `names`.
pub const layoutVersions = [names.len]u8{ 1, 1, 1, 1, 2, 1 };

/// A BlockState's index of none, in a field of one byte or four.
const none8 = 0xFF;
const none32 = 0xFFFFFFFF;

/// A BlockState (spec §4), its indexes into the tables.
pub const BlockState = struct {
    name: []const u8,
    material: u8,
    colourCode: u8,
    colour: ?u32 = null,
    grain: ?u32 = null,
    climateColourMap: ?u8 = null,
    seasonColourMap: ?u8 = null,
    /// In sixteenths of a block; null for the whole block.
    height: ?u8 = null,
    drawOffset: u8 = 0,
    flags: Flags = .{},
    firstSprite: u32 = 0,
    variants: u16 = 0,
    alternates: u16 = 1,
    turns: u8 = 1,
    coverSprite: ?u32 = null,

    /// The bytes of the smallest, with an empty name.
    const minLength = 2 + 1 + 1 + 4 + 4 + 1 + 1 + 1 + 1 + 1 + 4 + 2 + 2 + 1 + 4;
};

/// A BlockState's `flags`.
pub const Flags = packed struct(u8) {
    /// Its variant, alternate and turn are picked by x and z alone, with y as 0.
    xz: bool = false,
    /// It's turned by where it is.
    turned: bool = false,
    /// It's drawn in its shape, rather than as a cube.
    shape: bool = false,
    /// Any of its textures has a tinted layer.
    tinted: bool = false,
    /// It shows what's behind it.
    seeThrough: bool = false,
    _: u3 = 0,
};

/// A TextureColours (spec §4), read in place.
pub const TextureColours = extern struct {
    pub const samples = 30;

    average: [3]u8,
    grain: [samples][3]u8,

    comptime {
        std.debug.assert(@sizeOf(TextureColours) == 93);
    }
};

/// A ColourMap (spec §4), its pixels read in place.
pub const ColourMap = struct {
    code: []const u8,
    padding: u8,
    tropical: bool,
    width: u16,
    height: u16,
    /// Row by row.
    pixels: []const [3]u8,
};

/// Writes the six sections: `block_states` a block state at a time, then the tables.
pub const Encoder = struct {
    tables: Tables,
    count: u32,
    blockStates: Io.Writer.Allocating,

    /// For `count` block states pointing into `tables`, its bytes kept in `arena`. A table or
    /// count that doesn't fit its field is an error.
    pub fn init(arena: std.mem.Allocator, tables: Tables, count: usize) !Encoder {
        if (tables.materials.len > std.math.maxInt(u8)) return error.TooManyMaterials;
        if (tables.colourCodes.len > std.math.maxInt(u8)) return error.TooManyColourCodes;
        if (tables.colourMaps.len > std.math.maxInt(u8)) return error.TooManyColourMaps;
        if (tables.domains.len > std.math.maxInt(u16)) return error.TooManyDomains;
        if (tables.textureColours.len >= none32) return error.TooManyTextures;
        if (count > std.math.maxInt(u32)) return error.TooManyBlocks;
        var self: Encoder = .{ .tables = tables, .count = @intCast(count), .blockStates = .init(arena) };
        try self.blockStates.writer.writeInt(u32, self.count, .little);
        return self;
    }

    pub fn add(self: *Encoder, state: BlockState) !void {
        std.debug.assert(state.material < self.tables.materials.len and state.colourCode < self.tables.colourCodes.len);
        const w = &self.blockStates.writer;
        try storyblk.writeString(w, state.name);
        try w.writeByte(state.material);
        try w.writeByte(state.colourCode);
        try w.writeInt(u32, state.colour orelse none32, .little);
        try w.writeInt(u32, state.grain orelse none32, .little);
        try w.writeByte(state.climateColourMap orelse none8);
        try w.writeByte(state.seasonColourMap orelse none8);
        try w.writeByte(state.height orelse none8);
        try w.writeByte(state.drawOffset);
        try w.writeByte(@bitCast(state.flags));
        try w.writeInt(u32, state.firstSprite, .little);
        try w.writeInt(u16, state.variants, .little);
        try w.writeInt(u16, state.alternates, .little);
        try w.writeByte(state.turns);
        try w.writeInt(u32, state.coverSprite orelse none32, .little);
    }

    /// The six sections, in the order of `names`, once `count` block states are added; their
    /// bytes kept in `arena`.
    pub fn finish(self: *Encoder, arena: std.mem.Allocator, generatorVersion: u16) ![names.len]Section {
        var materials: Io.Writer.Allocating = .init(arena);
        var colourCodes: Io.Writer.Allocating = .init(arena);
        var textures: Io.Writer.Allocating = .init(arena);
        var colourMaps: Io.Writer.Allocating = .init(arena);
        var domains: Io.Writer.Allocating = .init(arena);
        try writeStrings(&materials.writer, u8, self.tables.materials);
        try writeStrings(&colourCodes.writer, u8, self.tables.colourCodes);
        try textures.writer.writeInt(u32, @intCast(self.tables.textureColours.len), .little);
        try textures.writer.writeAll(std.mem.sliceAsBytes(self.tables.textureColours));
        try colourMaps.writer.writeByte(@intCast(self.tables.colourMaps.len));
        for (self.tables.colourMaps) |colourMap| {
            try storyblk.writeString(&colourMaps.writer, colourMap.code);
            try colourMaps.writer.writeByte(colourMap.padding);
            try colourMaps.writer.writeByte(@intFromBool(colourMap.tropical));
            try colourMaps.writer.writeInt(u16, colourMap.width, .little);
            try colourMaps.writer.writeInt(u16, colourMap.height, .little);
            try colourMaps.writer.writeAll(std.mem.sliceAsBytes(colourMap.pixels));
        }
        try writeStrings(&domains.writer, u16, self.tables.domains);

        const bytes = [names.len][]const u8{ self.blockStates.written(), materials.written(), colourCodes.written(), textures.written(), colourMaps.written(), domains.written() };
        var sections: [names.len]Section = undefined;
        for (&sections, names, layoutVersions, bytes) |*section, name, layout, written| {
            section.* = .{ .name = name, .layoutVersion = layout, .generatorVersion = generatorVersion, .bytes = written };
        }
        return sections;
    }
};

/// A list of strings, counted by a `Count`.
fn writeStrings(w: *Io.Writer, comptime Count: type, strings: []const []const u8) !void {
    try w.writeInt(Count, @intCast(strings.len), .little);
    for (strings) |string| try storyblk.writeString(w, string);
}

/// The block states of a file, read one at a time, each checked against the tables and the
/// `sprites` section's count (spec §5).
pub const BlockStates = struct {
    tables: *const Tables,
    reader: Reader,
    count: u32,
    /// The next one's index.
    index: u32 = 0,
    spriteCount: usize,

    /// The next block state, its name where the file is; null after the last.
    pub fn next(self: *BlockStates) error{NotPreparedBlocks}!?BlockState {
        if (self.index == self.count) return null;
        self.index += 1;
        const r = &self.reader;
        const state: BlockState = .{
            .name = try r.string(),
            .material = try r.int(u8),
            .colourCode = try r.int(u8),
            .colour = none(u32, try r.int(u32)),
            .grain = none(u32, try r.int(u32)),
            .climateColourMap = none(u8, try r.int(u8)),
            .seasonColourMap = none(u8, try r.int(u8)),
            .height = none(u8, try r.int(u8)),
            .drawOffset = try r.int(u8),
            .flags = @bitCast(try r.int(u8)),
            .firstSprite = try r.int(u32),
            .variants = try r.int(u16),
            .alternates = try r.int(u16),
            .turns = try r.int(u8),
            .coverSprite = none(u32, try r.int(u32)),
        };
        const tables = self.tables;
        if (state.material >= tables.materials.len or state.colourCode >= tables.colourCodes.len) return error.NotPreparedBlocks;
        if (outside(state.colour, tables.textureColours.len) or outside(state.grain, tables.textureColours.len)) return error.NotPreparedBlocks;
        if (outside(state.climateColourMap, tables.colourMaps.len) or outside(state.seasonColourMap, tables.colourMaps.len)) return error.NotPreparedBlocks;
        if (state.variants > 0) {
            if (state.alternates == 0 or state.turns == 0) return error.NotPreparedBlocks;
            const count = @as(u64, state.variants) * state.alternates * state.turns;
            if (@as(u64, state.firstSprite) + count > self.spriteCount) return error.NotPreparedBlocks;
        }
        if (outside(state.coverSprite, self.spriteCount)) return error.NotPreparedBlocks;
        return state;
    }
};

fn none(comptime T: type, value: T) ?T {
    return if (value == std.math.maxInt(T)) null else value;
}

fn outside(index: anytype, count: usize) bool {
    return if (index) |i| i >= count else false;
}

/// The tables of `file`, and a reader of its block states, each checked against the `sprites`
/// section's `spriteCount`. Strings, texture colours and pixels are where `file` is, which
/// must outlive them; the lists of them are in `arena`. A section that's missing, of another
/// layout, or not as the spec has it is error.NotPreparedBlocks.
pub fn read(arena: std.mem.Allocator, file: *const storyblk.File, spriteCount: usize) !struct { *const Tables, BlockStates } {
    const tables = try arena.create(Tables);
    tables.* = .{
        .materials = try readStrings(arena, u8, try file.section("materials", layoutVersions[1])),
        .colourCodes = try readStrings(arena, u8, try file.section("colour_codes", layoutVersions[2])),
        .textureColours = &.{},
        .colourMaps = &.{},
        .domains = try readStrings(arena, u16, try file.section("domains", layoutVersions[5])),
    };

    var textures: Reader = .{ .bytes = (try file.section("texture_colours", layoutVersions[3])).bytes };
    const textureCount = try textures.int(u32);
    if (textures.bytes.len != 4 + @as(u64, textureCount) * @sizeOf(TextureColours)) return error.NotPreparedBlocks;
    tables.textureColours = std.mem.bytesAsSlice(TextureColours, textures.bytes[4..]);

    var maps: Reader = .{ .bytes = (try file.section("colour_maps", layoutVersions[4])).bytes };
    const colourMaps = try arena.alloc(ColourMap, try maps.int(u8));
    for (colourMaps) |*colourMap| {
        const code = try maps.string();
        const padding = try maps.int(u8);
        const flags = try maps.int(u8);
        const width = try maps.int(u16);
        const height = try maps.int(u16);
        if (width <= 2 * @as(u32, padding) or height <= 2 * @as(u32, padding)) return error.NotPreparedBlocks;
        colourMap.* = .{
            .code = code,
            .padding = padding,
            .tropical = flags & 1 != 0,
            .width = width,
            .height = height,
            .pixels = std.mem.bytesAsSlice([3]u8, try maps.take(@as(usize, width) * height * 3)),
        };
    }
    tables.colourMaps = colourMaps;

    var states: Reader = .{ .bytes = (try file.section("block_states", layoutVersions[0])).bytes };
    const count = try states.int(u32);
    if (count > states.bytes.len / BlockState.minLength) return error.NotPreparedBlocks;
    return .{ tables, .{ .tables = tables, .reader = states, .count = count, .spriteCount = spriteCount } };
}

/// A section's list of strings, counted by a `Count`.
fn readStrings(arena: std.mem.Allocator, comptime Count: type, section: Section) ![]const []const u8 {
    var reader: Reader = .{ .bytes = section.bytes };
    const strings = try arena.alloc([]const u8, try reader.int(Count));
    for (strings) |*string| string.* = try reader.string();
    return strings;
}
