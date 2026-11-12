//! Minecraft's block states as rendering needs them, prepared once from the client jar into the
//! prepared blocks file (docs/storyblk/spec.md): each with the shapes its sprites are drawn in,
//! and the colour of its top, which a map seen from above shows. Loaded from the file, they're
//! what a render reads a world's blocks as.
const Prepared = @This();

const std = @import("std");
const Io = std.Io;
const world = @import("world");
const storyblk = @import("storyblk");
const stb = @import("stb_image");
const Jar = @import("Jar.zig");
const Blocks = @import("Blocks.zig");
const Models = @import("Models.zig");
const Biomes = @import("Biomes.zig");
const BlockEntities = @import("BlockEntities.zig");
const names = @import("names.zig");
const Tables = storyblk.Tables;
const Image = world.Image;
const Biome = Biomes.Biome;

arena: std.heap.ArenaAllocator,
gameVersion: []const u8,
/// In the order of the `block_states` section.
states: []const BlockState,
/// Each state's index in `states`, by its name.
byName: std.StringHashMapUnmanaged(u32) = .empty,
/// In the order of the `biomes` section.
biomes: []const Biome = &.{},
/// Each biome's index in `biomes`, by its name.
biomeIndexes: std.StringHashMapUnmanaged(u16) = .empty,
/// Each block's properties that its states are named by, in name order, by the block's name,
/// e.g. "minecraft:oak_stairs".
properties: std.StringHashMapUnmanaged([]const Property) = .empty,

/// A block state as a render draws it.
pub const BlockState = struct {
    name: []const u8,
    sprites: world.BlockSprites,
    /// Its top's colour; null where it has none.
    colour: ?world.Rgb,
    mapType: world.MapType,
    liquid: bool,
    seeThrough: bool,
    /// What its tinted faces are multiplied by.
    tint: names.Tint,
    /// How high it reaches, in sixteenths of a block: a liquid's surface where none is above it.
    height: u8,
};

/// A property, and the values a block's states are named with.
pub const Property = struct {
    name: []const u8,
    values: []const []const u8,
    /// One Storymap names states by though the block's blockstate file doesn't, in `{}`.
    added: bool,
};

pub fn deinit(self: *Prepared) void {
    self.arena.deinit();
}

/// The block states in the six sections of `file` (`Tables.read`), each one's sprites checked
/// against `spriteCount`, the `sprites` section's count. Their names are where `file` is, which
/// must outlive the result.
pub fn load(allocator: std.mem.Allocator, file: *const storyblk.File, spriteCount: usize) !Prepared {
    var self: Prepared = .{ .arena = .init(allocator), .gameVersion = file.info.gameVersion, .states = &.{} };
    errdefer self.deinit();
    const arena = self.arena.allocator();
    const tables, var read = try Tables.read(arena, file, spriteCount);
    const states = try arena.alloc(BlockState, read.count);
    try self.byName.ensureTotalCapacity(arena, read.count);
    // Each block's properties, and each property's values, in the order they're first named.
    var named: std.StringArrayHashMapUnmanaged(std.ArrayList(Building)) = .empty;
    while (try read.next()) |state| {
        const short = names.shortName(state.name);
        states[read.index - 1] = .{
            .name = state.name,
            .sprites = .{
                .first = state.firstSprite,
                .variants = state.variants,
                .alternates = state.alternates,
                .turns = state.turns,
                .shape = state.flags.shape,
                .tinted = state.flags.tinted,
                .cover = state.coverSprite,
            },
            .colour = if (state.colour) |i| tables.textureColours[i].average else null,
            .mapType = std.meta.stringToEnum(world.MapType, tables.colourCodes[state.colourCode]) orelse .land,
            .liquid = names.isLiquid(short),
            .seeThrough = state.flags.seeThrough,
            .tint = names.tintOf(short),
            .height = @min(state.height orelse 16, 16),
        };
        self.byName.putAssumeCapacity(state.name, read.index - 1);
        try collectProperties(arena, &named, state.name);
    }
    self.states = states;
    self.biomes = try readBiomes(arena, try file.section(biomesSection, biomesLayoutVersion));
    try self.biomeIndexes.ensureTotalCapacity(arena, @intCast(self.biomes.len));
    for (self.biomes, 0..) |biome, i| self.biomeIndexes.putAssumeCapacity(biome.name, @intCast(i));
    try self.properties.ensureTotalCapacity(arena, @intCast(named.count()));
    for (named.keys(), named.values()) |block, building| {
        const properties = try arena.alloc(Property, building.items.len);
        for (properties, building.items) |*property, built| property.* = .{ .name = built.name, .values = built.values.items, .added = built.added };
        self.properties.putAssumeCapacity(block, properties);
    }
    return self;
}

const Building = struct {
    name: []const u8,
    added: bool,
    values: std.ArrayList([]const u8) = .empty,
};

/// Adds the block, properties and values a state's name names to `named`: those of its
/// blockstate file in `[]`, then those Storymap adds in `{}`, e.g.
/// `minecraft:oak_stairs[facing=east,half=bottom]` and `minecraft:water{level=0}`.
fn collectProperties(arena: std.mem.Allocator, named: *std.StringArrayHashMapUnmanaged(std.ArrayList(Building)), name: []const u8) !void {
    const block = names.blockOf(name);
    const entry = try named.getOrPut(arena, block);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    var rest = name[block.len..];
    for ([_][2]u8{ "[]".*, "{}".* }, [_]bool{ false, true }) |brackets, added| {
        if (rest.len == 0 or rest[0] != brackets[0]) continue;
        const end = std.mem.indexOfScalar(u8, rest, brackets[1]) orelse return;
        var pairs = std.mem.splitScalar(u8, rest[1..end], ',');
        rest = rest[end + 1 ..];
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..equals];
            const value = pair[equals + 1 ..];
            const property = for (entry.value_ptr.items) |*property| {
                if (property.added == added and std.mem.eql(u8, property.name, key)) break property;
            } else add: {
                try entry.value_ptr.append(arena, .{ .name = key, .added = added });
                break :add &entry.value_ptr.items[entry.value_ptr.items.len - 1];
            };
            for (property.values.items) |known| {
                if (std.mem.eql(u8, known, value)) break;
            } else try property.values.append(arena, value);
        }
    }
}

/// The index of the state that block `block` with `given` properties is drawn as: its name with
/// only the properties its states are named by, those of its blockstate file in `[]` and those
/// Storymap adds in `{}`, a value they don't name as empty (`BlockStates`). Null for a block the
/// file doesn't have.
pub fn find(self: *const Prepared, block: []const u8, given: anytype) ?u32 {
    const properties = self.properties.get(block) orelse return null;
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    w.writeAll(block) catch return null;
    for ([_][2]u8{ "[]".*, "{}".* }, [_]bool{ false, true }) |brackets, added| {
        var any = false;
        for (properties) |property| {
            if (property.added != added) continue;
            const value = given.get(property.name) orelse "";
            const known = for (property.values) |named| {
                if (std.mem.eql(u8, named, value)) break value;
            } else "";
            w.print("{c}{s}={s}", .{ @as(u8, if (any) ',' else brackets[0]), property.name, known }) catch return null;
            any = true;
        }
        if (any) w.writeByte(brackets[1]) catch return null;
    }
    return self.byName.get(w.buffered());
}

/// The game, as the file's `info` and `--game` name it.
pub const game = "minecraft";

/// Where the prepared blocks file goes when no path is given, relative to the current folder.
pub const defaultPath = game ++ ".storyblk";

/// How the seven sections' contents are read from the jar: raise it when that changes, so files
/// prepared before are prepared again.
pub const generatorVersion: u16 = 5;

/// The section only Minecraft's files have: its biomes' colours (spec §3).
const biomesSection = "biomes";
const biomesLayoutVersion: u8 = 1;
/// The bytes of a Biome with an empty name.
const biomeLength = 2 + 3 * 3;

fn writeBiomes(arena: std.mem.Allocator, biomes: []const Biome) !storyblk.Section {
    if (biomes.len > std.math.maxInt(u16)) return error.TooManyBiomes;
    var bytes: Io.Writer.Allocating = .init(arena);
    const w = &bytes.writer;
    try w.writeInt(u16, @intCast(biomes.len), .little);
    for (biomes) |biome| {
        try storyblk.writeString(w, biome.name);
        try w.writeAll(&biome.grass);
        try w.writeAll(&biome.foliage);
        try w.writeAll(&biome.water);
    }
    return .{ .name = biomesSection, .layoutVersion = biomesLayoutVersion, .generatorVersion = generatorVersion, .bytes = bytes.written() };
}

/// The `biomes` section's biomes, kept in `arena`, their names where the file is.
fn readBiomes(arena: std.mem.Allocator, section: storyblk.Section) ![]const Biome {
    var r: storyblk.Reader = .{ .bytes = section.bytes };
    const count = try r.int(u16);
    if (count > section.bytes.len / biomeLength) return error.NotPreparedBlocks;
    const biomes = try arena.alloc(Biome, count);
    for (biomes) |*biome| biome.* = .{
        .name = try r.string(),
        .grass = (try r.take(3))[0..3].*,
        .foliage = (try r.take(3))[0..3].*,
        .water = (try r.take(3))[0..3].*,
    };
    return biomes;
}

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
    std.hash.autoHash(&hasher, biomesLayoutVersion);
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

/// The seven sections' contents before they're written, with what drawing the sprites needs.
pub const Contents = struct {
    /// The sections `encode` makes.
    pub const sectionCount = Tables.names.len + 1;

    gameVersion: []const u8,
    states: []State,
    textures: []const Tables.TextureColours,
    /// The map types the states are, by name (`world.MapType`), each once.
    colourCodes: []const []const u8,
    biomes: []const Biome,

    pub const State = struct {
        name: []const u8,
        /// The shapes it picks one of by where it is; none for a state its models don't draw.
        shapes: []const world.Shape,
        /// A liquid's faces, drawn as a cube, which the game draws without a model.
        cube: ?world.CubeFaces = null,
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

    /// The six sections in the order of `Tables.names`, then `biomes`, their bytes kept in
    /// `arena`.
    pub fn encode(self: *const Contents, arena: std.mem.Allocator) ![sectionCount]storyblk.Section {
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
        return (try encoder.finish(arena, generatorVersion)) ++ [1]storyblk.Section{try writeBiomes(arena, self.biomes)};
    }
};

/// Reads every block state in `jar`, with its textures, keeping them in `arena`. What couldn't
/// be read is left out, and named in `problems`.
pub fn prepare(arena: std.mem.Allocator, io: Io, jar: *const Jar, problems: *Blocks.Problems) !Contents {
    const blocks = try Blocks.read(arena, io, jar, problems);
    var textures: Textures = .{ .arena = arena, .io = io, .jar = jar };
    var colourCodes: std.StringArrayHashMapUnmanaged(void) = .empty;
    var states: std.ArrayList(Contents.State) = .empty;
    for (blocks.states) |read| {
        const short = names.shortName(read.name);
        // A block the game draws in code has a state for each shape that draws it.
        if (try BlockEntities.statesOf(arena, short)) |drawn| {
            for (drawn) |entity| {
                const name = try std.fmt.allocPrint(arena, "{s}{{{s}}}", .{ read.name, entity.properties });
                try states.append(arena, try stateOf(arena, &textures, &colourCodes, name, &.{entity.shape}));
            }
            continue;
        }
        var state = try stateOf(arena, &textures, &colourCodes, read.name, read.alternates);
        if (!names.isLiquid(short)) {
            try states.append(arena, state);
            continue;
        }
        const kind = if (names.isWater(short)) "water" else "lava";
        const still = try std.fmt.allocPrint(arena, "minecraft:block/{s}_still", .{kind});
        const flow = try std.fmt.allocPrint(arena, "minecraft:block/{s}_flow", .{kind});
        if (try textures.get(still)) |top| {
            const side = try textures.get(flow) orelse top;
            const tinted = names.isWater(short);
            const layer = struct {
                fn of(texture: *const Textures.Texture, isTinted: bool) world.CubeFaces.Face {
                    return if (isTinted) .{ .tinted = texture.layer } else .{ .plain = texture.layer };
                }
            }.of;
            const sideFace = layer(side, tinted);
            state.cube = .{ .up = layer(top, tinted), .south = sideFace, .east = sideFace, .north = sideFace, .west = sideFace };
            state.seeThrough = top.seeThrough;
            state.colour = try textures.colours(still);
        }
        state.height = names.liquidHeight(0);
        if (!names.hasLevels(short)) {
            try states.append(arena, state);
            continue;
        }
        // A state for each level, which the game draws at its own height though its blockstate
        // file doesn't name it, then one for a falling liquid's.
        for (names.levels, 0..) |level, i| {
            state.name = try std.fmt.allocPrint(arena, "{s}{{level={s}}}", .{ read.name, level });
            state.height = names.liquidHeight(i);
            try states.append(arena, state);
        }
        state.name = try std.fmt.allocPrint(arena, "{s}{{level=}}", .{read.name});
        state.height = names.liquidHeight(null);
        try states.append(arena, state);
    }
    const grassMap = if (try textures.get("minecraft:colormap/grass")) |texture| texture.layer[0] else null;
    const foliageMap = if (try textures.get("minecraft:colormap/foliage")) |texture| texture.layer[0] else null;
    return .{
        .gameVersion = jar.version,
        .states = states.items,
        .textures = textures.read.items,
        .colourCodes = colourCodes.keys(),
        .biomes = try Biomes.read(arena, io, jar, grassMap, foliageMap, &problems.biomes),
    };
}

/// The state `name` drawn in `alternates`, each with its textures read, its colour its first
/// shape's top's, and its map type its name's.
fn stateOf(arena: std.mem.Allocator, textures: *Textures, colourCodes: *std.StringArrayHashMapUnmanaged(void), name: []const u8, alternates: []const Models.Shape) !Contents.State {
    var seeThrough = false;
    var shapes: std.ArrayList(world.Shape) = .empty;
    for (alternates) |alternate| {
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
    const first = if (alternates.len > 0) alternates[0] else Models.Shape{ .boxes = &.{}, .textures = &.{} };
    const code = try colourCodes.getOrPut(arena, @tagName(names.mapTypeOf(names.shortName(name))));
    const sixteenths = @round(first.height * 16);
    return .{
        .name = name,
        .shapes = shapes.items,
        .colour = if (first.top) |top| try textures.colours(first.textures[top].name) else null,
        .colourCode = @intCast(code.index),
        .height = if (sixteenths >= 16 or shapes.items.len == 0) null else @intFromFloat(@max(sixteenths, 0)),
        .seeThrough = seeThrough,
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

test find {
    var self: Prepared = .{ .arena = .init(std.testing.allocator), .gameVersion = "", .states = &.{} };
    defer self.deinit();
    const arena = self.arena.allocator();
    const stateNames = [_][]const u8{
        "minecraft:stone",
        "minecraft:oak_stairs[facing=east,half=bottom]",
        "minecraft:oak_stairs[facing=west,half=bottom]",
        "minecraft:wall[east=low,up=true]",
        "minecraft:wall[east=,up=true]",
        "minecraft:water{level=0}",
        "minecraft:water{level=}",
        "minecraft:pipe[axis=x]{level=1}",
    };
    var named: std.StringArrayHashMapUnmanaged(std.ArrayList(Building)) = .empty;
    for (stateNames, 0..) |name, i| {
        try self.byName.put(arena, name, @intCast(i));
        try collectProperties(arena, &named, name);
    }
    for (named.keys(), named.values()) |block, building| {
        const properties = try arena.alloc(Property, building.items.len);
        for (properties, building.items) |*property, built| property.* = .{ .name = built.name, .values = built.values.items, .added = built.added };
        try self.properties.put(arena, block, properties);
    }
    const Given = struct {
        pairs: []const [2][]const u8,
        fn get(given: @This(), name: []const u8) ?[]const u8 {
            for (given.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
            return null;
        }
    };
    try std.testing.expectEqual(0, self.find("minecraft:stone", Given{ .pairs = &.{} }));
    // A save's other properties are left out.
    try std.testing.expectEqual(2, self.find("minecraft:oak_stairs", Given{ .pairs = &.{ .{ "waterlogged", "false" }, .{ "half", "bottom" }, .{ "facing", "west" }, .{ "shape", "straight" } } }));
    // A value the states don't name is the empty one.
    try std.testing.expectEqual(4, self.find("minecraft:wall", Given{ .pairs = &.{ .{ "east", "none" }, .{ "up", "true" } } }));
    try std.testing.expectEqual(null, self.find("minecraft:dirt", Given{ .pairs = &.{} }));
    // Properties Storymap adds are in `{}`, after the file's in `[]`.
    try std.testing.expectEqual(5, self.find("minecraft:water", Given{ .pairs = &.{.{ "level", "0" }} }));
    try std.testing.expectEqual(6, self.find("minecraft:water", Given{ .pairs = &.{.{ "level", "12" }} }));
    try std.testing.expectEqual(7, self.find("minecraft:pipe", Given{ .pairs = &.{ .{ "level", "1" }, .{ "axis", "x" } } }));
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
