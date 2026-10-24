//! The game's and mods' blocks as rendering needs them, prepared once from their assets so a
//! render never reads assets itself (docs/rendering.md#preparing-blocks).
//!
//! A prepared set is a folder `<blocks folder>/<key>/` (see `key`) holding `blocks.txt`.
//! Textures come first, each with its average colour and grain (`TextureColours`), then the
//! colour maps with their padding and flags, each image beside it as `colormaps/<code>.png`.
//! Blocks name their two textures and their climate and season colour maps by number from 0,
//! or `-` for none, then, for a block drawn as a cube, the images of its faces' plain and
//! tinted layers (`world.CubeFaces`), top, south and east, by number in `textures.bin`, a
//! texture's variants separated by commas:
//!
//!     storymap blocks 6
//!     game 1.22.7
//!     mod primitivesurvival_5.1.4.zip
//!     domain game
//!     domain primitivesurvival
//!     texture game:block/stone/rock/granite1 8A7F78 978B83 …
//!     …
//!     colormap climatePlantTint 4 0
//!     …
//!     block rock-granite Stone land 0 0 - - 0,1,2,3 - 0,1,2,3 - 0,1,2,3 -
//!     …
//!
//! `textures.bin` holds the face images one after another, each its width and height as
//! little-endian u16s, then its pixels, row by row, red, green, blue and alpha.
const Prepared = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const world = @import("world");
const console = @import("console");
const Assets = @import("Assets.zig");
const BlockTypes = @import("BlockTypes.zig");
const TextureColours = @import("TextureColours.zig");
const Json = @import("Json.zig");
const Tint = @import("Tint.zig");
const stb = @import("stb_image");

arena: std.heap.ArenaAllocator,
gameVersion: []const u8 = "",
mods: std.ArrayList([]const u8) = .empty,
/// The domains the game and mods have assets in.
domains: std.StringHashMapUnmanaged(void) = .empty,
/// Every block, by its code as a save names it.
blocks: std.StringHashMapUnmanaged(Block) = .empty,

pub const Block = struct {
    /// One of `BlockTypes.materials`, e.g. "Stone".
    material: []const u8,
    /// Its colour on the game's map, e.g. "land" or "forest" (docs/rendering.md#block-colours).
    colorCode: []const u8,
    /// Its texture's average colour and grain, from the textures the game's colour-accurate map
    /// uses (`BlockTypes.Textures`), where readable.
    colour: ?world.Rgb = null,
    grain: []const world.Rgb = &.{},
    /// The colour maps tinting it by climate and season, where it has them and they're readable.
    climateColourMap: ?*const Tint.ColourMap = null,
    seasonColourMap: ?*const Tint.ColourMap = null,
    /// For a block the game draws as a plain cube, its faces' images; null for any other, or
    /// one with a face that can't be read.
    cube: ?world.CubeFaces = null,
};

const Image = world.Image;

/// The format of `blocks.txt` and `textures.bin`, and of what goes into them: raise it when
/// any changes, so sets prepared before are prepared again.
const formatVersion = 6;
const fileName = "blocks.txt";
const imageFileName = "textures.bin";
const colourMapFolder = "colormaps";

/// Blocks the game registers itself rather than from a block type file.
const builtInBlocks = [_][]const u8{ "air", "mantle" };

pub fn deinit(self: *Prepared) void {
    self.arena.deinit();
}

/// Where prepared sets go when no folder is given, relative to the current folder.
pub const defaultFolder = "blocks";

/// The folder name for the set prepared from `assets`: changes with the game version, the
/// mods (their names, sizes and times) and `formatVersion`.
pub fn key(buffer: *[16]u8, io: Io, assets: *const Assets) ![]const u8 {
    var hasher: std.hash.Wyhash = .init(formatVersion);
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
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{hasher.final()}) catch unreachable;
}

/// Replaces what `folder` held. Returns the block count.
pub fn prepare(arena: std.mem.Allocator, io: Io, assets: *const Assets, folder: Dir) !usize {
    const blocks = try BlockTypes.expand(arena, io, assets);
    var textures: Textures = .{ .arena = arena, .io = io, .assets = assets };
    var images: Images = .{ .textures = &textures };
    const colourMaps = try prepareColourMaps(arena, io, assets, folder);
    const numbers = try arena.alloc([4]?usize, blocks.len);
    // Each cube's layers, top, south and east, plain and tinted: their images' numbers, one for
    // each variant.
    const cubes = try arena.alloc(?[6]?[]const usize, blocks.len);
    for (numbers, cubes, blocks) |*number, *layers, block| {
        number.* = .{
            try textures.number(block.textures.colour),
            try textures.number(block.textures.grain),
            colourMapNumber(colourMaps, block.climateColorMap),
            colourMapNumber(colourMaps, block.seasonColorMap),
        };
        layers.* = null;
        const cube = block.cube orelse continue;
        const faces = [_]BlockTypes.Face{ cube.up, cube.south, cube.east };
        var found: [6]?[]const usize = undefined;
        // A cube with a face that can't be read isn't one: it's drawn in its colour instead.
        const whole = for (faces, 0..) |face, i| {
            found[2 * i] = try images.variants(face.plain);
            found[2 * i + 1] = try images.variants(face.tinted);
            if ((face.plain != null and found[2 * i] == null) or (face.tinted != null and found[2 * i + 1] == null)) break false;
        } else true;
        if (whole) layers.* = found;
    }

    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.print("storymap blocks {}\ngame {s}\n", .{ formatVersion, assets.version orelse "" });
    for (assets.sources.items[1..]) |source| try w.print("mod {s}\n", .{source.name});
    for (assets.domains.keys()) |domain| try w.print("domain {s}\n", .{domain});
    for (textures.read.items) |texture| {
        try w.print("texture {s} {X}", .{ texture.location, &texture.colours.average });
        for (texture.colours.grain) |sample| try w.print(" {X}", .{&sample});
        try w.writeByte('\n');
    }
    for (colourMaps) |map| try w.print("colormap {s} {} {}\n", .{ map.code, map.padding, map.extraFlags });
    for (blocks, numbers, cubes) |block, number, cube| {
        try w.print("block {s} {s} {s}", .{ block.code, block.material, block.colorCode });
        for (number) |n| if (n) |i| try w.print(" {}", .{i}) else try w.writeAll(" -");
        const layers: [6]?[]const usize = cube orelse @splat(null);
        for (layers) |layer| {
            const variants = layer orelse {
                try w.writeAll(" -");
                continue;
            };
            for (variants, 0..) |n, i| try w.print("{s}{}", .{ if (i == 0) " " else ",", n });
        }
        try w.writeByte('\n');
    }
    var imageBytes: std.Io.Writer.Allocating = .init(arena);
    for (images.made.items) |image| {
        try imageBytes.writer.writeInt(u16, image.width, .little);
        try imageBytes.writer.writeInt(u16, image.height, .little);
        try imageBytes.writer.writeAll(std.mem.sliceAsBytes(image.pixels));
    }
    // Each is written beside its name first, and `blocks.txt` last, so a set is never left half
    // written.
    const partialImages = imageFileName ++ ".partial";
    try folder.writeFile(io, .{ .sub_path = partialImages, .data = imageBytes.written() });
    try folder.rename(partialImages, folder, imageFileName, io);
    const partial = fileName ++ ".partial";
    try folder.writeFile(io, .{ .sub_path = partial, .data = text.written() });
    try folder.rename(partial, folder, fileName, io);
    return blocks.len;
}

/// Cube faces' images, each made once: a texture with its overlays drawn over it, or half of
/// it, numbered in the order they're first needed.
const Images = struct {
    textures: *Textures,
    /// Each layer met so far, by its textures and half, and its number, or null if it can't be
    /// made.
    numbers: std.StringHashMapUnmanaged(?usize) = .empty,
    made: std.ArrayList(Image) = .empty,

    /// The numbers of the layer's images, one for each variant of its base texture that can be
    /// made, each made the first time; null without a layer or if none can be made.
    fn variants(self: *Images, layer: ?BlockTypes.Layer) !?[]const usize {
        const wanted = layer orelse return null;
        var found: std.ArrayList(usize) = .empty;
        for (try self.textures.paths(wanted.base)) |path| {
            if (try self.number(wanted, path)) |n| try found.append(self.textures.arena, n);
        }
        return if (found.items.len == 0) null else found.items;
    }

    /// The number of the layer's image with `path` as its base, made the first time, or null if
    /// it can't be made.
    fn number(self: *Images, layer: BlockTypes.Layer, path: []const u8) !?usize {
        const arena = self.textures.arena;
        var name: std.Io.Writer.Allocating = .init(arena);
        try name.writer.print("{s}:{s}", .{ domainOf(layer.base), path });
        for (layer.overlays) |overlay| try name.writer.print("+{s}", .{overlay});
        if (layer.half) |half| try name.writer.print("#{t}", .{half});
        const entry = try self.numbers.getOrPut(arena, name.written());
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        const image = try self.make(layer, path) orelse return null;
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

const PreparedColourMap = struct {
    code: []const u8,
    padding: usize,
    /// 1 for a tropical season map.
    extraFlags: u32,
};

/// Copies the images of the colour maps in the game's `config/colormaps.json` into `folder`.
/// Returns those it could read, in the file's order.
fn prepareColourMaps(arena: std.mem.Allocator, io: Io, assets: *const Assets, folder: Dir) ![]const PreparedColourMap {
    const file = "config/colormaps.json";
    const bytes = try assets.read(arena, io, Assets.gameDomain, file) orelse return &.{};
    const json = Json.parse(arena, bytes) catch |err| {
        console.warn("{s}: could not read ({s}); nothing will be tinted", .{ file, @errorName(err) });
        return &.{};
    };
    if (json != .array) return &.{};
    try folder.createDirPath(io, colourMapFolder);
    var maps: std.ArrayList(PreparedColourMap) = .empty;
    for (json.array) |entry| {
        const code = (entry.get("code") orelse continue).asString() orelse continue;
        const base = ((entry.get("texture") orelse continue).get("base") orelse continue).asString() orelse continue;
        const colon = std.mem.indexOfScalar(u8, base, ':');
        const domain = if (colon) |c| base[0..c] else Assets.gameDomain;
        const path = try std.fmt.allocPrint(arena, "textures/{s}.png", .{if (colon) |c| base[c + 1 ..] else base});
        const png = try assets.read(arena, io, domain, path) orelse {
            console.warn("colour map {s}: no image {s}:{s}", .{ code, domain, path });
            continue;
        };
        const sub = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ colourMapFolder, code });
        try folder.writeFile(io, .{ .sub_path = sub, .data = png });
        try maps.append(arena, .{ .code = code, .padding = integer(entry.get("padding")), .extraFlags = @intCast(integer(entry.get("extraFlags"))) });
    }
    return maps.items;
}

/// A whole number in the game's JSON, or 0 without one.
fn integer(value: ?Json.Value) usize {
    const number = value orelse return 0;
    if (number != .number) return 0;
    return std.fmt.parseInt(usize, number.number, 10) catch 0;
}

fn colourMapNumber(maps: []const PreparedColourMap, code: ?[]const u8) ?usize {
    const wanted = code orelse return null;
    for (maps, 0..) |map, i| if (std.mem.eql(u8, map.code, wanted)) return i;
    return null;
}

/// The textures the blocks name, each read once, numbered in the order they're first named.
const Textures = struct {
    arena: std.mem.Allocator,
    io: Io,
    assets: *const Assets,
    /// Each location named so far, and its number, or null if it can't be read.
    numbers: std.StringHashMapUnmanaged(?usize) = .empty,
    read: std.ArrayList(struct { location: []const u8, colours: TextureColours }) = .empty,
    /// Every texture file, listed the first time a location ends in `*`.
    files: ?[]const Assets.Name = null,

    /// Reads the texture the first time; null without a location or if it can't be read.
    fn number(self: *Textures, location: ?[]const u8) !?usize {
        const wanted = location orelse return null;
        const entry = try self.numbers.getOrPut(self.arena, wanted);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        const colours = try self.readColours(wanted) orelse return null;
        try self.read.append(self.arena, .{ .location = wanted, .colours = colours });
        entry.value_ptr.* = self.read.items.len - 1;
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

pub fn exists(io: Io, folder: Dir) bool {
    folder.access(io, fileName, .{}) catch return false;
    return true;
}

pub fn load(allocator: std.mem.Allocator, io: Io, folder: Dir) !Prepared {
    var self: Prepared = .{ .arena = .init(allocator) };
    errdefer self.deinit();
    const arena = self.arena.allocator();
    const text = try folder.readFileAlloc(io, fileName, arena, .limited(256 << 20));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const header = lines.next() orelse return error.NotPreparedBlocks;
    if (!std.mem.eql(u8, header, std.fmt.comptimePrint("storymap blocks {}", .{formatVersion}))) return error.NotPreparedBlocks;
    const images = try loadImages(arena, try folder.readFileAlloc(io, imageFileName, arena, .limited(1 << 30)));
    var textures: std.ArrayList(*const TextureColours) = .empty;
    // Null where a colour map's image can't be read, so the numbers still count.
    var colourMaps: std.ArrayList(?*const Tint.ColourMap) = .empty;
    // The same list of variants, written the same, is one slice, so blocks with the same faces
    // can be told apart by their slices alone.
    var variantLists: std.StringHashMapUnmanaged([]const *const Image) = .empty;
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        const kind = words.next() orelse continue;
        const first = words.next() orelse "";
        if (std.mem.eql(u8, kind, "game")) {
            self.gameVersion = first;
        } else if (std.mem.eql(u8, kind, "mod")) {
            try self.mods.append(arena, first);
        } else if (std.mem.eql(u8, kind, "domain")) {
            try self.domains.put(arena, first, {});
        } else if (std.mem.eql(u8, kind, "texture")) {
            const colours = try arena.create(TextureColours);
            colours.average = try parseRgb(words.next());
            for (&colours.grain) |*sample| sample.* = try parseRgb(words.next());
            try textures.append(arena, colours);
        } else if (std.mem.eql(u8, kind, "colormap")) {
            const padding = std.fmt.parseInt(usize, words.next() orelse "", 10) catch return error.NotPreparedBlocks;
            const flags = std.fmt.parseInt(u32, words.next() orelse "", 10) catch return error.NotPreparedBlocks;
            try colourMaps.append(arena, try loadColourMap(arena, io, folder, first, padding, flags == 1));
        } else if (std.mem.eql(u8, kind, "block")) {
            const material = words.next() orelse return error.NotPreparedBlocks;
            const colorCode = words.next() orelse return error.NotPreparedBlocks;
            const colour = try numbered(*const TextureColours, textures.items, words.next());
            const grain = try numbered(*const TextureColours, textures.items, words.next());
            const climate = try numbered(?*const Tint.ColourMap, colourMaps.items, words.next());
            const season = try numbered(?*const Tint.ColourMap, colourMaps.items, words.next());
            var faces: [3]world.CubeFaces.Face = undefined;
            for (&faces) |*face| face.* = .{
                .plain = try variantsOf(arena, &variantLists, images, words.next()),
                .tinted = try variantsOf(arena, &variantLists, images, words.next()),
            };
            const cube = for (faces) |face| {
                if (face.plain.len == 0 and face.tinted.len == 0) break null;
            } else world.CubeFaces{ .up = faces[0], .south = faces[1], .east = faces[2] };
            try self.blocks.put(arena, first, .{
                .material = material,
                .colorCode = colorCode,
                .colour = if (colour) |texture| texture.average else null,
                .grain = if (grain) |texture| &texture.grain else &.{},
                .climateColourMap = climate orelse null,
                .seasonColourMap = season orelse null,
                .cube = cube,
            });
        }
    }
    return self;
}

/// The images in `textures.bin`, in order, their pixels pointing into `bytes`.
fn loadImages(arena: std.mem.Allocator, bytes: []const u8) ![]const *const Image {
    var images: std.ArrayList(*const Image) = .empty;
    var reader: std.Io.Reader = .fixed(bytes);
    while (reader.bufferedLen() > 0) {
        const image = try arena.create(Image);
        const width = reader.takeInt(u16, .little) catch return error.NotPreparedBlocks;
        const height = reader.takeInt(u16, .little) catch return error.NotPreparedBlocks;
        const pixels = reader.take(@as(usize, width) * height * 4) catch return error.NotPreparedBlocks;
        image.* = .{ .width = width, .height = height, .pixels = std.mem.bytesAsSlice([4]u8, pixels) };
        try images.append(arena, image);
    }
    return images.items;
}

/// Null if the colour map's image can't be read.
fn loadColourMap(arena: std.mem.Allocator, io: Io, folder: Dir, code: []const u8, padding: usize, tropical: bool) !?*const Tint.ColourMap {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}.png", .{ colourMapFolder, code }) catch return null;
    const png = folder.readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const map = try arena.create(Tint.ColourMap);
    map.* = try Tint.ColourMap.decode(arena, code, png, padding, tropical) orelse return null;
    return map;
}

fn parseRgb(word: ?[]const u8) !world.Rgb {
    const hex = word orelse return error.NotPreparedBlocks;
    var rgb: world.Rgb = undefined;
    if (hex.len != 6) return error.NotPreparedBlocks;
    _ = std.fmt.hexToBytes(&rgb, hex) catch return error.NotPreparedBlocks;
    return rgb;
}

/// The images of a layer's variants, numbered and separated by commas, or none for `-`.
fn variantsOf(arena: std.mem.Allocator, lists: *std.StringHashMapUnmanaged([]const *const Image), images: []const *const Image, word: ?[]const u8) ![]const *const Image {
    const text = word orelse return error.NotPreparedBlocks;
    if (std.mem.eql(u8, text, "-")) return &.{};
    const entry = try lists.getOrPut(arena, text);
    if (entry.found_existing) return entry.value_ptr.*;
    var found: std.ArrayList(*const Image) = .empty;
    var numbers = std.mem.splitScalar(u8, text, ',');
    while (numbers.next()) |n| try found.append(arena, (try numbered(*const Image, images, n)) orelse return error.NotPreparedBlocks);
    entry.value_ptr.* = found.items;
    return found.items;
}

/// The texture or colour map a block names by its number, or null for `-`.
fn numbered(comptime T: type, items: []const T, word: ?[]const u8) !?T {
    const n = word orelse return error.NotPreparedBlocks;
    if (std.mem.eql(u8, n, "-")) return null;
    const i = std.fmt.parseInt(usize, n, 10) catch return error.NotPreparedBlocks;
    if (i >= items.len) return error.NotPreparedBlocks;
    return items[i];
}

/// The folder name of the most recently prepared set in `blocks`, or null without any. For
/// when the game isn't there to give the key.
pub fn newest(arena: std.mem.Allocator, io: Io, blocks: Dir) !?[]const u8 {
    var best: ?[]const u8 = null;
    var bestTime: i96 = std.math.minInt(i96);
    var it = blocks.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ entry.name, fileName });
        const stat = blocks.statFile(io, path, .{}) catch continue;
        if (stat.mtime.nanoseconds > bestTime) {
            bestTime = stat.mtime.nanoseconds;
            best = try arena.dupe(u8, entry.name);
        }
    }
    return best;
}

/// What a save's blocks have that the prepared set doesn't: the mods (domains) it lacks, and
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

test "prepare, load and compare with a save" {
    // Keeps the expected warning off stderr, where the build runner would print it.
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
        .{ "data/Mods/testmod.zip", @embedFile("testdata/testmod.zip") },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var game = try tmp.dir.openDir(io, "game", .{});
    defer game.close(io);
    var data = try tmp.dir.openDir(io, "data", .{});
    defer data.close(io);
    var assets = try Assets.open(std.testing.allocator, io, game, data);
    defer assets.close(io);

    var buffer: [16]u8 = undefined;
    const name = try key(&buffer, io, &assets);
    try std.testing.expectEqual(16, name.len);
    try tmp.dir.createDirPath(io, name);
    var folder = try tmp.dir.openDir(io, name, .{});
    defer folder.close(io);
    try std.testing.expect(!exists(io, folder));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // rock-granite, soil, and the test mod's thing.
    try std.testing.expectEqual(3, try prepare(arena.allocator(), io, &assets, folder));
    try std.testing.expect(exists(io, folder));

    var prepared = try load(std.testing.allocator, io, folder);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("1.22.7", prepared.gameVersion);
    try std.testing.expectEqualStrings("testmod.zip", prepared.mods.items[0]);
    try std.testing.expectEqualStrings("Stone", prepared.blocks.get("rock-granite").?.material);
    try std.testing.expectEqualStrings("land", prepared.blocks.get("rock-granite").?.colorCode);
    // The transparent pixel counts for nothing.
    try std.testing.expectEqual(world.Rgb{ 200, 40, 20 }, prepared.blocks.get("rock-granite").?.colour.?);
    try std.testing.expectEqual(TextureColours.samples, prepared.blocks.get("rock-granite").?.grain.len);
    // The colour map's image, 2 × 1; the other one has none, so it isn't there.
    const climate = prepared.blocks.get("rock-granite").?.climateColourMap.?;
    try std.testing.expectEqualStrings("climateTest", climate.code);
    try std.testing.expectEqual(2, climate.width);
    try std.testing.expectEqual(null, prepared.blocks.get("rock-granite").?.seasonColourMap);
    try std.testing.expect(prepared.blocks.contains("testmod:thing"));
    try std.testing.expectEqual(null, prepared.blocks.get("testmod:thing").?.colour);

    // With a colour map, the rock's faces are its whole texture, tinted: granite1 and granite3,
    // its variants that can be read, the same list on every face.
    const rock = prepared.blocks.get("rock-granite").?.cube.?;
    try std.testing.expectEqual(0, rock.up.plain.len);
    try std.testing.expectEqual(2, rock.up.tinted.len);
    try std.testing.expectEqual(2, rock.up.tinted[0].width);
    try std.testing.expect(rock.up.tinted[0] != rock.up.tinted[1]);
    try std.testing.expectEqual(rock.up.tinted.ptr, rock.south.tinted.ptr);
    // The soil's grass is half its second texture, the right on top and the left on the sides.
    const soil = prepared.blocks.get("soil").?.cube.?;
    try std.testing.expectEqual(rock.up.tinted.ptr, soil.up.plain.ptr);
    try std.testing.expectEqual(1, soil.up.tinted[0].width);
    try std.testing.expectEqual(1, soil.south.tinted[0].width);
    try std.testing.expectEqual(soil.south.tinted.ptr, soil.east.tinted.ptr);
    try std.testing.expectEqual(rock.up.tinted[0].pixels[1], soil.up.tinted[0].pixels[0]);
    try std.testing.expectEqual(rock.up.tinted[0].pixels[0], soil.south.tinted[0].pixels[0]);

    const codes = [_]?[]const u8{ "air", "rock-granite", "rock-basalt", null, "testmod:thing", "othermod:x", "othermod:y" };
    const missing = try prepared.unknown(std.testing.allocator, &codes);
    defer std.testing.allocator.free(missing.mods);
    try std.testing.expectEqual(1, missing.mods.len);
    try std.testing.expectEqualStrings("othermod", missing.mods[0]);
    try std.testing.expectEqual(1, missing.codes);
    try std.testing.expectEqualStrings("rock-basalt", missing.example.?);
}
