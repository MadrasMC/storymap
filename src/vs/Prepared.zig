//! The game's and mods' blocks as rendering needs them, prepared once from their assets so a
//! render never reads assets itself (docs/blocks.md#preparing-blocks), in six sections of the
//! prepared blocks file: `blocks`, `materials`, `colour_codes`, `texture_colours`, `colour_maps`
//! and `domains` (docs/storyblk/spec.md).
const Prepared = @This();

const std = @import("std");
const Io = std.Io;
const world = @import("world");
const console = @import("console");
const storyblk = @import("storyblk");
const Assets = @import("Assets.zig");
const BlockTypes = @import("BlockTypes.zig");
const TextureColours = @import("TextureColours.zig");
const Json = @import("Json.zig");
const Tint = @import("Tint.zig");
const stb = @import("stb_image");

arena: std.heap.ArenaAllocator,
gameVersion: []const u8 = "",
mods: []const storyblk.Mod = &.{},
/// The domains the game and mods have assets in.
domains: std.StringHashMapUnmanaged(void) = .empty,
/// Every block, by its code as a save names it.
blocks: std.StringHashMapUnmanaged(Block) = .empty,

pub const Block = struct {
    /// Its index in the `blocks` section, from 0.
    index: u32 = 0,
    /// One of `BlockTypes.materials`, e.g. "Stone".
    material: []const u8,
    /// Its colour on the game's map, e.g. "land" or "forest" (docs/blocks.md#block-colours).
    colorCode: []const u8,
    /// Its texture's average colour and grain, from the textures the game's colour-accurate map
    /// uses (`BlockTypes.Textures`), where readable.
    colour: ?world.Rgb = null,
    grain: []const world.Rgb = &.{},
    /// The colour maps tinting it by climate and season, where it has them and they're readable.
    climateColourMap: ?*const Tint.ColourMap = null,
    seasonColourMap: ?*const Tint.ColourMap = null,
    /// For a block the game draws as a plain cube, its faces' images; null for any other, or
    /// one with a face that can't be read. Only while preparing (`prepare`): the file keeps its
    /// sprites instead.
    cube: ?world.CubeFaces = null,
    /// How high its selection box reaches, in sixteenths of a block; null for the whole block.
    height: ?u8 = null,
    /// For a block the game draws in a shape other than the plain cube, the shapes it picks one
    /// of for each block, by where it is (`BlockTypes.Block.shapes`), the first its own; empty for
    /// any other, or one whose shapes can't be read. One with nothing to draw has no boxes. Only
    /// while preparing, as `cube`.
    shapes: []const world.Shape = &.{},
    /// How it's moved off the middle of its place by where it is (`BlockTypes.Block.drawOffset`).
    drawOffset: u8 = 0,
    randomizeAxes: BlockTypes.Axes = .xyz,
    /// Whether it's turned about its vertical middle by where it is.
    randomizeRotations: bool = false,
    /// Its sprites, drawn from its `cube` or `shapes` (`Contents.useSprites`).
    sprites: world.BlockSprites = .{},
};

const Image = world.Image;

/// How the six sections' contents are read from the game's assets: raise it when that changes,
/// so files prepared before are prepared again.
pub const generatorVersion: u16 = 18;
/// The layout of each of the six sections (spec §7).
pub const layoutVersion: u8 = 1;

/// The sections this writes and reads, in the order it writes them.
pub const sectionNames = [_][]const u8{ "blocks", "materials", "colour_codes", "texture_colours", "colour_maps", "domains" };

/// The game, as the file's `info` names it.
pub const game = "vintagestory";

/// Where the prepared blocks file goes when no path is given, relative to the current folder.
pub const defaultPath = "prepared.storyblk";

/// Blocks the game registers itself rather than from a block type file.
const builtInBlocks = [_][]const u8{ "air", "mantle" };

pub fn deinit(self: *Prepared) void {
    self.arena.deinit();
}

/// What `hash` covers of the sprites, which the renderer draws.
pub const SpriteFormat = struct {
    generatorVersion: u16,
    layoutVersion: u8,
    blockWidth: u16,
};

/// The file's `header.hash` for blocks prepared from `assets`, with sprites drawn as `sprites`
/// says (spec §6): it changes with the container's and the sections' versions, the block width,
/// the game version and the mods (their names, sizes and times).
pub fn hash(io: Io, assets: *const Assets, sprites: SpriteFormat) !u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, storyblk.version);
    std.hash.autoHash(&hasher, layoutVersion);
    std.hash.autoHash(&hasher, generatorVersion);
    std.hash.autoHash(&hasher, sprites);
    hasher.update(game);
    hasher.update(&.{0});
    hasher.update(assets.version orelse "");
    for (assets.sources.items[1..]) |source| {
        hasher.update(&.{0});
        hasher.update(source.name);
        switch (source.kind) {
            .zip => |zip| {
                const stat = try zip.file.stat(io);
                hasher.update(std.mem.asBytes(&stat.size));
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            },
            .folders => |folders| for (folders) |folder| {
                const stat = try folder.dir.stat(io);
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            },
        }
    }
    return hasher.final();
}

/// The six sections' contents before they're written: the blocks prepared from the assets,
/// with what drawing their sprites needs, and the tables they name.
pub const Contents = struct {
    gameVersion: []const u8,
    mods: []const storyblk.Mod,
    domains: []const []const u8,
    textures: []const TextureColours,
    colourMaps: []const ColourMap,
    /// In the order of the `blocks` section.
    blocks: []Entry,

    pub const Entry = struct {
        code: []const u8,
        block: Block,
        /// The textures in `textures` its colour and grain are from, and its colour maps in
        /// `colourMaps`.
        colour: ?u32 = null,
        grain: ?u32 = null,
        climateColourMap: ?u8 = null,
        seasonColourMap: ?u8 = null,
    };

    /// A colour map, decoded, and its image as the game has it.
    pub const ColourMap = struct {
        map: Tint.ColourMap,
        png: []const u8,
    };

    /// Gives each block its sprites, by its index.
    pub fn useSprites(self: *Contents, sprites: []const world.BlockSprites) void {
        std.debug.assert(sprites.len == self.blocks.len);
        for (self.blocks, sprites) |*entry, own| entry.block.sprites = own;
    }

    pub fn info(self: *const Contents) storyblk.Info {
        return .{ .game = game, .gameVersion = self.gameVersion, .mods = self.mods };
    }

    /// The six sections, in the order of `sectionNames`, their bytes kept in `arena`. A count or
    /// string that doesn't fit its field is an error.
    pub fn encode(self: *const Contents, arena: std.mem.Allocator) ![sectionNames.len]storyblk.Section {
        // Each material and colour code once, in the order blocks first name them.
        var materials: std.StringArrayHashMapUnmanaged(void) = .empty;
        var colourCodes: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (self.blocks) |entry| {
            try materials.put(arena, entry.block.material, {});
            try colourCodes.put(arena, entry.block.colorCode, {});
        }
        if (materials.count() > std.math.maxInt(u8)) return error.TooManyMaterials;
        if (colourCodes.count() > std.math.maxInt(u8)) return error.TooManyColourCodes;
        if (self.colourMaps.len > std.math.maxInt(u8)) return error.TooManyColourMaps;
        if (self.domains.len > std.math.maxInt(u16)) return error.TooManyDomains;
        if (self.blocks.len > std.math.maxInt(u32)) return error.TooManyBlocks;
        if (self.textures.len >= none32) return error.TooManyTextures;

        var blocks: Io.Writer.Allocating = .init(arena);
        var materialNames: Io.Writer.Allocating = .init(arena);
        var colourCodeNames: Io.Writer.Allocating = .init(arena);
        var textures: Io.Writer.Allocating = .init(arena);
        var colourMaps: Io.Writer.Allocating = .init(arena);
        var domains: Io.Writer.Allocating = .init(arena);

        try blocks.writer.writeInt(u32, @intCast(self.blocks.len), .little);
        for (self.blocks) |entry| try writeBlock(&blocks.writer, entry, &materials, &colourCodes);
        try writeStrings(&materialNames.writer, u8, materials.keys());
        try writeStrings(&colourCodeNames.writer, u8, colourCodes.keys());
        try textures.writer.writeInt(u32, @intCast(self.textures.len), .little);
        for (self.textures) |texture| {
            try textures.writer.writeAll(&texture.average);
            for (texture.grain) |sample| try textures.writer.writeAll(&sample);
        }
        try colourMaps.writer.writeByte(@intCast(self.colourMaps.len));
        for (self.colourMaps) |colourMap| {
            try storyblk.writeString(&colourMaps.writer, colourMap.map.code);
            try colourMaps.writer.writeByte(@intCast(colourMap.map.padding));
            try colourMaps.writer.writeByte(@intFromBool(colourMap.map.tropical));
            try colourMaps.writer.writeInt(u32, std.math.cast(u32, colourMap.png.len) orelse return error.ColourMapTooLarge, .little);
            try colourMaps.writer.writeAll(colourMap.png);
        }
        try writeStrings(&domains.writer, u16, self.domains);

        const bytes = [sectionNames.len][]const u8{ blocks.written(), materialNames.written(), colourCodeNames.written(), textures.written(), colourMaps.written(), domains.written() };
        var sections: [sectionNames.len]storyblk.Section = undefined;
        for (&sections, sectionNames, bytes) |*section, name, written| {
            section.* = .{ .name = name, .layoutVersion = layoutVersion, .generatorVersion = generatorVersion, .bytes = written };
        }
        return sections;
    }

    fn writeBlock(w: *Io.Writer, entry: Entry, materials: *const std.StringArrayHashMapUnmanaged(void), colourCodes: *const std.StringArrayHashMapUnmanaged(void)) !void {
        const block = entry.block;
        try storyblk.writeString(w, entry.code);
        try w.writeByte(@intCast(materials.getIndex(block.material).?));
        try w.writeByte(@intCast(colourCodes.getIndex(block.colorCode).?));
        try w.writeInt(u32, entry.colour orelse none32, .little);
        try w.writeInt(u32, entry.grain orelse none32, .little);
        try w.writeByte(entry.climateColourMap orelse none8);
        try w.writeByte(entry.seasonColourMap orelse none8);
        try w.writeByte(block.height orelse none8);
        try w.writeByte(block.drawOffset);
        const flags: BlockFlags = .{
            .xz = block.randomizeAxes == .xz,
            .turned = block.randomizeRotations,
            .shape = block.sprites.shape,
            .tinted = block.sprites.tinted,
        };
        try w.writeByte(@bitCast(flags));
        try w.writeInt(u32, block.sprites.first, .little);
        try w.writeInt(u16, block.sprites.variants, .little);
        try w.writeInt(u16, block.sprites.alternates, .little);
        try w.writeByte(block.sprites.turns);
    }
};

/// A Block's `flags` (spec §4).
const BlockFlags = packed struct(u8) {
    /// Its variant, alternate and turn are picked by x and z alone (`randomizeAxes: xz`).
    xz: bool = false,
    /// It's turned by where it is (`randomizeRotations`).
    turned: bool = false,
    /// It's drawn in its shape, rather than as a cube.
    shape: bool = false,
    /// Any of its sprites has a tinted layer.
    tinted: bool = false,
    _: u4 = 0,
};

/// A Block's index of none, in a field of one byte or four.
const none8 = 0xFF;
const none32 = 0xFFFFFFFF;

/// A list of strings, counted by a `Count`.
fn writeStrings(w: *Io.Writer, comptime Count: type, strings: []const []const u8) !void {
    try w.writeInt(Count, @intCast(strings.len), .little);
    for (strings) |string| try storyblk.writeString(w, string);
}

/// Reads the blocks from `assets`, with what drawing their sprites needs, keeping them in
/// `arena`, and what only reading them needs in memory from `gpa`, freed before it returns.
/// Blocks with the same faces share their lists of variants, and blocks placed the same their
/// boxes: `isometric.drawSprites` tells them apart by those slices.
pub fn prepare(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, assets: *const Assets) !Contents {
    var temporaryArena: std.heap.ArenaAllocator = .init(gpa);
    defer temporaryArena.deinit();
    const temporary = temporaryArena.allocator();
    const types = try BlockTypes.expand(temporary, io, assets);
    var textures: Textures = .{ .arena = temporary, .io = io, .assets = assets };
    var images: Images = .{ .arena = arena, .textures = &textures };
    const colourMaps = try prepareColourMaps(arena, temporary, io, assets);
    var geometries: std.AutoHashMapUnmanaged(*const BlockTypes.Geometry, []const world.Shape.Box) = .empty;
    const blocks = try arena.alloc(Contents.Entry, types.len);
    for (blocks, types, 0..) |*entry, block, i| {
        entry.* = .{
            .code = try arena.dupe(u8, block.code),
            .block = .{
                .index = @intCast(i),
                .material = try arena.dupe(u8, block.material),
                .colorCode = try arena.dupe(u8, block.colorCode),
                .cube = try cubeOf(&images, block.cube),
                .height = block.height,
                .shapes = try shapesOf(arena, temporary, &images, &geometries, block.shapes),
                .drawOffset = block.drawOffset,
                .randomizeAxes = block.randomizeAxes,
                .randomizeRotations = block.randomizeRotations,
            },
            .colour = try textures.index(block.textures.colour),
            .grain = try textures.index(block.textures.grain),
            .climateColourMap = colourMapIndex(colourMaps, block.climateColorMap),
            .seasonColourMap = colourMapIndex(colourMaps, block.seasonColorMap),
        };
    }
    // Pointing into the textures and colour maps once all are read.
    const colours = try arena.alloc(TextureColours, textures.read.items.len);
    for (colours, textures.read.items) |*texture, read| texture.* = read.colours;
    for (blocks) |*entry| {
        if (entry.colour) |i| entry.block.colour = colours[i].average;
        if (entry.grain) |i| entry.block.grain = &colours[i].grain;
        if (entry.climateColourMap) |i| entry.block.climateColourMap = &colourMaps[i].map;
        if (entry.seasonColourMap) |i| entry.block.seasonColourMap = &colourMaps[i].map;
    }
    const mods = try arena.alloc(storyblk.Mod, assets.sources.items.len - 1);
    for (mods, assets.sources.items[1..]) |*mod, source| mod.* = source.mod.?;
    return .{
        .gameVersion = assets.version orelse "",
        .mods = mods,
        .domains = assets.domains.keys(),
        .textures = colours,
        .colourMaps = colourMaps,
        .blocks = blocks,
    };
}

/// A block's cube faces, each layer the images of its variants; null without a cube, or for one
/// with a face that can't be read, which is drawn in its colour instead.
fn cubeOf(images: *Images, cube: ?BlockTypes.Cube) !?world.CubeFaces {
    const faces = cube orelse return null;
    var out: [3]world.CubeFaces.Face = undefined;
    for (&out, [_]BlockTypes.Face{ faces.up, faces.south, faces.east }) |*face, from| {
        face.* = .{ .plain = try images.list(from.plain), .tinted = try images.list(from.tinted) };
        if ((from.plain != null and face.plain.len == 0) or (from.tinted != null and face.tinted.len == 0)) return null;
        if (face.plain.len == 0 and face.tinted.len == 0) return null;
    }
    return .{ .up = out[0], .south = out[1], .east = out[2] };
}

/// A block's shapes, each its geometry's boxes, one slice for each geometry, and its textures'
/// images. A shape with nothing to draw has no boxes or textures.
fn shapesOf(arena: std.mem.Allocator, temporary: std.mem.Allocator, images: *Images, geometries: *std.AutoHashMapUnmanaged(*const BlockTypes.Geometry, []const world.Shape.Box), shapes: []const BlockTypes.Shape) ![]const world.Shape {
    if (shapes.len == 0) return &.{};
    const out = try arena.alloc(world.Shape, shapes.len);
    for (out, shapes) |*shape, from| {
        if (from.geometry.boxes.len == 0) {
            shape.* = .{ .boxes = &.{}, .textures = &.{} };
            continue;
        }
        const boxes = try geometries.getOrPut(temporary, from.geometry);
        if (!boxes.found_existing) boxes.value_ptr.* = try boxesOf(arena, from.geometry.boxes);
        const textures = try arena.alloc(world.CubeFaces.Face, from.textures.len);
        for (textures, from.textures) |*texture, face| texture.* = .{ .plain = try images.list(face.plain), .tinted = try images.list(face.tinted) };
        shape.* = .{ .boxes = boxes.value_ptr.*, .textures = textures };
    }
    return out;
}

fn boxesOf(arena: std.mem.Allocator, boxes: []const BlockTypes.Geometry.Box) ![]const world.Shape.Box {
    const out = try arena.alloc(world.Shape.Box, boxes.len);
    for (out, boxes) |*box, from| {
        box.* = .{ .transform = from.transform, .size = from.size, .shade = from.shade, .faces = undefined };
        for (&box.faces, from.faces) |*face, side| face.* = if (side) |f| .{ .texture = f.texture, .uv = f.uv } else null;
    }
    return out;
}

/// Cube faces' images, each made once: a texture with its overlays drawn over it, or half of
/// it, by index in the order they're first needed.
const Images = struct {
    /// Where the images and their lists are kept; what's only needed to make them is in
    /// `textures.arena`.
    arena: std.mem.Allocator,
    textures: *Textures,
    /// Each layer met so far, by its textures and half, and its index, or null if it can't be
    /// made.
    indexes: std.StringHashMapUnmanaged(?usize) = .empty,
    made: std.ArrayList(*const Image) = .empty,
    /// Each list of images made so far, by their indexes, as one slice.
    lists: std.StringHashMapUnmanaged([]const *const Image) = .empty,

    /// The images of the layer's variants (`variants`), the same slice for the same images;
    /// none without a layer or if none can be made.
    fn list(self: *Images, layer: ?BlockTypes.Layer) ![]const *const Image {
        const indexes = try self.variants(layer) orelse return &.{};
        const entry = try self.lists.getOrPut(self.textures.arena, std.mem.sliceAsBytes(indexes));
        if (entry.found_existing) return entry.value_ptr.*;
        const found = try self.arena.alloc(*const Image, indexes.len);
        for (found, indexes) |*image, i| image.* = self.made.items[i];
        entry.value_ptr.* = found;
        return found;
    }

    /// The indexes of the layer's images, one for each of its variants that can be made, each
    /// made the first time; null without a layer or if none can be made. Its variants are in the
    /// game's order (vsapi `CompositeTexture.Bake`): its base's first file with its overlays,
    /// then each of its alternates' first file with the alternate's overlays, then its base's
    /// other files, without overlays.
    fn variants(self: *Images, layer: ?BlockTypes.Layer) !?[]const usize {
        const wanted = layer orelse return null;
        const arena = self.textures.arena;
        var found: std.ArrayList(usize) = .empty;
        const files = try self.textures.paths(wanted.base);
        if (files.len > 0) if (try self.index(wanted, files[0])) |i| try found.append(arena, i);
        for (wanted.alternates) |alternate| {
            const alternateFiles = try self.textures.paths(alternate.base);
            if (alternateFiles.len > 0) if (try self.index(alternate, alternateFiles[0])) |i| try found.append(arena, i);
        }
        const bare: BlockTypes.Layer = .{ .base = wanted.base, .half = wanted.half };
        if (files.len > 1) for (files[1..]) |path| {
            if (try self.index(bare, path)) |i| try found.append(arena, i);
        };
        return if (found.items.len == 0) null else found.items;
    }

    /// The index of the layer's image with `path` as its base, made the first time, or null if
    /// it can't be made.
    fn index(self: *Images, layer: BlockTypes.Layer, path: []const u8) !?usize {
        const arena = self.textures.arena;
        var name: std.Io.Writer.Allocating = .init(arena);
        try name.writer.print("{s}:{s}", .{ domainOf(layer.base), path });
        for (layer.overlays) |overlay| try name.writer.print("+{s}", .{overlay});
        if (layer.half) |half| try name.writer.print("#{t}", .{half});
        const entry = try self.indexes.getOrPut(arena, name.written());
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        const made = try self.make(layer, path) orelse return null;
        const image = try self.arena.create(Image);
        image.* = .{ .width = made.width, .height = made.height, .pixels = try self.arena.dupe([4]u8, made.pixels) };
        try self.made.append(arena, image);
        entry.value_ptr.* = self.made.items.len - 1;
        return entry.value_ptr.*;
    }

    fn make(self: *Images, layer: BlockTypes.Layer, path: []const u8) !?Image {
        const arena = self.textures.arena;
        const png = try self.textures.assets.read(arena, self.textures.io, domainOf(layer.base), path) orelse return null;
        var image = try decode(arena, png) orelse return null;
        if (layer.half) |half| image = halfOf(arena, image, half) orelse return null;
        // An overlay that can't be read is left out, as the game leaves out a missing texture.
        for (layer.overlays) |location| {
            const overlay = try decode(arena, try self.textures.readPng(location) orelse continue) orelse continue;
            drawOver(@constCast(image.pixels), image.width, image.height, overlay);
        }
        return image;
    }
};

/// A PNG's pixels, copied into `arena`; null if it can't be decoded or is larger than an
/// `Image` holds.
fn decode(arena: std.mem.Allocator, png: []const u8) !?Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = stb.stbi_load_from_memory(png.ptr, @intCast(png.len), &width, &height, &channels, 4) orelse return null;
    defer stb.stbi_image_free(data);
    if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return null;
    const count: usize = @intCast(width * height);
    const pixels = try arena.dupe([4]u8, @as([*]const [4]u8, @ptrCast(data))[0..count]);
    return .{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}

/// The left or right half of an image twice as wide as tall; null for any other.
fn halfOf(arena: std.mem.Allocator, image: Image, half: BlockTypes.Layer.Half) ?Image {
    if (image.width != 2 * image.height) return null;
    const side = image.height;
    const pixels = arena.alloc([4]u8, @as(usize, side) * side) catch return null;
    const offset: usize = if (half == .right) side else 0;
    for (0..side) |row| @memcpy(pixels[row * side ..][0..side], image.pixels[row * image.width + offset ..][0..side]);
    return .{ .width = side, .height = side, .pixels = pixels };
}

/// Draws `overlay` over `pixels`, by its opacity, stretched or shrunk to their size, taking
/// the nearest of its pixels.
fn drawOver(pixels: [][4]u8, width: u16, height: u16, overlay: Image) void {
    for (0..height) |y| for (0..width) |x| {
        const top = overlay.pixels[(y * overlay.height / height) * overlay.width + x * overlay.width / width];
        const under = &pixels[y * width + x];
        const a: u32 = top[3];
        const below: u32 = @as(u32, under[3]) * (255 - a) / 255;
        const alpha = a + below;
        if (alpha == 0) continue;
        for (0..3) |c| under[c] = @intCast((@as(u32, top[c]) * a + @as(u32, under[c]) * below) / alpha);
        under[3] = @intCast(alpha);
    };
}

test drawOver {
    var pixels = [_][4]u8{ .{ 0, 0, 255, 255 }, .{ 0, 0, 255, 255 } };
    // Opaque red on the left, half-transparent red on the right, from a 1 × 1 and 2 × 1 overlay.
    drawOver(&pixels, 2, 1, .{ .width = 2, .height = 1, .pixels = &.{ .{ 255, 0, 0, 255 }, .{ 255, 0, 0, 128 } } });
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixels[0]);
    try std.testing.expectEqual([4]u8{ 128, 0, 127, 255 }, pixels[1]);
}

/// The colour maps in the game's `config/colormaps.json` whose images can be read and decoded,
/// in the file's order, kept in `arena`.
fn prepareColourMaps(arena: std.mem.Allocator, temporary: std.mem.Allocator, io: Io, assets: *const Assets) ![]const Contents.ColourMap {
    const file = "config/colormaps.json";
    const bytes = try assets.read(temporary, io, Assets.gameDomain, file) orelse return &.{};
    const json = Json.parse(temporary, bytes) catch |err| {
        console.warn("{s}: could not read ({s}); nothing will be tinted", .{ file, @errorName(err) });
        return &.{};
    };
    if (json != .array) return &.{};
    var maps: std.ArrayList(Contents.ColourMap) = .empty;
    for (json.array) |entry| {
        const code = (entry.get("code") orelse continue).asString() orelse continue;
        const base = ((entry.get("texture") orelse continue).get("base") orelse continue).asString() orelse continue;
        const colon = std.mem.indexOfScalar(u8, base, ':');
        const domain = if (colon) |c| base[0..c] else Assets.gameDomain;
        const path = try std.fmt.allocPrint(temporary, "textures/{s}.png", .{if (colon) |c| base[c + 1 ..] else base});
        const png = try assets.read(arena, io, domain, path) orelse {
            console.warn("colour map {s}: no image {s}:{s}", .{ code, domain, path });
            continue;
        };
        const padding = integer(entry.get("padding"));
        const map = if (padding <= std.math.maxInt(u8)) try Tint.ColourMap.decode(arena, try arena.dupe(u8, code), png, padding, integer(entry.get("extraFlags")) == 1) else null;
        try maps.append(arena, .{ .map = map orelse {
            console.warn("colour map {s}: could not read its image {s}:{s}", .{ code, domain, path });
            continue;
        }, .png = png });
    }
    return maps.items;
}

/// A whole number in the game's JSON, or 0 without one.
fn integer(value: ?Json.Value) usize {
    const number = value orelse return 0;
    if (number != .number) return 0;
    return std.fmt.parseInt(usize, number.number, 10) catch 0;
}

fn colourMapIndex(maps: []const Contents.ColourMap, code: ?[]const u8) ?u8 {
    const wanted = code orelse return null;
    for (maps, 0..) |map, i| if (std.mem.eql(u8, map.map.code, wanted)) return std.math.cast(u8, i);
    return null;
}

/// The textures the blocks name, each read once, by index in the order they're first named.
const Textures = struct {
    arena: std.mem.Allocator,
    io: Io,
    assets: *const Assets,
    /// Each location named so far, and its index, or null if it can't be read.
    indexes: std.StringHashMapUnmanaged(?u32) = .empty,
    read: std.ArrayList(struct { location: []const u8, colours: TextureColours }) = .empty,
    /// Every texture file, listed the first time a location ends in `*`.
    files: ?[]const Assets.Name = null,

    /// Reads the texture the first time; null without a location or if it can't be read.
    fn index(self: *Textures, location: ?[]const u8) !?u32 {
        const wanted = location orelse return null;
        const entry = try self.indexes.getOrPut(self.arena, wanted);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        const colours = try self.readColours(wanted) orelse return null;
        try self.read.append(self.arena, .{ .location = wanted, .colours = colours });
        entry.value_ptr.* = @intCast(self.read.items.len - 1);
        return entry.value_ptr.*;
    }

    fn readColours(self: *Textures, location: []const u8) !?TextureColours {
        const png = try self.readPng(location) orelse return null;
        return TextureColours.ofPng(png);
    }

    /// The texture's file, or for a location ending in `*`, the first file it starts; null if
    /// there's none.
    fn readPng(self: *Textures, location: []const u8) !?[]const u8 {
        const files = try self.paths(location);
        if (files.len == 0) return null;
        return self.assets.read(self.arena, self.io, domainOf(location), files[0]);
    }

    /// The texture's file, in its location's domain; or for a location ending in `*`, every file
    /// it starts, by name: the first is the texture and the others its variants (vsapi
    /// `CompositeTexture.Bake`).
    fn paths(self: *Textures, location: []const u8) ![]const []const u8 {
        const domain = domainOf(location);
        const path = try std.fmt.allocPrint(self.arena, "textures/{s}.png", .{location[domain.len + 1 ..]});
        if (!std.mem.endsWith(u8, location, "*")) return self.arena.dupe([]const u8, &.{path});
        const start = path[0 .. path.len - "*.png".len];
        const files = self.files orelse try self.assets.list(self.arena, self.io, "textures");
        self.files = files;
        var found: std.ArrayList([]const u8) = .empty;
        for (files) |file| {
            if (std.mem.eql(u8, file.domain, domain) and std.mem.startsWith(u8, file.path, start) and std.mem.endsWith(u8, file.path, ".png")) try found.append(self.arena, file.path);
        }
        return found.items;
    }
};

/// The domain of a location such as `game:block/stone/granite1`.
fn domainOf(location: []const u8) []const u8 {
    return location[0..std.mem.indexOfScalar(u8, location, ':').?];
}

/// The bytes of the smallest Block, with an empty code.
const blockLength = 2 + 1 + 1 + 4 + 4 + 1 + 1 + 1 + 1 + 1 + 4 + 2 + 2 + 1;
/// The bytes of a TextureColours.
const textureLength = 3 + TextureColours.samples * 3;

/// The blocks in the six sections of `file`, each block's sprites checked against
/// `spriteCount`, the `sprites` section's count. Their codes, materials, colour codes, domains
/// and grain are where `file` is, which must outlive the result. A section that's missing, of
/// another layout, or not as the spec has it is error.NotPreparedBlocks.
pub fn load(allocator: std.mem.Allocator, file: *const storyblk.File, spriteCount: usize) !Prepared {
    var self: Prepared = .{ .arena = .init(allocator), .gameVersion = file.info.gameVersion, .mods = file.info.mods };
    errdefer self.deinit();
    const arena = self.arena.allocator();
    const materials = try readStrings(arena, u8, try file.section("materials", layoutVersion));
    const colourCodes = try readStrings(arena, u8, try file.section("colour_codes", layoutVersion));
    const domains = try readStrings(arena, u16, try file.section("domains", layoutVersion));
    for (domains) |domain| try self.domains.put(arena, domain, {});

    var textures: storyblk.Reader = .{ .bytes = (try file.section("texture_colours", layoutVersion)).bytes };
    const textureCount = try textures.int(u32);
    if (textures.bytes.len != 4 + @as(u64, textureCount) * textureLength) return error.NotPreparedBlocks;

    var colourMapsReader: storyblk.Reader = .{ .bytes = (try file.section("colour_maps", layoutVersion)).bytes };
    // Null where an image can't be decoded, so the indexes still count.
    const colourMaps = try arena.alloc(?*const Tint.ColourMap, try colourMapsReader.int(u8));
    for (colourMaps) |*colourMap| {
        const code = try colourMapsReader.string();
        const padding = try colourMapsReader.int(u8);
        const flags = try colourMapsReader.int(u8);
        const png = try colourMapsReader.take(try colourMapsReader.int(u32));
        colourMap.* = null;
        const decoded = try Tint.ColourMap.decode(arena, code, png, padding, flags & 1 != 0) orelse continue;
        const map = try arena.create(Tint.ColourMap);
        map.* = decoded;
        colourMap.* = map;
    }

    var blocks: storyblk.Reader = .{ .bytes = (try file.section("blocks", layoutVersion)).bytes };
    const count = try blocks.int(u32);
    if (count > blocks.bytes.len / blockLength) return error.NotPreparedBlocks;
    try self.blocks.ensureTotalCapacity(arena, count);
    for (0..count) |i| {
        const code = try blocks.string();
        const material = try indexed([]const u8, materials, try blocks.int(u8));
        const colorCode = try indexed([]const u8, colourCodes, try blocks.int(u8));
        const colour = try textureAt(textures.bytes, textureCount, try blocks.int(u32));
        const grain = try textureAt(textures.bytes, textureCount, try blocks.int(u32));
        const climate = try colourMapAt(colourMaps, try blocks.int(u8));
        const season = try colourMapAt(colourMaps, try blocks.int(u8));
        const height = try blocks.int(u8);
        const drawOffset = try blocks.int(u8);
        const flags: BlockFlags = @bitCast(try blocks.int(u8));
        const sprites: world.BlockSprites = .{
            .first = try blocks.int(u32),
            .variants = try blocks.int(u16),
            .alternates = try blocks.int(u16),
            .turns = try blocks.int(u8),
            .shape = flags.shape,
            .tinted = flags.tinted,
        };
        if (sprites.variants > 0 and (sprites.alternates == 0 or sprites.turns == 0)) return error.NotPreparedBlocks;
        if (sprites.variants > 0 and @as(u64, sprites.first) + sprites.count() > spriteCount) return error.NotPreparedBlocks;
        self.blocks.putAssumeCapacity(code, .{
            .index = @intCast(i),
            .material = material,
            .colorCode = colorCode,
            .colour = if (colour) |texture| texture[0..3].* else null,
            .grain = if (grain) |texture| std.mem.bytesAsSlice(world.Rgb, texture[3..]) else &.{},
            .climateColourMap = climate,
            .seasonColourMap = season,
            .height = if (height == none8) null else height,
            .drawOffset = drawOffset,
            .randomizeAxes = if (flags.xz) .xz else .xyz,
            .randomizeRotations = flags.turned,
            .sprites = sprites,
        });
    }
    return self;
}

/// A section's list of strings, counted by a `Count`.
fn readStrings(arena: std.mem.Allocator, comptime Count: type, section: storyblk.Section) ![]const []const u8 {
    var reader: storyblk.Reader = .{ .bytes = section.bytes };
    const strings = try arena.alloc([]const u8, try reader.int(Count));
    for (strings) |*string| string.* = try reader.string();
    return strings;
}

fn indexed(comptime T: type, items: []const T, i: usize) error{NotPreparedBlocks}!T {
    return if (i < items.len) items[i] else error.NotPreparedBlocks;
}

/// TextureColours `i` in `texture_colours`, `bytes`, or null for none.
fn textureAt(bytes: []const u8, count: u32, i: u32) error{NotPreparedBlocks}!?*const [textureLength]u8 {
    if (i == none32) return null;
    if (i >= count) return error.NotPreparedBlocks;
    return bytes[4 + @as(usize, i) * textureLength ..][0..textureLength];
}

fn colourMapAt(maps: []const ?*const Tint.ColourMap, i: u8) error{NotPreparedBlocks}!?*const Tint.ColourMap {
    if (i == none8) return null;
    return indexed(?*const Tint.ColourMap, maps, i);
}

/// What a save's blocks have that the prepared blocks don't: the mods (domains) it lacks, and
/// how many codes in known domains it lacks, with an example.
pub const Unknown = struct {
    mods: []const []const u8,
    codes: usize,
    example: ?[]const u8,
};

pub fn unknown(self: *const Prepared, allocator: std.mem.Allocator, codes: []const ?[]const u8) !Unknown {
    var mods: std.ArrayList([]const u8) = .empty;
    errdefer mods.deinit(allocator);
    var count: usize = 0;
    var example: ?[]const u8 = null;
    codes: for (codes) |maybeCode| {
        const code = maybeCode orelse continue;
        if (self.blocks.contains(code)) continue;
        for (builtInBlocks) |builtIn| if (std.mem.eql(u8, code, builtIn)) continue :codes;
        const colon = std.mem.indexOfScalar(u8, code, ':');
        const domain = if (colon) |c| code[0..c] else Assets.gameDomain;
        if (!self.domains.contains(domain)) {
            for (mods.items) |seen| {
                if (std.mem.eql(u8, seen, domain)) break;
            } else try mods.append(allocator, domain);
            continue;
        }
        count += 1;
        if (example == null) example = code;
    }
    return .{ .mods = try mods.toOwnedSlice(allocator), .codes = count, .example = example };
}

fn find(contents: *const Contents, code: []const u8) *const Block {
    for (contents.blocks) |*entry| if (std.mem.eql(u8, entry.code, code)) return &entry.block;
    unreachable;
}

fn expectTransformRow(expected: [4]f32, actual: [4]f32) !void {
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-6);
}

test "prepare, write, load and compare with a save" {
    // Keeps the expected warnings off stderr, where the build runner would print them.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "game/assets/version-1.22.7.txt", "" },
        .{ "game/assets/survival/worldproperties/block/rock.json", "{ code: 'rock', variants: [ { code: 'granite' } ] }" },
        .{ "game/assets/survival/blocktypes/rock.json", "{ code: 'rock', variantgroups: [ { loadFromProperties: 'block/rock' } ], textures: { all: { base: 'block/stone/{rock}*' } }, climateColorMap: 'climateTest', seasonColorMap: 'missing' }" },
        .{ "game/assets/survival/textures/block/stone/granite1.png", @embedFile("testdata/red.png") },
        .{ "game/assets/survival/config/colormaps.json", "[ { code: 'climateTest', texture: { base: 'environment/test' } }, { code: 'missing', texture: { base: 'environment/none' } } ]" },
        .{ "game/assets/game/textures/environment/test.png", @embedFile("testdata/red.png") },
        .{ "game/assets/survival/textures/block/stone/granite2.png", "not a PNG: a variant that can't be read is left out" },
        .{ "game/assets/survival/textures/block/stone/granite3.png", @embedFile("testdata/red.png") },
        .{ "game/assets/survival/blocktypes/soil.json", "{ code: 'soil', drawtype: 'TopSoil', textures: { all: { base: 'block/stone/granite*' }, specialSecondTexture: { base: 'block/grass' } } }" },
        .{ "game/assets/survival/textures/block/grass.png", @embedFile("testdata/red.png") },
        .{ "game/assets/survival/blocktypes/step.json", "{ code: 'step', shape: { base: 'block/step', alternates: [ { rotateY: 180 }, { base: 'block/missing' } ] }, textures: { all: { base: 'block/stone/granite*' } } }" },
        .{ "game/assets/survival/shapes/block/step.json", "{ elements: [ { from: [ 0, 0, 0 ], to: [ 16, 8, 16 ], rotationOrigin: [ 8, 8, 8 ], rotationY: 90, faces: { north: { texture: '#all', uv: [ 0, 0, 16, 8 ] }, up: { texture: '#top' } } } ] }" },
        .{ "game/assets/survival/blocktypes/ore.json", "{ code: 'ore', drawtype: 'Cube', textures: { all: { base: 'block/stone/granite*', overlays: [ 'block/grass' ], alternates: [ { base: 'block/grass' }, { base: 'block/missing' } ] } } }" },
        .{ "data/Mods/testmod.zip", @embedFile("testdata/testmod.zip") },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var gameDir = try tmp.dir.openDir(io, "game", .{});
    defer gameDir.close(io);
    var dataDir = try tmp.dir.openDir(io, "data", .{});
    defer dataDir.close(io);
    var assets = try Assets.open(std.testing.allocator, io, gameDir, dataDir);
    defer assets.close(io);

    const sprites: SpriteFormat = .{ .generatorVersion = 4, .layoutVersion = 1, .blockWidth = 32 };
    const first = try hash(io, &assets, sprites);
    try std.testing.expectEqual(first, try hash(io, &assets, sprites));
    try std.testing.expect(first != try hash(io, &assets, .{ .generatorVersion = 5, .layoutVersion = 1, .blockWidth = 32 }));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var contents = try prepare(std.testing.allocator, arena.allocator(), io, &assets);
    // rock-granite, soil, step, ore, and the test mod's thing.
    try std.testing.expectEqual(5, contents.blocks.len);
    // The colour map without an image is left out.
    try std.testing.expectEqual(1, contents.colourMaps.len);

    // With a colour map, the rock's faces are its whole texture, tinted: granite1 and granite3,
    // its variants that can be read, the same list on every face.
    const rock = find(&contents, "rock-granite").cube.?;
    try std.testing.expectEqual(0, rock.up.plain.len);
    try std.testing.expectEqual(2, rock.up.tinted.len);
    try std.testing.expectEqual(2, rock.up.tinted[0].width);
    try std.testing.expect(rock.up.tinted[0] != rock.up.tinted[1]);
    try std.testing.expectEqual(rock.up.tinted.ptr, rock.south.tinted.ptr);
    // The soil's grass is half its second texture, the right on top and the left on the sides.
    const soil = find(&contents, "soil").cube.?;
    try std.testing.expectEqual(rock.up.tinted.ptr, soil.up.plain.ptr);
    try std.testing.expectEqual(1, soil.up.tinted[0].width);
    try std.testing.expectEqual(1, soil.south.tinted[0].width);
    try std.testing.expectEqual(soil.south.tinted.ptr, soil.east.tinted.ptr);
    try std.testing.expectEqual(rock.up.tinted[0].pixels[1], soil.up.tinted[0].pixels[0]);
    try std.testing.expectEqual(rock.up.tinted[0].pixels[0], soil.south.tinted[0].pixels[0]);
    try std.testing.expectEqual(0, find(&contents, "rock-granite").shapes.len);
    // The ore's variants in the game's order: granite1 under its overlay, then its alternate, the
    // grass whole, then granite3 without the overlay, the rock's own image; the missing
    // alternate and the granite that can't be read are left out.
    const ore = find(&contents, "ore").cube.?;
    try std.testing.expectEqual(3, ore.up.plain.len);
    try std.testing.expect(ore.up.plain[0] != rock.up.tinted[0]);
    try std.testing.expectEqual(2, ore.up.plain[1].width);
    try std.testing.expect(ore.up.plain[1] != rock.up.tinted[0] and ore.up.plain[1] != rock.up.tinted[1]);
    try std.testing.expectEqual(rock.up.tinted[1], ore.up.plain[2]);

    // The step's one box, turned a quarter about its origin, half a block high. Both its faces
    // are the granite, untinted, the same images as the rock's: one by name, and one by `all`,
    // naming a texture the block doesn't have.
    const step = find(&contents, "step");
    try std.testing.expectEqual(null, step.cube);
    try std.testing.expectEqual(3, step.shapes.len);
    const shape = step.shapes[0];
    try std.testing.expectEqual(1, shape.boxes.len);
    const box = shape.boxes[0];
    try std.testing.expectEqual([3]f32{ 1, 0.5, 1 }, box.size);
    try expectTransformRow(.{ 0, 0, 1, 0 }, box.transform[0]);
    try expectTransformRow(.{ -1, 0, 0, 1 }, box.transform[2]);
    try std.testing.expect(box.shade);
    const north = box.faces[@backingInt(world.Shape.Side.north)].?;
    try std.testing.expectEqual([4][2]f32{ .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0.5 } }, north.uv);
    const up = box.faces[@backingInt(world.Shape.Side.up)].?;
    try std.testing.expectEqual(2, shape.textures.len);
    for ([_]world.Shape.Face{ north, up }) |face| {
        try std.testing.expectEqual(rock.up.tinted.ptr, shape.textures[face.texture].plain.ptr);
        try std.testing.expectEqual(0, shape.textures[face.texture].tinted.len);
    }
    try std.testing.expectEqual(null, box.faces[@backingInt(world.Shape.Side.down)]);
    // Its alternates: the step turned half about the block's middle, in the same textures, and
    // a shape with nothing to draw, which keeps its place.
    const turned = step.shapes[1];
    try std.testing.expectEqual(1, turned.boxes.len);
    try std.testing.expect(turned.boxes.ptr != shape.boxes.ptr);
    try std.testing.expectApproxEqAbs(1, turned.boxes[0].transform[0][3], 1e-5);
    try std.testing.expectEqual(shape.textures[0].plain.ptr, turned.textures[0].plain.ptr);
    try std.testing.expectEqual(0, step.shapes[2].boxes.len);

    // The rock in two sprites, and the step in three; the others in none.
    var drawn: [5]world.BlockSprites = @splat(.{});
    drawn[find(&contents, "rock-granite").index] = .{ .first = 0, .variants = 2, .tinted = true };
    drawn[step.index] = .{ .first = 2, .variants = 1, .alternates = 3, .shape = true };
    contents.useSprites(&drawn);

    const sections = try contents.encode(arena.allocator());
    try storyblk.writeFile(io, tmp.dir, "prepared.storyblk", first, contents.info(), &sections);
    const written = try tmp.dir.readFileAlloc(io, "prepared.storyblk", arena.allocator(), .unlimited);
    const bytes = try arena.allocator().alignedAlloc(u8, .@"8", written.len);
    @memcpy(bytes, written);
    const file = try storyblk.parse(arena.allocator(), bytes);
    try std.testing.expectEqualStrings(game, file.info.game);

    var prepared = try load(std.testing.allocator, &file, 5);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("1.22.7", prepared.gameVersion);
    try std.testing.expectEqualDeep(storyblk.Mod{ .file = "testmod.zip", .id = "testmod", .version = "1.0.0" }, prepared.mods[0]);
    try std.testing.expect(prepared.domains.contains("game") and prepared.domains.contains("testmod"));
    const granite = prepared.blocks.get("rock-granite").?;
    try std.testing.expectEqualStrings("Stone", granite.material);
    try std.testing.expectEqualStrings("land", granite.colorCode);
    // The transparent pixel counts for nothing.
    try std.testing.expectEqual(world.Rgb{ 200, 40, 20 }, granite.colour.?);
    try std.testing.expectEqualSlices(world.Rgb, find(&contents, "rock-granite").grain, granite.grain);
    // The colour map's image, 2 × 1; the other one has none, so it isn't there.
    try std.testing.expectEqualStrings("climateTest", granite.climateColourMap.?.code);
    try std.testing.expectEqual(2, granite.climateColourMap.?.width);
    try std.testing.expectEqual(null, granite.seasonColourMap);
    try std.testing.expectEqual(world.BlockSprites{ .first = 0, .variants = 2, .tinted = true }, granite.sprites);
    try std.testing.expectEqual(drawn[step.index], prepared.blocks.get("step").?.sprites);
    try std.testing.expectEqual(null, prepared.blocks.get("testmod:thing").?.colour);
    // Each block's index is its place in the file, and the file keeps their sprites, not what
    // they're drawn from.
    var blocks = prepared.blocks.iterator();
    while (blocks.next()) |entry| {
        const block = entry.value_ptr.*;
        const before = find(&contents, entry.key_ptr.*);
        try std.testing.expectEqual(before.index, block.index);
        try std.testing.expectEqual(before.height, block.height);
        try std.testing.expectEqual(before.randomizeAxes, block.randomizeAxes);
        try std.testing.expectEqual(null, block.cube);
        try std.testing.expectEqual(0, block.shapes.len);
    }

    // The step's sprites go past the last of 4.
    try std.testing.expectError(error.NotPreparedBlocks, load(std.testing.allocator, &file, 4));
    // A file without one of the sections, or with a block naming a material that isn't there,
    // isn't one.
    var missing = file;
    missing.sections = file.sections[1..];
    try std.testing.expectError(error.NotPreparedBlocks, load(std.testing.allocator, &missing, 5));
    var changed = file;
    const sectionsCopy = try arena.allocator().dupe(storyblk.Section, file.sections);
    const blocksBytes = try arena.allocator().dupe(u8, sectionsCopy[0].bytes);
    blocksBytes[6 + std.mem.readInt(u16, blocksBytes[4..6], .little)] = 200;
    sectionsCopy[0].bytes = blocksBytes;
    changed.sections = sectionsCopy;
    try std.testing.expectError(error.NotPreparedBlocks, load(std.testing.allocator, &changed, 5));

    const codes = [_]?[]const u8{ "air", "rock-granite", "rock-basalt", null, "testmod:thing", "othermod:x", "othermod:y" };
    const missingCodes = try prepared.unknown(std.testing.allocator, &codes);
    defer std.testing.allocator.free(missingCodes.mods);
    try std.testing.expectEqual(1, missingCodes.mods.len);
    try std.testing.expectEqualStrings("othermod", missingCodes.mods[0]);
    try std.testing.expectEqual(1, missingCodes.codes);
    try std.testing.expectEqualStrings("rock-basalt", missingCodes.example.?);
}
