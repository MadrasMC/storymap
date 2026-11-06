//! Minecraft's block states as rendering needs them, prepared once from the client jar into the
//! prepared blocks file (docs/storyblk/spec.md): each with the shapes its sprites are drawn in,
//! and the colour of its top, which a map seen from above shows.
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const storyblk = @import("storyblk");
const stb = @import("stb_image");
const Jar = @import("Jar.zig");
const Blocks = @import("Blocks.zig");
const Models = @import("Models.zig");
const names = @import("names.zig");
const Tables = storyblk.Tables;
const Image = world.Image;

/// The game, as the file's `info` and `--game` name it.
pub const game = "minecraft";

/// Where the prepared blocks file goes when no path is given, relative to the current folder.
pub const defaultPath = game ++ ".storyblk";

/// How the six sections' contents are read from the jar: raise it when that changes, so files
/// prepared before are prepared again.
pub const generatorVersion: u16 = 1;

/// The only domain: the game's assets are all in `minecraft`.
const domains = [_][]const u8{game};
/// The game has no materials, so every block state is of one, named "".
const materials = [_][]const u8{""};

/// The file's `header.hash` for blocks prepared from `jar`, with sprites drawn as `sprites` says
/// (spec §6): it changes with the container's and the sections' versions, the block width, the
/// game version and the jar's size and time.
pub fn hash(io: Io, jar: *const Jar, sprites: storyblk.SpriteFormat) !u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, storyblk.version);
    std.hash.autoHash(&hasher, Tables.layoutVersions);
    std.hash.autoHash(&hasher, generatorVersion);
    std.hash.autoHash(&hasher, sprites);
    hasher.update(game);
    hasher.update(&.{0});
    hasher.update(jar.version);
    const stat = try jar.file.stat(io);
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    return hasher.final();
}

/// The six sections' contents before they're written, with what drawing the sprites needs.
pub const Contents = struct {
    gameVersion: []const u8,
    states: []State,
    textures: []const Tables.TextureColours,
    /// The map types the states are, by name (`world.MapType`), each once.
    colourCodes: []const []const u8,

    pub const State = struct {
        name: []const u8,
        /// The shapes it picks one of by where it is; none for a state its models don't draw.
        shapes: []const world.Shape,
        /// Its top's colours in `textures`.
        colour: ?u32,
        colourCode: u8,
        /// How high it reaches, in sixteenths of a block; null for the whole block.
        height: ?u8,
        /// Any of its textures is partly see-through, as glass and ice are.
        seeThrough: bool,
        sprites: world.BlockSprites = .{},
    };

    /// Gives each state its sprites, by its index.
    pub fn useSprites(self: *Contents, sprites: []const world.BlockSprites) void {
        std.debug.assert(sprites.len == self.states.len);
        for (self.states, sprites) |*state, own| state.sprites = own;
    }

    /// The file's `info`, kept in `arena`, so it can outlast these contents.
    pub fn info(self: *const Contents, arena: std.mem.Allocator) !storyblk.Info {
        return .{ .game = game, .gameVersion = try arena.dupe(u8, self.gameVersion), .mods = &.{} };
    }

    /// The six sections, in the order of `Tables.names`, their bytes kept in `arena`.
    pub fn encode(self: *const Contents, arena: std.mem.Allocator) ![Tables.names.len]storyblk.Section {
        var encoder: Tables.Encoder = try .init(arena, .{
            .materials = &materials,
            .colourCodes = self.colourCodes,
            .textureColours = self.textures,
            .colourMaps = &.{},
            .domains = &domains,
        }, self.states.len);
        for (self.states) |state| try encoder.add(.{
            .name = state.name,
            .material = 0,
            .colourCode = state.colourCode,
            .colour = state.colour,
            .height = state.height,
            .flags = .{ .shape = state.sprites.shape, .tinted = state.sprites.tinted, .seeThrough = state.seeThrough },
            .firstSprite = state.sprites.first,
            .variants = state.sprites.variants,
            .alternates = state.sprites.alternates,
            .turns = state.sprites.turns,
            .coverSprite = state.sprites.cover,
        });
        return encoder.finish(arena, generatorVersion);
    }
};

/// Reads every block state in `jar`, with its textures, keeping them in `arena`. What couldn't
/// be read is left out, and named in `problems`.
pub fn prepare(arena: std.mem.Allocator, io: Io, jar: *const Jar, problems: *Blocks.Problems) !Contents {
    const blocks = try Blocks.read(arena, io, jar, problems);
    var textures: Textures = .{ .arena = arena, .io = io, .jar = jar };
    var colourCodes: std.StringArrayHashMapUnmanaged(void) = .empty;
    const states = try arena.alloc(Contents.State, blocks.states.len);
    for (states, blocks.states) |*state, read| {
        var seeThrough = false;
        var shapes: std.ArrayList(world.Shape) = .empty;
        for (read.alternates) |alternate| {
            if (alternate.boxes.len == 0) continue;
            const faces = try arena.alloc(world.CubeFaces.Face, alternate.textures.len);
            for (faces, alternate.textures) |*face, texture| {
                const found = try textures.get(texture.name) orelse {
                    face.* = .{};
                    continue;
                };
                seeThrough = seeThrough or found.seeThrough;
                face.* = if (texture.tinted) .{ .tinted = found.layer } else .{ .plain = found.layer };
            }
            try shapes.append(arena, .{ .boxes = alternate.boxes, .textures = faces });
        }
        const first = if (read.alternates.len > 0) read.alternates[0] else Models.Shape{ .boxes = &.{}, .textures = &.{} };
        const colour = if (first.top) |top| try textures.colours(first.textures[top].name) else null;
        const mapType = names.mapTypeOf(names.shortName(read.name));
        const code = try colourCodes.getOrPut(arena, @tagName(mapType));
        const sixteenths = @round(first.height * 16);
        state.* = .{
            .name = read.name,
            .shapes = shapes.items,
            .colour = colour,
            .colourCode = @intCast(code.index),
            .height = if (sixteenths >= 16 or shapes.items.len == 0) null else @intFromFloat(@max(sixteenths, 0)),
            .seeThrough = seeThrough,
        };
    }
    return .{
        .gameVersion = jar.version,
        .states = states,
        .textures = textures.read.items,
        .colourCodes = colourCodes.keys(),
    };
}

/// The textures the block states name, each read once.
const Textures = struct {
    arena: std.mem.Allocator,
    io: Io,
    jar: *const Jar,
    /// By name, e.g. "minecraft:block/stone"; null for one that can't be read.
    loaded: std.StringHashMapUnmanaged(?Texture) = .empty,
    /// The colours of the textures a state's top shows, in the order first needed.
    read: std.ArrayList(Tables.TextureColours) = .empty,

    const Texture = struct {
        /// The texture as a face's one layer.
        layer: []const *const Image,
        seeThrough: bool,
        /// Its index in `read`, once a top shows it.
        colours: ?u32 = null,
    };

    fn get(self: *Textures, name: []const u8) !?*Texture {
        const entry = try self.loaded.getOrPut(self.arena, name);
        if (!entry.found_existing) entry.value_ptr.* = try self.load(name);
        return if (entry.value_ptr.*) |*texture| texture else null;
    }

    fn load(self: *Textures, name: []const u8) !?Texture {
        const colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
        if (!std.mem.eql(u8, name[0..colon], game)) return null;
        const path = try std.fmt.allocPrint(self.arena, "textures/{s}.png", .{name[colon + 1 ..]});
        const png = try self.jar.read(self.arena, self.io, path) orelse return null;
        const image = try decode(self.arena, png) orelse return null;
        const layer = try self.arena.alloc(*const Image, 1);
        layer[0] = image;
        return .{ .layer = layer, .seeThrough = isSeeThrough(image.pixels) };
    }

    /// The index in `read` of texture `name`'s colours; null if it can't be read.
    fn colours(self: *Textures, name: []const u8) !?u32 {
        const texture = try self.get(name) orelse return null;
        if (texture.colours == null) {
            try self.read.append(self.arena, averageOf(texture.layer[0].pixels) orelse return null);
            texture.colours = @intCast(self.read.items.len - 1);
        }
        return texture.colours;
    }
};

/// A PNG's pixels, kept in `arena`; an animated texture's frames are stacked one under another,
/// and only the first is kept. Null for one that can't be decoded.
fn decode(arena: std.mem.Allocator, png: []const u8) !?*const Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = stb.stbi_load_from_memory(png.ptr, @intCast(png.len), &width, &height, &channels, 4) orelse return null;
    defer stb.stbi_image_free(data);
    if (width <= 0 or height <= 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return null;
    const shown: usize = if (height > width and @rem(height, width) == 0) @intCast(width) else @intCast(height);
    const count = @as(usize, @intCast(width)) * shown;
    const pixels = try arena.dupe([4]u8, @as([*]const [4]u8, @ptrCast(data))[0..count]);
    const image = try arena.create(Image);
    image.* = .{ .width = @intCast(width), .height = @intCast(shown), .pixels = pixels };
    return image;
}

/// Whether any pixel is partly see-through: glass and ice, whose pixels show what's behind them,
/// rather than leaves and plants, whose pixels are there or not.
fn isSeeThrough(pixels: []const [4]u8) bool {
    for (pixels) |pixel| if (pixel[3] > 0 and pixel[3] < 255) return true;
    return false;
}

/// The colour of `pixels`, weighing each by its opacity, as grain too; null if all are
/// transparent.
fn averageOf(pixels: []const [4]u8) ?Tables.TextureColours {
    var sums: [3]u64 = @splat(0);
    var weight: u64 = 0;
    for (pixels) |pixel| {
        for (&sums, pixel[0..3]) |*sum, channel| sum.* += @as(u64, channel) * pixel[3];
        weight += pixel[3];
    }
    if (weight == 0) return null;
    var average: [3]u8 = undefined;
    for (&average, sums) |*channel, sum| channel.* = @intCast((sum + weight / 2) / weight);
    return .{ .average = average, .grain = @splat(average) };
}

test averageOf {
    const colours = averageOf(&.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 0 } }).?;
    try std.testing.expectEqual([3]u8{ 128, 0, 128 }, colours.average);
    try std.testing.expectEqual(null, averageOf(&.{.{ 9, 9, 9, 0 }}));
}

test isSeeThrough {
    try std.testing.expect(!isSeeThrough(&.{ .{ 0, 0, 0, 0 }, .{ 1, 2, 3, 255 } }));
    try std.testing.expect(isSeeThrough(&.{.{ 1, 2, 3, 128 }}));
}
