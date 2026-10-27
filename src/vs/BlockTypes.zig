//! The block types in the game's and mods' `blocktypes/`, expanded into one code per variant as
//! the game does it (docs/rendering.md#block-codes).
const std = @import("std");
const Io = std.Io;
const console = @import("console");
const world = @import("world");
const Assets = @import("Assets.zig");
const Json = @import("Json.zig");
const Wildcard = @import("Wildcard.zig");

pub const Block = struct {
    /// As a save names it: "rock-granite" in the game's domain, "primitivesurvival:…" in a mod's.
    code: []const u8,
    /// One of `materials`, e.g. "Stone".
    material: []const u8,
    /// The game's map palette colour, e.g. "land" or "forest": its `mapColorCode` attribute,
    /// else its material's default (docs/rendering.md#block-colours).
    colorCode: []const u8,
    textures: Textures,
    /// The colour maps tinting it by climate and by season, by their codes in
    /// `config/colormaps.json`, e.g. "climatePlantTint" and "seasonalGrass".
    climateColorMap: ?[]const u8 = null,
    seasonColorMap: ?[]const u8 = null,
    /// For a block the game draws as a plain cube, the textures on the faces the isometric view
    /// shows; null for any other.
    cube: ?Cube = null,
    /// For a block the game draws in a shape other than the plain cube, the shapes it picks one
    /// of for each block, by where it is (`Shapes.resolve`), the first its own; empty for any
    /// other, or one whose shapes can't be read.
    shapes: []const Shape = &.{},
    /// How high its selection box reaches, the part of it a player can point at, in sixteenths of
    /// a block; null where its block type gives none, which is the whole block.
    height: ?u8 = null,
    /// How it's moved off the middle of its place, by where it is (`randomDrawOffset`): 0 not at
    /// all; the larger, the less.
    drawOffset: u8 = 0,
    /// Which of its position's coordinates pick its variants and offset (`randomizeAxes`): all,
    /// or only x and z, so a column of it is the same all the way up.
    randomizeAxes: Axes = .xyz,
    /// Whether it's turned about its vertical middle by where it is (`randomizeRotations`).
    randomizeRotations: bool = false,
};

pub const Axes = enum { xyz, xz };

/// A cube's top, south and east faces: those seen looking north-west from above.
pub const Cube = struct {
    up: Face,
    south: Face,
    east: Face,
};

/// A block's shape as the game draws it: its boxes, and its textures for them.
pub const Shape = struct {
    /// Shared by every block whose shape is the same file placed the same way.
    geometry: *const Geometry,
    /// By `Geometry.textures`: this block's texture for each, tinted where the block or the
    /// element is, or neither layer where it has none.
    textures: []const Face,

    /// A shape with nothing to draw, which a block may still pick.
    pub const empty: Shape = .{ .geometry = &.{ .boxes = &.{}, .textures = &.{} }, .textures = &.{} };
};

/// A shape file's elements, placed in the block as a block type's `shape` places them
/// (`world.Shape`), each face naming its texture.
pub const Geometry = struct {
    boxes: []const Box,
    /// The textures the faces name, each once.
    textures: []const TextureName,
    /// The colour maps the first element naming them names, for a block type that names none.
    climateColorMap: ?[]const u8 = null,
    seasonColorMap: ?[]const u8 = null,

    pub const Box = struct {
        transform: [3][4]f32,
        size: [3]f32,
        shade: bool,
        /// By `world.Shape.Side`.
        faces: [6]?BoxFace,
    };

    pub const BoxFace = struct {
        /// In `Geometry.textures`.
        texture: u16,
        /// At each corner, in `world.Shape.Side.corners` order.
        uv: [4][2]f32,
    };

    pub const TextureName = struct {
        /// As a face names it, without its `#`.
        code: []const u8,
        /// The shape file's own texture of that name, as "domain:path", for a block type
        /// without one.
        own: ?[]const u8,
        /// Whether its element names colour maps, tinting it whatever the block type says.
        tinted: bool,
    };
};

/// One face of a cube: what's never tinted, and what the block's colour maps tint, drawn over
/// it. Grassy soil has both, the soil and its grass; other blocks one or the other.
pub const Face = struct {
    plain: ?Layer = null,
    tinted: ?Layer = null,
};

/// A texture and the overlays drawn over it, each as "domain:path" below `textures/` without
/// ".png", the path ending in `*` for the first of its variants.
pub const Layer = struct {
    base: []const u8,
    overlays: []const []const u8 = &.{},
    /// For grassy soil's grass: the half of a texture twice as wide as tall that this face takes,
    /// the left for the sides and the right for the top.
    half: ?Half = null,

    pub const Half = enum { left, right };
};

/// The textures that colour a block on the game's colour-accurate map (vsapi
/// `Block.LoadTextureSubIdForBlockColor` and `Block.GetRandomColor`), as "domain:path" below
/// `textures/` without ".png". A path ending in `*` stands for every file it starts.
pub const Textures = struct {
    /// Average colour: the `textureCodeForBlockColor` texture, else `up`, else the first.
    colour: ?[]const u8 = null,
    /// Grain: the `particlesTextureCode` texture, else `up`, else the first.
    grain: ?[]const u8 = null,
};

/// The game's block materials (vsapi `EnumBlockMaterial`).
pub const materials = [_][]const u8{
    "Air",   "Soil",   "Gravel", "Sand",  "Wood",    "Leaves", "Stone", "Ore",   "Water", "Snow", "Ice",
    "Metal", "Mantle", "Plant",  "Glass", "Ceramic", "Cloth",  "Lava",  "Brick", "Fire",  "Meta", "Other",
};

/// A block without a material is stone (vsapi `Block.BlockMaterial`).
const defaultMaterial = "Stone";

/// A material's map colour code, for blocks without `mapColorCode`
/// (vsessentialsmod `ChunkMapLayer.defaultMapColorCodes`).
fn defaultColorCode(material: []const u8) []const u8 {
    const defaults = [_][2][]const u8{
        .{ "Soil", "land" },    .{ "Sand", "desert" },   .{ "Ore", "land" },    .{ "Gravel", "desert" },
        .{ "Stone", "land" },   .{ "Leaves", "forest" }, .{ "Plant", "plant" }, .{ "Wood", "forest" },
        .{ "Snow", "glacier" }, .{ "Water", "lake" },    .{ "Ice", "glacier" }, .{ "Lava", "lava" },
    };
    for (defaults) |pair| if (std.mem.eql(u8, pair[0], material)) return pair[1];
    return "land";
}

const Variant = struct {
    code: Location,
    parts: []const Part,
};

/// A code or a world property's name, with its domain, both lowercase.
const Location = struct {
    domain: []const u8,
    path: []const u8,

    /// "domain:path", or a path in `domain`; lowercased, as the game does.
    fn parse(arena: std.mem.Allocator, text: []const u8, domain: []const u8) !Location {
        const lower = try std.ascii.allocLowerString(arena, text);
        if (std.mem.indexOfScalar(u8, lower, ':')) |colon| return .{ .domain = lower[0..colon], .path = lower[colon + 1 ..] };
        return .{ .domain = domain, .path = lower };
    }

    fn eql(a: Location, b: Location) bool {
        return std.mem.eql(u8, a.domain, b.domain) and std.mem.eql(u8, a.path, b.path);
    }

    /// `self` may be a wildcard. A domain of `*` matches any.
    fn matches(self: Location, code: Location) !bool {
        if (!Wildcard.isWildcard(self.path)) return self.eql(code);
        if (!std.mem.eql(u8, self.domain, "*") and !std.mem.eql(u8, self.domain, code.domain)) return false;
        return Wildcard.match(self.path, code.path);
    }
};

const Part = struct {
    group: []const u8,
    state: []const u8,
};

/// Every block `assets` defines, each code once, in file order. A block type that can't be
/// read is skipped with a warning, as in the game.
pub fn expand(arena: std.mem.Allocator, io: Io, assets: *const Assets) ![]const Block {
    var expander: Expander = .{ .arena = arena, .io = io, .assets = assets };
    try expander.loadWorldProperties();
    var shapes: Shapes = .{ .arena = arena, .io = io, .assets = assets };

    var blocks: std.ArrayList(Block) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try assets.list(arena, io, "blocktypes")) |name| {
        if (!std.mem.endsWith(u8, name.path, ".json")) continue;
        const blockType = expander.blockType(name) catch |err| {
            console.warn("skipped block type {s}:{s}: could not read ({s})", .{ name.domain, name.path, @errorName(err) });
            continue;
        };
        var warned = false;
        for (blockType.variants) |variant| {
            const code = variant.code;
            const saved = if (std.mem.eql(u8, code.domain, Assets.gameDomain))
                code.path
            else
                try std.fmt.allocPrint(arena, "{s}:{s}", .{ code.domain, code.path });
            const entry = try seen.getOrPut(arena, saved);
            if (entry.found_existing) continue;
            const look = describe(arena, blockType.json, variant, &shapes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => look: {
                    // As in the game, a variant whose …ByType properties can't be resolved
                    // keeps the defaults.
                    if (!warned) console.warn("{s}:{s}: could not resolve its …ByType properties ({s})", .{ name.domain, name.path, @errorName(err) });
                    warned = true;
                    break :look Look{ .material = defaultMaterial, .colorCode = defaultColorCode(defaultMaterial), .textures = .{} };
                },
            };
            try blocks.append(arena, .{
                .code = saved,
                .material = look.material,
                .colorCode = look.colorCode,
                .textures = look.textures,
                .climateColorMap = look.climateColorMap,
                .seasonColorMap = look.seasonColorMap,
                .cube = look.cube,
                .shapes = look.shapes,
                .height = look.height,
                .drawOffset = look.drawOffset,
                .randomizeAxes = look.randomizeAxes,
                .randomizeRotations = look.randomizeRotations,
            });
        }
    }
    return blocks.items;
}

const Look = struct {
    material: []const u8,
    colorCode: []const u8,
    textures: Textures,
    climateColorMap: ?[]const u8 = null,
    seasonColorMap: ?[]const u8 = null,
    cube: ?Cube = null,
    shapes: []const Shape = &.{},
    height: ?u8 = null,
    drawOffset: u8 = 0,
    randomizeAxes: Axes = .xyz,
    randomizeRotations: bool = false,
};

/// A variant's `Look`, from its block type's properties with their `…ByType` forms resolved.
fn describe(arena: std.mem.Allocator, json: Json.Value, variant: Variant, shapes: *Shapes) !Look {
    const materialValue = try property(arena, json, "blockmaterial", variant);
    const material = canonicalMaterial(if (materialValue) |m| m.asString() orelse defaultMaterial else defaultMaterial);
    const attributes = try property(arena, json, "attributes", variant);
    const colorCode = if (attributes) |a| if (a.get("mapColorCode")) |c| c.asString() else null else null;
    // A …ByType may set one to null, for variants without.
    var climateColorMap = if (try property(arena, json, "climateColorMap", variant)) |c| c.asString() else null;
    var seasonColorMap = if (try property(arena, json, "seasonColorMap", variant)) |c| c.asString() else null;
    const drawing = try drawingOf(arena, json, variant, shapes);
    // Leaves whose shape names colour maps on its elements, rather than the block type, are
    // tinted by its cube's.
    if (drawing == .distantCube) {
        climateColorMap = climateColorMap orelse drawing.distantCube.climateColorMap;
        seasonColorMap = seasonColorMap orelse drawing.distantCube.seasonColorMap;
    }

    const tinted = climateColorMap != null or seasonColorMap != null;
    const all: []const Json.Field = if (try property(arena, json, "textures", variant)) |t| (if (t == .object) t.object else &.{}) else &.{};
    var textures: Textures = .{};
    var cube: ?Cube = null;
    if (all.len > 0) {
        const forColour = if (attributes) |a| if (a.get("textureCodeForBlockColor")) |c| c.asString() else null else null;
        const forGrain = if (try property(arena, json, "particlesTextureCode", variant)) |c| c.asString() else null;
        textures = .{
            .colour = try textureLocation(arena, pickTexture(all, forColour), variant.code.domain),
            .grain = try textureLocation(arena, pickTexture(all, forGrain), variant.code.domain),
        };
        cube = try cubeOf(arena, all, drawing, tinted, variant.code.domain);
    }
    const shaped: []const Shape = if (drawing == .shaped) try shapes.alternatesOf(drawing.shaped, all, tinted, variant.code.domain) else &.{};
    for (shaped) |shape| if (shape.geometry.climateColorMap != null or shape.geometry.seasonColorMap != null) {
        climateColorMap = climateColorMap orelse shape.geometry.climateColorMap;
        seasonColorMap = seasonColorMap orelse shape.geometry.seasonColorMap;
        break;
    };
    return .{
        .material = material,
        .colorCode = colorCode orelse defaultColorCode(material),
        .textures = textures,
        .climateColorMap = climateColorMap,
        .seasonColorMap = seasonColorMap,
        .cube = cube,
        .shapes = shaped,
        .height = try heightOf(arena, json, variant),
        .drawOffset = try drawOffsetOf(arena, json, variant),
        .randomizeAxes = if (try property(arena, json, "randomizeAxes", variant)) |axes| (if (std.ascii.eqlIgnoreCase(axes.asString() orelse "", "xz")) .xz else .xyz) else .xyz,
        .randomizeRotations = if (try property(arena, json, "randomizeRotations", variant)) |turned| turned == .bool and turned.bool else false,
    };
}

/// A block type's `randomDrawOffset`: `true` is 1, and `false` or none 0.
fn drawOffsetOf(arena: std.mem.Allocator, json: Json.Value, variant: Variant) !u8 {
    const value = try property(arena, json, "randomDrawOffset", variant) orelse return 0;
    return switch (value) {
        .bool => |on| @intFromBool(on),
        .number => |n| std.math.cast(u8, std.fmt.parseInt(i64, n, 10) catch 0) orelse 0,
        else => 0,
    };
}

/// The top of a block's selection box, `selectionBox`, else `collisionSelectionBox`, in
/// sixteenths of a block; null without one.
fn heightOf(arena: std.mem.Allocator, json: Json.Value, variant: Variant) !?u8 {
    const box = try property(arena, json, "selectionBox", variant) orelse
        try property(arena, json, "collisionSelectionBox", variant) orelse return null;
    const top = box.get("y2") orelse return null;
    if (top != .number) return null;
    const blocks = std.fmt.parseFloat(f64, top.number) catch return null;
    return @intFromFloat(std.math.clamp(@round(blocks * 16), 0, 255));
}

/// How the game draws a block, as far as the isometric view tells them apart.
const Drawing = union(enum) {
    /// A plain cube, each face its own texture.
    cube,
    /// Grassy soil (`TopSoil`): a cube of soil, with grass over its top and the top of its sides.
    topSoil,
    /// A cube in the shape the game draws at a distance (`lod0Shape`), as leaves are, each face
    /// in the texture the shape names for it.
    distantCube: Shapes.CubeElement,
    /// In a shape other than the plain cube: the block type's `shape`.
    shaped: Json.Value,
    other,
};

/// The game's shape files, each read once: the boxes of a block's shape, and the plain cube a
/// shape may hold.
pub const Shapes = struct {
    arena: std.mem.Allocator,
    io: Io,
    /// Null where there are no files to read, as in tests.
    assets: ?*const Assets,
    /// Each shape file read so far, by its location, or null if it can't be read.
    files: std.StringHashMapUnmanaged(?Json.Value) = .empty,
    /// Every shape file, listed the first time a location ends in `*`.
    listed: ?[]const Assets.Name = null,
    /// The files each location ending in `*` stands for (`matching`), by the location.
    matches: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// Each way of placing shape files met so far (`writeKey`), and its boxes, or null if none
    /// shows a face.
    geometries: std.StringHashMapUnmanaged(?*const Geometry) = .empty,
    /// What each shape read so far holds, by its location: its cube, or null without one.
    cubes: std.StringHashMapUnmanaged(?CubeElement) = .empty,

    /// A shape's element filling the whole block.
    pub const CubeElement = struct {
        /// The textures its top, south and east faces name, without their `#`.
        up: []const u8,
        south: []const u8,
        east: []const u8,
        /// The colour maps that tint it, where the element names them, as some leaves' do.
        climateColorMap: ?[]const u8 = null,
        seasonColorMap: ?[]const u8 = null,
    };

    /// The cube in the shape at `location`, or null if it has none or can't be read.
    fn cubeIn(self: *Shapes, location: Location) !?CubeElement {
        const key = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ location.domain, location.path });
        const entry = try self.cubes.getOrPut(self.arena, key);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        const json = try self.file(location) orelse return null;
        entry.value_ptr.* = fullCube(json);
        return entry.value_ptr.*;
    }

    /// The shape file at `location`, read the first time; null if it can't be read. A location
    /// ending in `*`, as an overlay's may, is the first file it stands for (`matching`).
    fn file(self: *Shapes, location: Location) !?Json.Value {
        const key = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ location.domain, location.path });
        const entry = try self.files.getOrPut(self.arena, key);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        if (std.mem.endsWith(u8, location.path, "*")) {
            const files = try self.matching(location);
            if (files.len == 0) return null;
            const json = try self.file(try .parse(self.arena, files[0], location.domain));
            // Looked up again: reading the first file may have moved the table.
            self.files.getPtr(key).?.* = json;
            return json;
        }
        const assets = self.assets orelse return null;
        const path = try std.fmt.allocPrint(self.arena, "shapes/{s}.json", .{location.path});
        // A path no file can have, such as one with a second `:`, names none.
        const text = assets.read(self.arena, self.io, location.domain, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        } orelse return null;
        entry.value_ptr.* = Json.parse(self.arena, text) catch return null;
        return entry.value_ptr.*;
    }

    /// The shape files a location ending in `*` stands for, each as "domain:path" without
    /// `shapes/` and from its last `.` on: those in its domain whose path starts with its own, in
    /// folders below too, whatever their format, each then read as the game's JSON (vsapi
    /// `CompositeShape.resolveShapeWildCards`). The game lists them in no set order; by name is a
    /// guess. For an alternate's own base, vsapi cuts the path to its shape's base's length
    /// instead, which no asset relies on, as it either fails or matches more than meant.
    fn matching(self: *Shapes, location: Location) ![]const []const u8 {
        const key = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ location.domain, location.path });
        const entry = try self.matches.getOrPut(self.arena, key);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = &.{};
        const names = self.listed orelse if (self.assets) |assets| try assets.list(self.arena, self.io, "shapes") else return &.{};
        self.listed = names;
        const start = try std.fmt.allocPrint(self.arena, "shapes/{s}", .{location.path[0 .. location.path.len - 1]});
        var found: std.ArrayList([]const u8) = .empty;
        for (names) |name| {
            if (!std.mem.eql(u8, name.domain, location.domain) or !std.mem.startsWith(u8, name.path, start)) continue;
            const end = std.mem.lastIndexOfScalar(u8, name.path, '.') orelse name.path.len;
            const path = name.path["shapes/".len..end];
            try found.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ name.domain, path }));
        }
        entry.value_ptr.* = found.items;
        return found.items;
    }

    /// The shapes the game picks one of for each block of a block type's `shape`, in the order
    /// vsapi `CompositeShape.LoadAlternates` lists them:
    /// - the shape itself, its base's first file if that ends in `*`, or the plain cube if it
    ///   stands for none;
    /// - its base's other files, turned, scaled and picking elements as the shape does, but
    ///   neither moved nor overlaid;
    /// - each of its `alternates`, or for one whose base ends in `*`, each file it stands for,
    ///   as above. An alternate without a base takes the shape's, and without
    ///   `quantityElements`, `selectiveElements` or `ignoreElements`, the shape's; everything
    ///   else is its own.
    /// A shape listed twice is picked twice as often.
    fn resolve(self: *Shapes, composite: Json.Value, domain: []const u8) ![]const Json.Value {
        const arena = self.arena;
        const base = (composite.get("base") orelse return arena.dupe(Json.Value, &.{composite})).asString() orelse return arena.dupe(Json.Value, &.{composite});
        var list: std.ArrayList(Json.Value) = .empty;
        if (std.mem.endsWith(u8, base, "*")) {
            const files = try self.matching(try .parse(arena, base, domain));
            if (files.len == 0) try list.append(arena, try withFields(arena, composite, &.{.{ .key = "base", .value = .{ .string = "game:block/basic/cube" } }}));
            for (files, 0..) |path, i| {
                const shape = if (i == 0) try withFields(arena, composite, &.{.{ .key = "base", .value = .{ .string = path } }}) else try fileOf(arena, composite, path);
                try list.append(arena, shape);
            }
        } else try list.append(arena, composite);
        for (composite.getArray("alternates")) |alternate| {
            if (alternate != .object) continue;
            const own = if (alternate.get("base")) |b| (if (b.asString()) |text| text else null) else null;
            const placed = if (own == null) try withFields(arena, alternate, &.{.{ .key = "base", .value = .{ .string = base } }}) else alternate;
            const alternateBase = own orelse base;
            if (!std.mem.endsWith(u8, alternateBase, "*")) {
                try list.append(arena, placed);
                continue;
            }
            for (try self.matching(try .parse(arena, alternateBase, domain))) |path| try list.append(arena, try fileOf(arena, placed, path));
        }
        for (list.items[1..]) |*shape| for (elementFilters) |key| {
            if (shape.get(key) != null) continue;
            const value = composite.get(key) orelse continue;
            shape.* = try withFields(arena, shape.*, &.{.{ .key = key, .value = value }});
        };
        return list.items;
    }

    const elementFilters = [_][]const u8{ "quantityElements", "selectiveElements", "ignoreElements" };

    /// One of the files a shape's base ending in `*` stands for, at `path`, turned, scaled and
    /// picking elements as `shape` does.
    fn fileOf(arena: std.mem.Allocator, shape: Json.Value, path: []const u8) !Json.Value {
        var fields: std.ArrayList(Json.Field) = .empty;
        try fields.append(arena, .{ .key = "base", .value = .{ .string = path } });
        for ([_][]const u8{ "rotateX", "rotateY", "rotateZ", "scale" } ++ elementFilters) |key| {
            if (shape.get(key)) |value| try fields.append(arena, .{ .key = key, .value = value });
        }
        return .{ .object = fields.items };
    }

    /// `object` with `fields`, which take the place of any of the same name it has.
    fn withFields(arena: std.mem.Allocator, object: Json.Value, fields: []const Json.Field) !Json.Value {
        const own: []const Json.Field = if (object == .object) object.object else &.{};
        return .{ .object = try std.mem.concat(arena, Json.Field, &.{ own, fields }) };
    }

    /// The shapes the game picks one of for each block of a block type's `shape` (`resolve`),
    /// each with the block's textures for it; empty if none shows a face.
    fn alternatesOf(self: *Shapes, composite: Json.Value, textures: []const Json.Field, tinted: bool, domain: []const u8) ![]const Shape {
        const list = try self.resolve(composite, domain);
        const found = try self.arena.alloc(Shape, list.len);
        var any = false;
        for (found, list) |*shape, placed| {
            shape.* = try self.shapeOf(placed, textures, tinted, domain) orelse .empty;
            any = any or shape.geometry.boxes.len > 0;
        }
        return if (any) found else &.{};
    }

    /// A block type's `shape` (vsapi `CompositeShape`) with its overlays, and the block's
    /// textures for it (`textureFor`). Null if no box shows a face.
    fn shapeOf(self: *Shapes, composite: Json.Value, textures: []const Json.Field, tinted: bool, domain: []const u8) !?Shape {
        const geometry = try self.geometryOf(composite, domain) orelse return null;
        const faces = try self.arena.alloc(Face, geometry.textures.len);
        for (faces, geometry.textures) |*face, name| {
            const layer = try textureFor(self.arena, textures, name, domain) orelse {
                face.* = .{};
                continue;
            };
            face.* = if (tinted or name.tinted) .{ .tinted = layer } else .{ .plain = layer };
        }
        return .{ .geometry = geometry, .textures = faces };
    }

    /// The boxes of a composite shape and its overlays, built the first time they're placed
    /// that way; null if no box shows a face.
    fn geometryOf(self: *Shapes, composite: Json.Value, domain: []const u8) !?*const Geometry {
        var key: std.Io.Writer.Allocating = .init(self.arena);
        try writeKey(&key.writer, self.arena, composite, domain);
        for (composite.getArray("overlays")) |overlay| try writeKey(&key.writer, self.arena, overlay, domain);
        const entry = try self.geometries.getOrPut(self.arena, key.written());
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        var built: Builder = .{ .shapes = self, .domain = domain };
        try built.add(composite);
        for (composite.getArray("overlays")) |overlay| try built.add(overlay);
        if (built.boxes.items.len == 0) return null;
        const geometry = try self.arena.create(Geometry);
        geometry.* = .{
            .boxes = built.boxes.items,
            .textures = built.textures.items,
            .climateColorMap = built.climateColorMap,
            .seasonColorMap = built.seasonColorMap,
        };
        entry.value_ptr.* = geometry;
        return geometry;
    }

    /// What places a composite shape's elements: its file, and how it turns, moves, scales and
    /// picks them.
    fn writeKey(w: *std.Io.Writer, arena: std.mem.Allocator, composite: Json.Value, domain: []const u8) !void {
        const base = (composite.get("base") orelse return).asString() orelse return;
        const location: Location = try .parse(arena, base, domain);
        try w.print("{s}:{s}", .{ location.domain, location.path });
        for ([_][]const u8{ "rotateX", "rotateY", "rotateZ", "offsetX", "offsetY", "offsetZ", "scale", "quantityElements" }) |field| {
            try w.print(" {d}", .{number(composite.get(field), 0)});
        }
        for ([_][]const u8{ "selectiveElements", "ignoreElements" }) |field| {
            try w.writeAll(" [");
            for (composite.getArray(field)) |item| try w.print("{s},", .{item.asString() orelse ""});
            try w.writeAll("]");
        }
        try w.writeAll("\n");
    }

    /// A shape's boxes and the textures they name, as its composite shapes are added.
    const Builder = struct {
        shapes: *Shapes,
        domain: []const u8,
        boxes: std.ArrayList(Geometry.Box) = .empty,
        textures: std.ArrayList(Geometry.TextureName) = .empty,
        climateColorMap: ?[]const u8 = null,
        seasonColorMap: ?[]const u8 = null,

        /// What one shape file gives every box: its textures, their sizes, and which elements
        /// it draws.
        const File = struct {
            location: Location,
            /// The shape's own textures, by name, each a path.
            textures: Json.Value,
            /// The size UV coordinates count a texture in, unless `sizes` names its own.
            width: f32,
            height: f32,
            sizes: Json.Value,
            selective: []const Json.Value,
            ignored: []const Json.Value,
        };

        /// Adds one composite shape's elements: its file's, turned and placed as it says.
        fn add(self: *Builder, composite: Json.Value) !void {
            const arena = self.shapes.arena;
            const base = (composite.get("base") orelse return).asString() orelse return;
            const location: Location = try .parse(arena, base, self.domain);
            const json = try self.shapes.file(location) orelse return;
            const shape: File = .{
                .location = location,
                .textures = json.get("textures") orelse .null,
                .width = number(json.get("textureWidth"), 16),
                .height = number(json.get("textureHeight"), 16),
                .sizes = json.get("textureSizes") orelse .null,
                .selective = composite.getArray("selectiveElements"),
                .ignored = composite.getArray("ignoreElements"),
            };
            // The whole shape turns about the block's middle, and is then scaled about it and
            // moved (vsapi `MeshData.Rotate`, `Scale` and `Translate`).
            const scale = number(composite.get("scale"), 1);
            var placed = translation(.{ number(composite.get("offsetX"), 0), number(composite.get("offsetY"), 0), number(composite.get("offsetZ"), 0) });
            placed = multiply(placed, translation(.{ 0.5, 0.5, 0.5 }));
            placed = multiply(placed, scaling(.{ scale, scale, scale }));
            placed = multiply(placed, rotation(.{ number(composite.get("rotateX"), 0), number(composite.get("rotateY"), 0), number(composite.get("rotateZ"), 0) }));
            placed = multiply(placed, translation(.{ -0.5, -0.5, -0.5 }));
            const elements = json.getArray("elements");
            // `quantityElements` draws only that many of the first elements.
            const count: usize = if (composite.get("quantityElements")) |q| @intFromFloat(@max(0, number(q, 0))) else elements.len;
            for (elements[0..@min(count, elements.len)]) |item| try self.element(&shape, item, placed, "", shape.selective.len == 0);
        }

        /// Adds an element's box, placed by `parent`, and its children's. `above` is the path to
        /// it, its parents' names joined by `/`, and `selected` whether the shape's
        /// `selectiveElements` take everything under one of them, or there are none.
        fn element(self: *Builder, shape: *const File, json: Json.Value, parent: Matrix, above: []const u8, selected: bool) !void {
            const name = if (json.get("name")) |n| n.asString() orelse "" else "";
            const path = if (above.len == 0) name else try std.fmt.allocPrint(self.shapes.arena, "{s}/{s}", .{ above, name });
            if (listing(shape.ignored, path, name) != .none) return;
            const selection = listing(shape.selective, path, name);
            const drawn = selected or selection != .none;
            const from = triple(json.get("from"), .{ 0, 0, 0 });
            const to = triple(json.get("to"), from);
            const origin = triple(json.get("rotationOrigin"), .{ 0, 0, 0 });
            // vsapi `ShapeElement.GetLocalTransformMatrix`: turned about its origin, then scaled,
            // its own corner at `from`, all in sixteenths of a block.
            var local = translation(.{ origin[0] / 16, origin[1] / 16, origin[2] / 16 });
            local = multiply(local, rotation(.{ number(json.get("rotationX"), 0), number(json.get("rotationY"), 0), number(json.get("rotationZ"), 0) }));
            local = multiply(local, scaling(.{ number(json.get("scaleX"), 1), number(json.get("scaleY"), 1), number(json.get("scaleZ"), 1) }));
            local = multiply(local, translation(.{ (from[0] - origin[0]) / 16, (from[1] - origin[1]) / 16, (from[2] - origin[2]) / 16 }));
            const transform = multiply(parent, local);

            if (drawn) {
                const climate = if (json.get("climateColorMap")) |m| m.asString() else null;
                const season = if (json.get("seasonColorMap")) |m| m.asString() else null;
                if (climate != null or season != null) {
                    self.climateColorMap = self.climateColorMap orelse climate;
                    self.seasonColorMap = self.seasonColorMap orelse season;
                }
                const size = [3]f32{ (to[0] - from[0]) / 16, (to[1] - from[1]) / 16, (to[2] - from[2]) / 16 };
                var faces: [6]?Geometry.BoxFace = @splat(null);
                var any = false;
                if (json.get("faces")) |list| if (list == .object) for (list.object) |field| {
                    const side = sideOf(field.key) orelse continue;
                    faces[side] = try self.face(shape, field.value, side, size, climate != null or season != null) orelse continue;
                    any = true;
                };
                if (any) try self.boxes.append(self.shapes.arena, .{
                    .transform = transform,
                    .size = size,
                    .shade = if (json.get("shade")) |s| !s.isFalse() else true,
                    .faces = faces,
                });
            }
            for (json.getArray("children")) |child| try self.element(shape, child, transform, path, selected or selection == .withChildren);
        }

        /// A face's texture and where its corners are on it; null if it's turned off or names
        /// no texture.
        fn face(self: *Builder, shape: *const File, json: Json.Value, side: usize, size: [3]f32, elementTinted: bool) !?Geometry.BoxFace {
            if (json.get("enabled")) |enabled| if (enabled.isFalse()) return null;
            const reference = (json.get("texture") orelse return null).asString() orelse return null;
            const code = if (std.mem.startsWith(u8, reference, "#")) reference[1..] else reference;
            const texture = try self.textureNumber(shape, code, elementTinted);
            const textureSize = if (shape.sizes.get(code)) |s| s.asArray() else &.{};
            const width = if (textureSize.len == 2) number(textureSize[0], shape.width) else shape.width;
            const height = if (textureSize.len == 2) number(textureSize[1], shape.height) else shape.height;
            // Without its own, a face takes as much of the texture as it is big, from the corner.
            const faceSize: [2]f32 = switch (side) {
                0, 2 => .{ size[0], size[1] },
                1, 3 => .{ size[2], size[1] },
                else => .{ size[0], size[2] },
            };
            const rect = json.getArray("uv");
            const uv: [4]f32 = if (rect.len == 4)
                .{ number(rect[0], 0), number(rect[1], 0), number(rect[2], 0), number(rect[3], 0) }
            else
                .{ 0, 0, faceSize[0] * 16, faceSize[1] * 16 };
            const turns: usize = @intFromFloat(@mod(@round(number(json.get("rotation"), 0) / 90), 4));
            var corners: [4][2]f32 = undefined;
            for (&corners, 0..) |*corner, i| {
                const at = uvCorners[side][(i + turns) % 4];
                corner.* = .{ (uv[0] + (uv[2] - uv[0]) * at[0]) / width, (uv[1] + (uv[3] - uv[1]) * at[1]) / height };
            }
            return .{ .texture = texture, .uv = corners };
        }

        /// The number of the texture a face names, added the first time.
        fn textureNumber(self: *Builder, shape: *const File, code: []const u8, tinted: bool) !u16 {
            const arena = self.shapes.arena;
            const own: ?[]const u8 = if (shape.textures.get(code)) |value| own: {
                const path = value.asString() orelse break :own null;
                const location: Location = try .parse(arena, path, shape.location.domain);
                break :own try std.fmt.allocPrint(arena, "{s}:{s}", .{ location.domain, location.path });
            } else null;
            for (self.textures.items, 0..) |name, i| {
                const sameOwn = if (name.own) |a| (if (own) |b| std.mem.eql(u8, a, b) else false) else own == null;
                if (std.mem.eql(u8, name.code, code) and sameOwn and name.tinted == tinted) return @intCast(i);
            }
            if (self.textures.items.len >= std.math.maxInt(u16)) return error.TooManyTextures;
            try self.textures.append(arena, .{ .code = code, .own = own, .tinted = tinted });
            return @intCast(self.textures.items.len - 1);
        }
    };

    /// Which corner of a face's UV rectangle, left or right and top or bottom, each corner in
    /// `world.Shape.Side.corners` order takes: the Model Creator's `Face.cubeUVCoords`, which
    /// draws shapes as the game does. A face's `rotation` shifts them a quarter at a time.
    const uvCorners = [6][4][2]f32{
        .{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 } },
        .{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 } },
        .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } },
        .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } },
        .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } },
        .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } },
    };
};

/// A block type's texture for one its shape names: its texture of that name, or for a side's
/// name, its group's, as a cube's faces take them; else the shape file's own; else its `all`,
/// or `sides`. Null if it has none. The game picks them in closed code; stairs, which name only
/// `horizontals`, `up` and `down` or only `sides` for faces named after their sides, need these.
fn textureFor(arena: std.mem.Allocator, textures: []const Json.Field, name: Geometry.TextureName, domain: []const u8) !?Layer {
    if (try layerOf(arena, findTexture(textures, &.{name.code}), domain)) |found| return found;
    const sides = [_][]const u8{ "north", "east", "south", "west", "up", "down" };
    for (sides, 0..) |side, i| {
        if (!std.mem.eql(u8, name.code, side)) continue;
        const group = if (i < 4) "horizontals" else "verticals";
        if (try layerOf(arena, findTexture(textures, &.{group}), domain)) |found| return found;
    }
    if (name.own) |own| return .{ .base = own };
    return layerOf(arena, findTexture(textures, &.{ "all", "sides" }), domain);
}

/// A face's side, by `world.Shape.Side`, from the first letter of its name, as the game reads
/// them (vsapi `BlockFacing.FromFirstLetter`).
fn sideOf(name: []const u8) ?usize {
    if (name.len == 0) return null;
    return switch (std.ascii.toLower(name[0])) {
        'n' => 0,
        'e' => 1,
        's' => 2,
        'w' => 3,
        'u' => 4,
        'd' => 5,
        else => null,
    };
}

/// How a composite shape's `selectiveElements` or `ignoreElements` name an element, by its
/// `name` or its `path` from the top: not at all, alone, or with everything under it, as
/// `Stem/*`.
fn listing(names: []const Json.Value, path: []const u8, name: []const u8) enum { none, alone, withChildren } {
    for (names) |value| {
        const text = value.asString() orelse continue;
        if (std.mem.endsWith(u8, text, "/*")) {
            const target = text[0 .. text.len - 2];
            if (std.mem.eql(u8, target, path) or std.mem.eql(u8, target, name)) return .withChildren;
        } else if (std.mem.eql(u8, text, path) or std.mem.eql(u8, text, name)) return .alone;
    }
    return .none;
}

fn number(value: ?Json.Value, default: f32) f32 {
    const n = value orelse return default;
    if (n != .number) return default;
    return std.fmt.parseFloat(f32, n.number) catch default;
}

fn triple(value: ?Json.Value, default: [3]f32) [3]f32 {
    const items = (value orelse return default).asArray();
    if (items.len != 3) return default;
    return .{ number(items[0], default[0]), number(items[1], default[1]), number(items[2], default[2]) };
}

/// Three rows of a 4 × 4 matrix whose last row is 0, 0, 0, 1.
const Matrix = [3][4]f32;

fn multiply(a: Matrix, b: Matrix) Matrix {
    var out: Matrix = undefined;
    for (0..3) |row| for (0..4) |column| {
        var sum: f32 = if (column == 3) a[row][3] else 0;
        for (0..3) |k| sum += a[row][k] * b[k][column];
        out[row][column] = sum;
    };
    return out;
}

fn translation(by: [3]f32) Matrix {
    return .{ .{ 1, 0, 0, by[0] }, .{ 0, 1, 0, by[1] }, .{ 0, 0, 1, by[2] } };
}

fn scaling(by: [3]f32) Matrix {
    return .{ .{ by[0], 0, 0, 0 }, .{ 0, by[1], 0, 0 }, .{ 0, 0, by[2], 0 } };
}

/// Turning by `degrees` about x, then y, then z, as vsapi `Mat4f.RotateByXYZ` and `RotateXYZ`
/// multiply them.
fn rotation(degrees: [3]f32) Matrix {
    const radians = std.math.pi / 180.0;
    const sx = @sin(degrees[0] * radians);
    const cx = @cos(degrees[0] * radians);
    const sy = @sin(degrees[1] * radians);
    const cy = @cos(degrees[1] * radians);
    const sz = @sin(degrees[2] * radians);
    const cz = @cos(degrees[2] * radians);
    const a01 = sx * sy;
    const a02 = -cx * sy;
    return .{
        .{ cy * cz, -cy * sz, sy, 0 },
        .{ a01 * cz + cx * sz, cx * cz - a01 * sz, -sx * cy, 0 },
        .{ a02 * cz + sx * sz, sx * cz - a02 * sz, cx * cy, 0 },
    };
}

/// A shape's first element filling the whole block, from 0 to 16 on every axis, unturned; null
/// without one, or if a face it shows is missing.
fn fullCube(shape: Json.Value) ?Shapes.CubeElement {
    const elements = shape.get("elements") orelse return null;
    if (elements != .array) return null;
    for (elements.array) |element| {
        if (!isFullBlock(element)) continue;
        const faces = element.get("faces") orelse return null;
        return .{
            .up = faceTexture(faces, "up") orelse return null,
            .south = faceTexture(faces, "south") orelse return null,
            .east = faceTexture(faces, "east") orelse return null,
            .climateColorMap = if (element.get("climateColorMap")) |map| map.asString() else null,
            .seasonColorMap = if (element.get("seasonColorMap")) |map| map.asString() else null,
        };
    }
    return null;
}

fn isFullBlock(element: Json.Value) bool {
    for ([_][]const u8{ "rotationX", "rotationY", "rotationZ" }) |axis| {
        const angle = element.get(axis) orelse continue;
        if (angle != .number or (std.fmt.parseFloat(f64, angle.number) catch 1) != 0) return false;
    }
    for ([_][]const u8{ "from", "to" }, [_]f64{ 0, 16 }) |key, wanted| {
        const corner = element.get(key) orelse return false;
        if (corner != .array or corner.array.len != 3) return false;
        for (corner.array) |value| {
            if (value != .number or (std.fmt.parseFloat(f64, value.number) catch -1) != wanted) return false;
        }
    }
    return true;
}

/// The texture a face names, without its `#`; null if it's missing or turned off.
fn faceTexture(faces: Json.Value, name: []const u8) ?[]const u8 {
    const face = faces.get(name) orelse return null;
    if (face.get("enabled")) |enabled| if (enabled == .bool and !enabled.bool) return null;
    const texture = (face.get("texture") orelse return null).asString() orelse return null;
    return if (std.mem.startsWith(u8, texture, "#")) texture[1..] else texture;
}

test fullCube {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The leaves' distant shape: crossed planes, and the cube.
    const shape = try Json.parse(a,
        \\{ "elements": [
        \\  { "from": [ -8, -8, 8 ], "to": [ 24, 24, 8 ], "rotationY": 45, "faces": { "north": { "texture": "#largeleaves" } } },
        \\  { "from": [ 0.0, 0.0, 0.0 ], "to": [ 16.0, 16.0, 16.0 ], "climateColorMap": "climatePlantTint", "faces": {
        \\    "up": { "texture": "#smallleaves" }, "south": { "texture": "#smallleaves" }, "east": { "texture": "#side" } } }
        \\] }
    );
    const cube = fullCube(shape).?;
    try std.testing.expectEqualStrings("smallleaves", cube.up);
    try std.testing.expectEqualStrings("side", cube.east);
    try std.testing.expectEqualStrings("climatePlantTint", cube.climateColorMap.?);
    try std.testing.expectEqual(null, cube.seasonColorMap);
    // A turned cube, and a face turned off, aren't.
    try std.testing.expectEqual(null, fullCube(try Json.parse(a, "{ elements: [ { from: [ 0, 0, 0 ], to: [ 16, 16, 16 ], rotationX: 90, faces: {} } ] }")));
    try std.testing.expectEqual(null, fullCube(try Json.parse(a, "{ elements: [ { from: [ 0, 0, 0 ], to: [ 16, 16, 16 ], faces: { up: { texture: '#a', enabled: false }, south: { texture: '#a' }, east: { texture: '#a' } } } ] }")));
}

/// From its `drawtype`, which is `json` without one: a JSON block whose shape is the game's
/// default, the plain cube, unturned, is drawn as a cube too (vsapi `Block.DrawType`,
/// `Block.DefaultCubeShape`), and so is one whose shape at a distance holds a cube, and a
/// liquid. Any other JSON block, also one under snow or in water, is drawn in its shape.
fn drawingOf(arena: std.mem.Allocator, json: Json.Value, variant: Variant, shapes: *Shapes) !Drawing {
    const drawtype = if (try property(arena, json, "drawtype", variant)) |d| d.asString() orelse "json" else "json";
    if (std.ascii.eqlIgnoreCase(drawtype, "cube")) return .cube;
    if (std.ascii.eqlIgnoreCase(drawtype, "topsoil")) return .topSoil;
    // Liquids are a cube in their `all` texture, if lower where they flow, and see-through.
    if (std.ascii.eqlIgnoreCase(drawtype, "liquid")) return .cube;
    // A shape with a layer of snow over it, or in water, is drawn as the shape alone.
    const jsonDrawtypes = [_][]const u8{ "json", "jsonandsnowlayer", "jsonandwater" };
    for (jsonDrawtypes) |name| {
        if (std.ascii.eqlIgnoreCase(drawtype, name)) break;
    } else return .other;
    const shape = try property(arena, json, "shape", variant) orelse return .cube;
    if (try isCubeShape(arena, shape)) return .cube;
    const shaped: Drawing = .{ .shaped = shape };
    const distant = try property(arena, json, "lod0Shape", variant) orelse return shaped;
    const base = (distant.get("base") orelse return shaped).asString() orelse return shaped;
    const names = try shapes.cubeIn(try .parse(arena, base, Assets.gameDomain)) orelse return shaped;
    return .{ .distantCube = names };
}

/// Whether a block's `shape` is the plain cube, unturned.
fn isCubeShape(arena: std.mem.Allocator, shape: Json.Value) !bool {
    const base = (shape.get("base") orelse return false).asString() orelse return false;
    const location: Location = try .parse(arena, base, Assets.gameDomain);
    // `cube-nozfight`, for glacier ice, insets each pair of faces by 0.006 of a pixel.
    const cubes = [_][]const u8{ "block/basic/cube", "block/basic/cube-nozfight" };
    for (cubes) |cube| {
        if (std.mem.eql(u8, location.path, cube)) break;
    } else return false;
    for ([_][]const u8{ "rotateX", "rotateY", "rotateZ" }) |axis| {
        const angle = shape.get(axis) orelse continue;
        if (angle != .number or (std.fmt.parseFloat(f64, angle.number) catch 1) != 0) return false;
    }
    return true;
}

/// A cube's faces from its block's textures, or null if it isn't drawn as one or a face has
/// no texture. A face takes the texture named for it, else its group's, else `all`. A block with
/// colour maps has every face tinted, except grassy soil, which tints only its grass, the
/// right half of its `specialSecondTexture` on top and the left half on the sides.
fn cubeOf(arena: std.mem.Allocator, textures: []const Json.Field, drawing: Drawing, tinted: bool, domain: []const u8) !?Cube {
    if (drawing == .other or drawing == .shaped) return null;
    // A shape's cube names each face's texture itself.
    const names: [3][]const []const u8 = switch (drawing) {
        .distantCube => |shape| .{ &.{shape.up}, &.{shape.south}, &.{shape.east} },
        else => .{ &.{ "up", "verticals", "all" }, &.{ "south", "horizontals", "all" }, &.{ "east", "horizontals", "all" } },
    };
    const up = try layerOf(arena, findTexture(textures, names[0]), domain) orelse return null;
    const south = try layerOf(arena, findTexture(textures, names[1]), domain) orelse return null;
    const east = try layerOf(arena, findTexture(textures, names[2]), domain) orelse return null;
    if (drawing == .topSoil) {
        const grass = try textureLocation(arena, findTexture(textures, &.{"specialSecondTexture"}) orelse return null, domain) orelse return null;
        return .{
            .up = .{ .plain = up, .tinted = .{ .base = grass, .half = .right } },
            .south = .{ .plain = south, .tinted = .{ .base = grass, .half = .left } },
            .east = .{ .plain = east, .tinted = .{ .base = grass, .half = .left } },
        };
    }
    const face = struct {
        fn of(layer: Layer, isTinted: bool) Face {
            return if (isTinted) .{ .tinted = layer } else .{ .plain = layer };
        }
    }.of;
    return .{ .up = face(up, tinted), .south = face(south, tinted), .east = face(east, tinted) };
}

/// Case-sensitive, as in the game.
fn findTexture(textures: []const Json.Field, names: []const []const u8) ?Json.Value {
    for (names) |name| for (textures) |texture| if (std.mem.eql(u8, texture.key, name)) return texture.value;
    return null;
}

/// A texture's base and overlays, or null without a base.
fn layerOf(arena: std.mem.Allocator, texture: ?Json.Value, domain: []const u8) !?Layer {
    const value = texture orelse return null;
    const base = try textureLocation(arena, value, domain) orelse return null;
    var overlays: std.ArrayList([]const u8) = .empty;
    if (value.get("overlays")) |list| if (list == .array) for (list.array) |item| {
        const path = item.asString() orelse continue;
        const location: Location = try .parse(arena, path, domain);
        try overlays.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ location.domain, location.path }));
    };
    return .{ .base = base, .overlays = overlays.items };
}

/// Case-sensitive, as in the game.
fn pickTexture(textures: []const Json.Field, code: ?[]const u8) Json.Value {
    if (code) |wanted| for (textures) |texture| if (std.mem.eql(u8, texture.key, wanted)) return texture.value;
    for (textures) |texture| if (std.mem.eql(u8, texture.key, "up")) return texture.value;
    return textures[0].value;
}

/// A texture's `base` as lowercase "domain:path", in `domain` unless it names its own.
fn textureLocation(arena: std.mem.Allocator, texture: Json.Value, domain: []const u8) !?[]const u8 {
    const base = (texture.get("base") orelse return null).asString() orelse return null;
    const location: Location = try .parse(arena, base, domain);
    return try std.fmt.allocPrint(arena, "{s}:{s}", .{ location.domain, location.path });
}

/// `name` in the game's spelling, or the default if unknown.
fn canonicalMaterial(name: []const u8) []const u8 {
    for (materials) |material| if (std.ascii.eqlIgnoreCase(material, name)) return material;
    return defaultMaterial;
}

/// Property `key` for one variant, as vsessentialsmod `RegistryObjectType.solveByType`
/// resolves it: `keyByType` gives the value of its first key matching the variant's code,
/// merged into `key` if both are objects; nested `…ByType` properties resolve the same way, and
/// `{group}` placeholders in strings are filled from the variant. Only `key` and `keyByType`
/// are resolved.
fn property(arena: std.mem.Allocator, json: Json.Value, key: []const u8, variant: Variant) !?Json.Value {
    if (json != .object) return null;
    var fields: std.ArrayList(Json.Field) = .empty;
    for (json.object) |field| {
        const isKey = std.ascii.eqlIgnoreCase(field.key, key);
        const isByType = std.ascii.endsWithIgnoreCase(field.key, byType) and std.ascii.eqlIgnoreCase(field.key[0 .. field.key.len - byType.len], key);
        if (isKey or isByType) try fields.append(arena, field);
    }
    if (fields.items.len == 0) return null;
    const resolved = try solveByType(arena, .{ .object = fields.items }, variant);
    return resolved.get(key);
}

const byType = "byType";

fn solveByType(arena: std.mem.Allocator, value: Json.Value, variant: Variant) !Json.Value {
    switch (value) {
        .object => |fields| {
            var kept: std.ArrayList(Json.Field) = .empty;
            var added: std.ArrayList(Json.Field) = .empty;
            for (fields) |field| {
                if (field.key.len < byType.len or !std.ascii.endsWithIgnoreCase(field.key, byType)) {
                    try kept.append(arena, field);
                    continue;
                }
                if (field.value != .object) return error.InvalidByType;
                for (field.value.object) |candidate| {
                    if (try Wildcard.match(candidate.key, variant.code.path)) {
                        try added.append(arena, .{ .key = field.key[0 .. field.key.len - byType.len], .value = candidate.value });
                        break;
                    }
                }
            }
            for (added.items) |addition| {
                for (kept.items) |*existing| {
                    // Case-sensitive, as in the game.
                    if (!std.mem.eql(u8, existing.key, addition.key)) continue;
                    existing.value = if (existing.value == .object) try Json.merge(arena, existing.value, addition.value) else addition.value;
                    break;
                } else try kept.append(arena, addition);
            }
            for (kept.items) |*field| field.value = try solveByType(arena, field.value, variant);
            return .{ .object = kept.items };
        },
        .array => |items| {
            const resolved = try arena.alloc(Json.Value, items.len);
            for (resolved, items) |*out, item| out.* = try solveByType(arena, item, variant);
            return .{ .array = resolved };
        },
        .string => |text| return .{ .string = try fillPlaceholders(arena, text, variant.parts) },
        else => return value,
    }
}

/// Replaces each `{group}` placeholder with the variant's state of that group. `{wood|rock}`
/// is replaced if any alternative is one of its groups (vsapi `RegistryObject.FillPlaceHolder`).
fn fillPlaceholders(arena: std.mem.Allocator, text: []const u8, parts: []const Part) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '{') == null) return text;
    var current = text;
    for (parts) |part| {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < current.len) {
            if (current[i] == '{') {
                if (std.mem.indexOfAnyPos(u8, current, i + 1, "{}")) |end| if (current[end] == '}') {
                    var names = std.mem.splitScalar(u8, current[i + 1 .. end], '|');
                    const named = while (names.next()) |name| {
                        if (std.mem.eql(u8, name, part.group)) break true;
                    } else false;
                    if (named) {
                        try out.appendSlice(arena, part.state);
                        i = end + 1;
                        continue;
                    }
                };
            }
            try out.append(arena, current[i]);
            i += 1;
        }
        current = out.items;
    }
    return current;
}

test fillPlaceholders {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parts = [_]Part{ .{ .group = "rock", .state = "granite" }, .{ .group = "side", .state = "up" } };
    try std.testing.expectEqualStrings("block/stone/rock/granite1", try fillPlaceholders(arena.allocator(), "block/stone/rock/{rock}1", &parts));
    try std.testing.expectEqualStrings("granite-up", try fillPlaceholders(arena.allocator(), "{wood|rock}-{side}", &parts));
    try std.testing.expectEqualStrings("{wood}", try fillPlaceholders(arena.allocator(), "{wood}", &parts));
}

const Expander = struct {
    arena: std.mem.Allocator,
    io: Io,
    assets: *const Assets,
    /// World property files by their location ("game:block/rock", for
    /// worldproperties/block/rock.json): the property's code ("game:rock").
    properties: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Variant codes by property code.
    propertyVariants: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn loadWorldProperties(self: *Expander) !void {
        for (try self.assets.list(self.arena, self.io, "worldproperties")) |name| {
            if (!std.mem.endsWith(u8, name.path, ".json")) continue;
            const json = try self.readJson(name.domain, name.path) orelse continue;
            const codeText = (json.get("code") orelse continue).asString() orelse continue;
            const code = try Location.parse(self.arena, codeText, name.domain);
            const key = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ name.domain, name.path["worldproperties/".len .. name.path.len - ".json".len] });
            const codeKey = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ code.domain, code.path });
            var variants: std.ArrayList([]const u8) = .empty;
            for (json.getArray("variants")) |variant| {
                const variantCode = (variant.get("code") orelse continue).asString() orelse continue;
                try variants.append(self.arena, (try Location.parse(self.arena, variantCode, name.domain)).path);
            }
            try self.properties.put(self.arena, key, codeKey);
            try self.propertyVariants.put(self.arena, codeKey, variants.items);
        }
    }

    fn readJson(self: *Expander, domain: []const u8, path: []const u8) !?Json.Value {
        const text = try self.assets.read(self.arena, self.io, domain, path) orelse return null;
        return try Json.parse(self.arena, text);
    }

    /// One block type file and its variants, as RegistryObjectType.CreateBasetype and
    /// ModRegistryObjectTypeLoader.GatherVariants make them.
    fn blockType(self: *Expander, name: Assets.Name) !struct { json: Json.Value, variants: []const Variant } {
        var json = try self.readJson(name.domain, name.path) orelse return error.FileNotFound;
        json = try self.inherit(json, name.domain, 0);
        const base = try Location.parse(self.arena, (json.get("code") orelse return error.NoCode).asString() orelse return error.NoCode, name.domain);
        if (json.get("enabled")) |enabled| if (enabled.isFalse()) return .{ .json = json, .variants = &.{} };

        const groups = json.getArray("variantgroups");
        if (groups.len == 0) return .{ .json = json, .variants = try self.one(base) };
        const skipped = try self.locations(json.get("skipVariants"), name.domain);
        const allowed = try self.locations(json.get("allowedVariants"), name.domain);
        const variants = try self.gather(base, groups, skipped, allowed, name);
        return .{ .json = json, .variants = if (variants.len == 0) try self.one(base) else variants };
    }

    fn one(self: *Expander, code: Location) ![]const Variant {
        const list = try self.arena.alloc(Variant, 1);
        list[0] = .{ .code = code, .parts = &.{} };
        return list;
    }

    /// Lays a block type over the file its `inheritFrom` names, recursively.
    fn inherit(self: *Expander, json: Json.Value, domain: []const u8, depth: usize) !Json.Value {
        const from = (json.get("inheritFrom") orelse return json).asString() orelse return json;
        if (depth == 16) return error.InheritsTooDeep;
        const parent = try Location.parse(self.arena, from, domain);
        const path = if (std.mem.endsWith(u8, parent.path, ".json")) parent.path else try std.fmt.allocPrint(self.arena, "{s}.json", .{parent.path});
        const base = try self.readJson(parent.domain, path) orelse return error.InheritedFileMissing;
        const merged = try Json.merge(self.arena, try self.inherit(base, domain, depth + 1), json);
        if (merged != .object) return merged;
        var fields: std.ArrayList(Json.Field) = .empty;
        for (merged.object) |field| {
            if (!std.ascii.eqlIgnoreCase(field.key, "inheritFrom")) try fields.append(self.arena, field);
        }
        return .{ .object = fields.items };
    }

    fn locations(self: *Expander, value: ?Json.Value, domain: []const u8) !?[]const Location {
        const items = (value orelse return null).asArray();
        const list = try self.arena.alloc(Location, items.len);
        for (list, items) |*location, item| location.* = try Location.parse(self.arena, item.asString() orelse "", domain);
        return list;
    }

    /// Groups that multiply give every combination of their states; groups that add give one
    /// variant per state.
    fn gather(self: *Expander, base: Location, groups: []const Json.Value, skipped: ?[]const Location, allowed: ?[]const Location, name: Assets.Name) ![]const Variant {
        const arena = self.arena;
        var added: std.ArrayList([]const Part) = .empty;
        // Each multiplying group's entries, in the order the groups first appear.
        var multiplied: std.StringArrayHashMapUnmanaged(std.ArrayList([]const Part)) = .empty;

        for (groups) |group| {
            const groupCode = if (group.get("code")) |code| code.asString() else null;
            const combine = if (group.get("combine")) |c| c.asString() orelse "multiply" else "multiply";
            const adds = std.ascii.eqlIgnoreCase(combine, "add");
            const multiplies = std.ascii.eqlIgnoreCase(combine, "multiply");

            var propertyNames: std.ArrayList([]const u8) = .empty;
            if (group.get("loadFromProperties")) |p| if (p.asString()) |s| try propertyNames.append(arena, s);
            for (group.getArray("loadFromPropertiesCombine")) |p| {
                if (p.asString()) |s| try propertyNames.append(arena, s);
            }
            for (propertyNames.items) |propertyName| {
                const location = try Location.parse(arena, propertyName, Assets.gameDomain);
                const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ location.domain, location.path });
                const codeKey = self.properties.get(key) orelse {
                    console.warn("{s}:{s}: unknown world property {s}", .{ name.domain, name.path, key });
                    break;
                };
                const typeName = groupCode orelse codeKey[std.mem.indexOfScalar(u8, codeKey, ':').? + 1 ..];
                for (self.propertyVariants.get(codeKey).?) |state| {
                    const entry = try onePart(arena, typeName, state);
                    if (adds) try added.append(arena, entry);
                    if (multiplies) {
                        const list = try multiplied.getOrPut(arena, typeName);
                        if (!list.found_existing) list.value_ptr.* = .empty;
                        try list.value_ptr.append(arena, entry);
                    }
                }
            }

            const states = (group.get("states") orelse continue).asArray();
            const code = groupCode orelse continue;
            if (adds) for (states) |state| try added.append(arena, try onePart(arena, code, state.asString() orelse ""));
            if (multiplies) {
                var stateList: std.ArrayList([]const Part) = .empty;
                for (states) |state| try stateList.append(arena, try onePart(arena, code, state.asString() orelse ""));
                try self.selectivelyMultiply(&stateList, groups, code);
                const list = try multiplied.getOrPut(arena, code);
                if (list.found_existing) {
                    // A state list goes before what the group already has.
                    try stateList.appendSlice(arena, list.value_ptr.items);
                }
                list.value_ptr.* = stateList;
            }
        }

        // Every combination of the multiplying groups' entries, the first group varying fastest.
        const lists = multiplied.values();
        var total: usize = if (lists.len == 0) 0 else 1;
        for (lists) |list| total = std.math.mul(usize, total, list.items.len) catch return error.TooManyVariants;
        var variants: std.ArrayList([]const Part) = try .initCapacity(arena, added.items.len + total);
        variants.appendSliceAssumeCapacity(added.items);
        for (0..total) |i| {
            var parts: std.ArrayList(Part) = .empty;
            var index = i;
            for (lists) |list| {
                try parts.appendSlice(arena, list.items[index % list.items.len]);
                index /= list.items.len;
            }
            variants.appendAssumeCapacity(parts.items);
        }

        var codes: std.ArrayList(Variant) = .empty;
        next: for (variants.items) |parts| {
            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(arena, base.path);
            for (parts) |part| {
                if (part.state.len == 0) continue;
                try path.append(arena, '-');
                try path.appendSlice(arena, part.state);
            }
            const code: Location = .{ .domain = base.domain, .path = std.ascii.lowerString(path.items, path.items) };
            if (skipped) |patterns| for (patterns) |pattern| {
                if (matchOrWarn(pattern, code, name)) continue :next;
            };
            if (allowed) |patterns| {
                for (patterns) |pattern| {
                    if (matchOrWarn(pattern, code, name)) break;
                } else continue :next;
            }
            try codes.append(arena, .{ .code = code, .parts = parts });
        }
        return codes.items;
    }

    /// A selectively multiplying group (`combine: "selectiveMultiply", onVariant: <group>`)
    /// splits the entry of `group` whose code is the selective group's code into one entry
    /// per state of its own. Unused by 1.22.7 and the mods checked.
    fn selectivelyMultiply(self: *Expander, stateList: *std.ArrayList([]const Part), groups: []const Json.Value, group: []const u8) !void {
        for (groups) |selective| {
            const combine = (selective.get("combine") orelse continue).asString() orelse continue;
            if (!std.ascii.eqlIgnoreCase(combine, "selectivemultiply")) continue;
            const onVariant = (selective.get("onVariant") orelse continue).asString() orelse continue;
            if (!std.mem.eql(u8, onVariant, group)) continue;
            const code = (selective.get("code") orelse continue).asString() orelse continue;
            var k: usize = 0;
            while (k < stateList.items.len) : (k += 1) {
                const old = stateList.items[k];
                if (!try codeIs(self.arena, old, code)) continue;
                _ = stateList.orderedRemove(k);
                for (selective.getArray("states")) |state| {
                    const parts = try self.arena.alloc(Part, old.len + 1);
                    @memcpy(parts[0..old.len], old);
                    parts[old.len] = .{ .group = code, .state = state.asString() orelse "" };
                    try stateList.insert(self.arena, k, parts);
                }
            }
        }
    }
};

fn matchOrWarn(pattern: Location, code: Location, name: Assets.Name) bool {
    return pattern.matches(code) catch |err| {
        console.warn("{s}:{s}: could not read variant pattern {s} ({s})", .{ name.domain, name.path, pattern.path, @errorName(err) });
        return false;
    };
}

fn onePart(arena: std.mem.Allocator, group: []const u8, state: []const u8) ![]const Part {
    const parts = try arena.alloc(Part, 1);
    parts[0] = .{ .group = group, .state = state };
    return parts;
}

/// Whether an entry's states, joined with "-", are `code`.
fn codeIs(arena: std.mem.Allocator, parts: []const Part, code: []const u8) !bool {
    var joined: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        if (part.state.len == 0) continue;
        if (joined.items.len > 0) try joined.append(arena, '-');
        try joined.appendSlice(arena, part.state);
    }
    return std.mem.eql(u8, joined.items, code);
}

test "variants multiply, add, inherit and filter" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "game/assets/survival/worldproperties/block/rock.json", "{ code: 'rock', variants: [ { code: 'granite' }, { code: 'basalt' } ] }" },
        .{ "game/assets/survival/blocktypes/stone/rock.json", "{ code: 'rock', variantgroups: [ { loadFromProperties: 'block/rock' } ] }" },
        .{
            "game/assets/survival/blocktypes/slab.json",
            \\{ code: "slab",
            \\  variantgroups: [ { code: "rock", loadFromProperties: "block/rock" }, { code: "side", states: ["up", "down"] } ],
            \\  skipVariants: [ "slab-basalt-*" ], }
        },
        .{ "game/assets/survival/blocktypes/torch.json", "{ code: 'torch', variantgroups: [ { code: 'state', states: ['lit', 'out'], combine: 'add' } ] }" },
        .{ "game/assets/survival/blocktypes/off.json", "{ code: 'off', enabled: 0 }" },
        .{ "game/assets/survival/blocktypes/fence.json", "{ code: 'fence', inheritFrom: 'blocktypes/base/fencebase', }" },
        .{ "game/assets/survival/blocktypes/base/fencebase.json", "{ code: 'base', variantgroups: [ { code: 'wood', states: ['oak'] } ] }" },
        .{ "data/Mods/mod/assets/mymod/blocktypes/thing.json", "{ code: 'Thing', variantgroups: [ { code: 'size', states: ['big', ''] } ], allowedVariants: ['thing-big', 'thing'] }" },
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

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try expand(arena.allocator(), io, &assets);
    var codes: std.ArrayList([]const u8) = .empty;
    for (blocks) |block| try codes.append(arena.allocator(), block.code);
    std.mem.sort([]const u8, codes.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    // The base a block type inherits from is in blocktypes/ too, so it's a block type itself.
    const expected = [_][]const u8{
        "base-oak",
        "fence-oak",
        "mymod:thing",
        "mymod:thing-big",
        "rock-basalt",
        "rock-granite",
        "slab-granite-down",
        "slab-granite-up",
        "torch-lit",
        "torch-out",
    };
    try std.testing.expectEqual(expected.len, codes.items.len);
    for (expected, codes.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "materials and map colour codes, resolved per variant" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{
            "game/assets/survival/blocktypes/soil.json",
            \\{ code: "soil", variantgroups: [ { code: "kind", states: ["loam", "sand", "leafy", "snowy"] } ],
            \\  blockmaterialByType: { "@soil-(sand)": "sand", "soil-leafy": "Leaves", "*-snowy": "Snow", "*": "soil" },
            \\  attributes: { mapColorCodeByType: { "soil-loam": "{kind}-colour" }, other: 1 },
            \\  attributesByType: { "soil-sand": { mapColorCode: "settlement" } } }
        },
        .{ "game/assets/survival/blocktypes/plain.json", "{ code: 'plain' }" },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var game = try tmp.dir.openDir(io, "game", .{});
    defer game.close(io);
    var assets = try Assets.open(std.testing.allocator, io, game, null);
    defer assets.close(io);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try expand(arena.allocator(), io, &assets);
    const expected = [_][3][]const u8{
        .{ "plain", "Stone", "land" },
        // A placeholder filled from the variant, in a mapColorCode from a nested …ByType.
        .{ "soil-loam", "Soil", "loam-colour" },
        // attributesByType merged into attributes; the regex key picks the material.
        .{ "soil-sand", "Sand", "settlement" },
        // No mapColorCode: the material's default.
        .{ "soil-leafy", "Leaves", "forest" },
        .{ "soil-snowy", "Snow", "glacier" },
    };
    try std.testing.expectEqual(expected.len, blocks.len);
    for (expected) |want| {
        const block = for (blocks) |block| {
            if (std.mem.eql(u8, block.code, want[0])) break block;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want[1], block.material);
        try std.testing.expectEqualStrings(want[2], block.colorCode);
    }
}

test "the textures that colour a block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const variant: Variant = .{ .code = .{ .domain = "game", .path = "rock-granite" }, .parts = &.{.{ .group = "rock", .state = "granite" }} };
    const cases = [_]struct { json: []const u8, colour: ?[]const u8, grain: ?[]const u8 }{
        // The first, as there's no up, with the placeholder filled.
        .{ .json = "{ textures: { all: { base: 'block/stone/rock/{rock}1' }, north: { base: 'x' } } }", .colour = "game:block/stone/rock/granite1", .grain = "game:block/stone/rock/granite1" },
        // Up, before the first.
        .{ .json = "{ textures: { side: { base: 'Side' }, up: { base: 'top' } } }", .colour = "game:top", .grain = "game:top" },
        // Each by its own code, from …ByType, in another domain.
        .{
            .json = "{ attributes: { textureCodeForBlockColor: 'side' }, particlesTextureCodeByType: { '*': 'other' }, texturesByType: { 'rock-*': { up: { base: 'top' }, side: { base: 'mod:side' }, other: { base: 'grain' } } } }",
            .colour = "mod:side",
            .grain = "game:grain",
        },
        .{ .json = "{ textures: {} }", .colour = null, .grain = null },
        .{ .json = "{ code: 'rock' }", .colour = null, .grain = null },
    };
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };
    for (cases) |case| {
        const look = try describe(a, try Json.parse(a, case.json), variant, &shapes);
        try std.testing.expectEqualDeep(case.colour, look.textures.colour);
        try std.testing.expectEqualDeep(case.grain, look.textures.grain);
    }
}

test "the cube a block is drawn as" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rock: Variant = .{ .code = .{ .domain = "game", .path = "rock-granite" }, .parts = &.{.{ .group = "rock", .state = "granite" }} };
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };

    // `all` on every face, with an ore's overlay, untinted.
    const ore = (try describe(a, try Json.parse(a, "{ drawtype: 'cube', textures: { all: { base: 'block/stone/rock/{rock}1', overlays: [ 'block/stone/ore/gold1' ] } } }"), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:block/stone/rock/granite1", ore.east.plain.?.base);
    try std.testing.expectEqualStrings("game:block/stone/ore/gold1", ore.up.plain.?.overlays[0]);
    try std.testing.expectEqual(null, ore.south.tinted);

    // Its own name, then its group's, then `all`; no drawtype or shape is the game's cube.
    const log = (try describe(a, try Json.parse(a, "{ textures: { all: { base: 'a' }, verticals: { base: 'v' }, south: { base: 's' } } }"), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:v", log.up.plain.?.base);
    try std.testing.expectEqualStrings("game:s", log.south.plain.?.base);
    try std.testing.expectEqualStrings("game:a", log.east.plain.?.base);

    // Colour maps tint the whole face.
    const tinted = (try describe(a, try Json.parse(a, "{ drawtype: 'Cube', climateColorMap: 'climatePlantTint', textures: { all: { base: 'x' } } }"), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:x", tinted.up.tinted.?.base);
    try std.testing.expectEqual(null, tinted.up.plain);

    // Glacier ice's cube with its faces inset.
    const ice = (try describe(a, try Json.parse(a, "{ shape: { base: 'block/basic/cube-nozfight' }, textures: { all: { base: 'i' } } }"), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:i", ice.up.plain.?.base);

    // Grassy soil: soil under the grass's halves, the right on top and the left on the sides.
    const soil = (try describe(a, try Json.parse(a,
        \\{ drawtype: 'TopSoil', climateColorMap: 'climatePlantTint',
        \\  textures: { all: { base: 'block/soil/fertmedium' }, specialSecondTexture: { base: 'block/plant/grasscoverage/normal' } } }
    ), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:block/soil/fertmedium", soil.up.plain.?.base);
    try std.testing.expectEqual(.right, soil.up.tinted.?.half.?);
    try std.testing.expectEqual(.left, soil.east.tinted.?.half.?);
    try std.testing.expectEqualStrings("game:block/plant/grasscoverage/normal", soil.south.tinted.?.base);

    // Leaves: crossed planes up close, and at a distance a cube in their small leaves, here
    // its shape read before. Branchy leaves name their colour maps on the shape's cube.
    try shapes.cubes.put(a, "game:block/plant/leaves/normal-lod0", .{ .up = "smallleaves", .south = "smallleaves", .east = "smallleaves" });
    try shapes.cubes.put(a, "game:block/plant/leaves/branchy-lod0", .{ .up = "smallleaves", .south = "smallleaves", .east = "smallleaves", .seasonColorMap = "seasonalBirch" });
    const leaves = (try describe(a, try Json.parse(a,
        \\{ shape: { base: 'block/plant/leaves/normal' }, lod0Shape: { base: 'block/plant/leaves/normal-lod0' }, climateColorMap: 'climatePlantTint',
        \\  textures: { largeleaves: { base: 'large' }, smallleavesByType: { '*': { base: 'small/{rock}' } } } }
    ), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:small/granite", leaves.east.tinted.?.base);
    const branchy = try describe(a, try Json.parse(a, "{ shape: { base: 'block/plant/leaves/branchy' }, lod0Shape: { base: 'block/plant/leaves/branchy-lod0' }, textures: { smallleaves: { base: 'small' } } }"), rock, &shapes);
    try std.testing.expectEqualStrings("seasonalBirch", branchy.seasonColorMap.?);
    try std.testing.expectEqualStrings("game:small", branchy.cube.?.up.tinted.?.base);

    // Water: its `all` texture on every face, tinted, and not its second one.
    const water = (try describe(a, try Json.parse(a, "{ drawtype: 'liquid', climateColorMap: 'climateWaterTint', textures: { all: { base: 'block/liquid/water' }, specialSecondTexture: { base: 'block/liquid/water2' } } }"), rock, &shapes)).cube.?;
    try std.testing.expectEqualStrings("game:block/liquid/water", water.up.tinted.?.base);
    try std.testing.expectEqual(null, water.up.plain);

    // Not cubes: another shape, a turned cube, another drawtype.
    for ([_][]const u8{
        "{ shape: { base: 'block/wood/log/noresin1' }, textures: { all: { base: 'x' } } }",
        "{ shape: { base: 'game:block/basic/cube', rotateY: 90 }, textures: { all: { base: 'x' } } }",
        "{ drawtype: 'surfacelayer', textures: { all: { base: 'x' } } }",
    }) |json| try std.testing.expectEqual(null, (try describe(a, try Json.parse(a, json), rock, &shapes)).cube);
}

test "the shape a block is drawn in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const variant: Variant = .{ .code = .{ .domain = "game", .path = "step" }, .parts = &.{} };
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };
    // A step with a knob on it, its shape read before, and a leaf turned 45° beside it.
    try shapes.files.put(a, "game:block/test/step", try Json.parse(a,
        \\{ textures: { own: 'block/own' }, elements: [
        \\  { name: 'Base', from: [ 0, 0, 0 ], to: [ 16, 8, 16 ], faces: {
        \\      north: { texture: '#north', uv: [ 0, 0, 16, 8 ] },
        \\      up: { texture: '#up', uv: [ 0, 0, 16, 16 ], rotation: 180 },
        \\      down: { texture: '#down', uv: [ 0, 0, 16, 16 ], enabled: false } },
        \\    children: [ { name: 'Knob', from: [ 0, 8, 0 ], to: [ 4, 12, 4 ], faces: { east: { texture: '#own' } } } ] },
        \\  { name: 'Leaf', from: [ 8, 0, 8 ], to: [ 8, 16, 24 ], rotationOrigin: [ 8, 0, 8 ], rotationY: 45,
        \\    climateColorMap: 'climatePlantTint', faces: { west: { texture: '#missing' } } } ] }
    ));
    const textures = "textures: { horizontals: { base: 'side' }, up: { base: 'top' } }";
    const look = try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/step' }, " ++ textures ++ " }"), variant, &shapes);
    try std.testing.expectEqual(1, look.shapes.len);
    const shape = look.shapes[0];
    const boxes = shape.geometry.boxes;
    try std.testing.expectEqual(3, boxes.len);
    try std.testing.expectEqual(null, look.cube);

    // The base: half a block high, where its file has it. A face named after its side takes its
    // group's texture, and the corners of its UV rectangle go round the face, turned for `up`.
    try std.testing.expectEqual([3]f32{ 1, 0.5, 1 }, boxes[0].size);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 0 }, boxes[0].transform[0]);
    const north = boxes[0].faces[@backingInt(world.Shape.Side.north)].?;
    try std.testing.expectEqualStrings("game:side", shape.textures[north.texture].plain.?.base);
    try std.testing.expectEqual([4][2]f32{ .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0.5 } }, north.uv);
    const up = boxes[0].faces[@backingInt(world.Shape.Side.up)].?;
    try std.testing.expectEqualStrings("game:top", shape.textures[up.texture].plain.?.base);
    try std.testing.expectEqual([4][2]f32{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 } }, up.uv);
    try std.testing.expectEqual(null, boxes[0].faces[@backingInt(world.Shape.Side.down)]);

    // The knob, placed within the base, in the shape's own texture; without a UV rectangle, a
    // face takes as much of the texture as it's big.
    try std.testing.expectEqual([3]f32{ 0, 0.5, 0 }, .{ boxes[1].transform[0][3], boxes[1].transform[1][3], boxes[1].transform[2][3] });
    const east = boxes[1].faces[@backingInt(world.Shape.Side.east)].?;
    try std.testing.expectEqualStrings("game:block/own", shape.textures[east.texture].plain.?.base);
    try std.testing.expectEqual([4][2]f32{ .{ 0.25, 0.25 }, .{ 0.25, 0 }, .{ 0, 0 }, .{ 0, 0.25 } }, east.uv);

    // The leaf, turned about its origin; its colour map tints the block, and the texture it
    // names isn't there.
    try std.testing.expectApproxEqAbs(@sqrt(0.5), boxes[2].transform[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@sqrt(0.5), boxes[2].transform[0][2], 1e-6);
    try std.testing.expectEqual(0.5, boxes[2].transform[0][3]);
    try std.testing.expectEqualStrings("climatePlantTint", look.climateColorMap.?);
    const west = boxes[2].faces[@backingInt(world.Shape.Side.west)].?;
    try std.testing.expect(shape.geometry.textures[west.texture].tinted);
    try std.testing.expectEqual(Face{}, shape.textures[west.texture]);

    // Placed the same, blocks share the boxes; turned a quarter about the block's middle, its
    // corner at (0, 0, 0) goes to (0, 0, 1).
    const again = (try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/step' }, textures: { all: { base: 'x' } } }"), variant, &shapes)).shapes[0];
    try std.testing.expectEqual(shape.geometry, again.geometry);
    try std.testing.expectEqualStrings("game:x", again.textures[west.texture].tinted.?.base);
    const turned = (try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/step', rotateY: 90 }, " ++ textures ++ " }"), variant, &shapes)).shapes[0];
    try std.testing.expect(turned.geometry != shape.geometry);
    try std.testing.expectApproxEqAbs(0, turned.geometry.boxes[0].transform[0][3], 1e-6);
    try std.testing.expectApproxEqAbs(1, turned.geometry.boxes[0].transform[2][3], 1e-6);

    // `selectiveElements` picks elements by name, and with `/*` everything under them too.
    const picked = [_]struct { list: []const u8, boxes: usize }{
        .{ .list = "[ 'Base/*' ]", .boxes = 2 },
        .{ .list = "[ 'Knob' ]", .boxes = 1 },
        .{ .list = "[ 'Base', 'Leaf' ]", .boxes = 2 },
    };
    for (picked) |case| {
        const json = try std.fmt.allocPrint(a, "{{ shape: {{ base: 'block/test/step', selectiveElements: {s} }}, {s} }}", .{ case.list, textures });
        try std.testing.expectEqual(case.boxes, (try describe(a, try Json.parse(a, json), variant, &shapes)).shapes[0].geometry.boxes.len);
    }
}

test "the shapes a block picks from" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const variant: Variant = .{ .code = .{ .domain = "game", .path = "bush" }, .parts = &.{} };
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };
    // Two bushes, the second in a folder below, a third in another format, a pot, and a bush
    // in another domain.
    shapes.listed = &.{
        .{ .domain = "game", .path = "shapes/block/test/bush1.json" },
        .{ .domain = "game", .path = "shapes/block/test/bush2/tall.json" },
        .{ .domain = "game", .path = "shapes/block/test/bush3.obj" },
        .{ .domain = "game", .path = "shapes/block/test/pot.json" },
        .{ .domain = "mod", .path = "shapes/block/test/bush4.json" },
    };
    const cube = "{ elements: [ { name: 'Leaf', from: [ 0, 0, 0 ], to: [ 16, 16, 16 ], faces: { up: { texture: '#all' } } } ] }";
    for ([_][]const u8{ "game:block/test/bush1", "game:block/test/bush2/tall", "game:block/test/pot", "game:block/basic/cube" }) |location| {
        try shapes.files.put(a, location, try Json.parse(a, cube));
    }

    // The bush's own shape first, then its other files, then each alternate: one taking the
    // bush's base, and all its files, one of its own, and one standing for no file at all.
    const composite = try Json.parse(a,
        \\{ base: 'block/test/bush*', rotateY: 90, offsetX: 0.5, selectiveElements: [ 'Leaf' ],
        \\  overlays: [ { base: 'block/test/pot' } ],
        \\  alternates: [ { rotateY: 180 }, { base: 'block/test/pot', selectiveElements: [] }, { base: 'block/test/none*' } ] }
    );
    const list = try shapes.resolve(composite, "game");
    const expected = [_]struct { base: []const u8, rotateY: f32, offsetX: f32, overlaid: bool, selective: usize }{
        .{ .base = "game:block/test/bush1", .rotateY = 90, .offsetX = 0.5, .overlaid = true, .selective = 1 },
        .{ .base = "game:block/test/bush2/tall", .rotateY = 90, .offsetX = 0, .overlaid = false, .selective = 1 },
        .{ .base = "game:block/test/bush3", .rotateY = 90, .offsetX = 0, .overlaid = false, .selective = 1 },
        .{ .base = "game:block/test/bush1", .rotateY = 180, .offsetX = 0, .overlaid = false, .selective = 1 },
        .{ .base = "game:block/test/bush2/tall", .rotateY = 180, .offsetX = 0, .overlaid = false, .selective = 1 },
        .{ .base = "game:block/test/bush3", .rotateY = 180, .offsetX = 0, .overlaid = false, .selective = 1 },
        .{ .base = "block/test/pot", .rotateY = 0, .offsetX = 0, .overlaid = false, .selective = 0 },
    };
    try std.testing.expectEqual(expected.len, list.len);
    for (expected, list) |want, shape| {
        try std.testing.expectEqualStrings(want.base, shape.get("base").?.asString().?);
        try std.testing.expectEqual(want.rotateY, number(shape.get("rotateY"), 0));
        try std.testing.expectEqual(want.offsetX, number(shape.get("offsetX"), 0));
        try std.testing.expectEqual(want.overlaid, shape.get("overlays") != null);
        try std.testing.expectEqual(want.selective, shape.getArray("selectiveElements").len);
    }

    // Each is drawn: the bush and its overlaid pot, then the second bush alone, the third, with
    // no JSON file, as nothing, and the pot.
    const look = try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/bush*', overlays: [ { base: 'block/test/pot' } ], alternates: [ { base: 'block/test/pot' } ] }, textures: { all: { base: 'leaf' } } }"), variant, &shapes);
    try std.testing.expectEqual(4, look.shapes.len);
    try std.testing.expectEqual(2, look.shapes[0].geometry.boxes.len);
    try std.testing.expectEqual(1, look.shapes[1].geometry.boxes.len);
    try std.testing.expectEqual(0, look.shapes[2].geometry.boxes.len);
    try std.testing.expectEqualStrings("game:leaf", look.shapes[3].textures[0].plain.?.base);

    // A base standing for no file is the plain cube; an alternate with nothing to draw keeps its
    // place, and a block none of whose shapes has anything to draw has none.
    const none = try shapes.resolve(try Json.parse(a, "{ base: 'block/test/none*', rotateY: 90 }"), "game");
    try std.testing.expectEqual(1, none.len);
    try std.testing.expectEqualStrings("game:block/basic/cube", none[0].get("base").?.asString().?);
    try std.testing.expectEqual(90, number(none[0].get("rotateY"), 0));
    const hollow = try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/pot', alternates: [ { base: 'block/test/missing' } ] }, textures: { all: { base: 'leaf' } } }"), variant, &shapes);
    try std.testing.expectEqual(2, hollow.shapes.len);
    try std.testing.expectEqual(0, hollow.shapes[1].geometry.boxes.len);
    const empty = try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/missing' }, textures: { all: { base: 'leaf' } } }"), variant, &shapes);
    try std.testing.expectEqual(0, empty.shapes.len);

    // A block type naming no colour maps takes those of the first of its shapes naming any.
    try shapes.files.put(a, "game:block/test/fern", try Json.parse(a, "{ elements: [ { from: [ 0, 0, 0 ], to: [ 16, 16, 0 ], climateColorMap: 'climatePlantTint', faces: { north: { texture: '#all' } } } ] }"));
    const fern = try describe(a, try Json.parse(a, "{ shape: { base: 'block/test/missing', alternates: [ { base: 'block/test/pot' }, { base: 'block/test/fern' } ] }, textures: { all: { base: 'leaf' } } }"), variant, &shapes);
    try std.testing.expectEqualStrings("climatePlantTint", fern.climateColorMap.?);
}

test "how high a block's selection box reaches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const variant: Variant = .{ .code = .{ .domain = "game", .path = "loosestones-granite-free" }, .parts = &.{} };
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };
    const cases = [_]struct { json: []const u8, height: ?u8 }{
        .{ .json = "{ selectionBox: { x1: 0.0625, y1: 0, z1: 0.0625, x2: 0.9375, y2: 0.125, z2: 0.9375 } }", .height = 2 },
        .{ .json = "{ collisionSelectionBox: { x1: 0, y1: 0, z1: 0, x2: 1, y2: 0.25, z2: 1 } }", .height = 4 },
        .{ .json = "{ selectionboxByType: { '*-free': { x1: 0, y1: 0, z1: 0, x2: 1, y2: 0.5, z2: 1 } } }", .height = 8 },
        .{ .json = "{ code: 'rock' }", .height = null },
    };
    for (cases) |case| try std.testing.expectEqual(case.height, (try describe(a, try Json.parse(a, case.json), variant, &shapes)).height);
}

test "how a block is placed by where it is" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const variant: Variant = .{ .code = .{ .domain = "game", .path = "tallgrass-tall" }, .parts = &.{} };
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };
    const cases = [_]struct { json: []const u8, offset: u8, axes: Axes, turned: bool }{
        .{ .json = "{ randomDrawOffset: true, randomizeAxes: 'xz', randomizeRotations: true }", .offset = 1, .axes = .xz, .turned = true },
        .{ .json = "{ RandomDrawOffset: 14, randomizeAxes: 'XZ' }", .offset = 14, .axes = .xz, .turned = false },
        .{ .json = "{ randomDrawOffsetByType: { '*-tall': false }, randomizeRotations: false }", .offset = 0, .axes = .xyz, .turned = false },
        .{ .json = "{ code: 'rock' }", .offset = 0, .axes = .xyz, .turned = false },
    };
    for (cases) |case| {
        const look = try describe(a, try Json.parse(a, case.json), variant, &shapes);
        try std.testing.expectEqual(case.offset, look.drawOffset);
        try std.testing.expectEqual(case.axes, look.randomizeAxes);
        try std.testing.expectEqual(case.turned, look.randomizeRotations);
    }
}

test "the colour maps that tint a block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try Json.parse(a,
        \\{ climateColorMapByType: { "*-none": null, "*": "climatePlantTint" },
        \\  seasonColorMapByType: { "*-none": null, "*": "seasonalGrass" } }
    );
    var shapes: Shapes = .{ .arena = a, .io = undefined, .assets = null };
    const grassy = try describe(a, json, .{ .code = .{ .domain = "game", .path = "soil-low-normal" }, .parts = &.{} }, &shapes);
    try std.testing.expectEqualStrings("climatePlantTint", grassy.climateColorMap.?);
    try std.testing.expectEqualStrings("seasonalGrass", grassy.seasonColorMap.?);
    const bare = try describe(a, json, .{ .code = .{ .domain = "game", .path = "soil-low-none" }, .parts = &.{} }, &shapes);
    try std.testing.expectEqual(null, bare.climateColorMap);
    try std.testing.expectEqual(null, bare.seasonColorMap);
}
