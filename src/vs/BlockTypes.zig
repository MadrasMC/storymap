//! The block types in the game's and mods' `blocktypes/`, expanded into one code per variant as
//! the game does it (docs/rendering.md#block-codes).
const std = @import("std");
const Io = std.Io;
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
};

/// A cube's top, south and east faces: those seen looking north-west from above.
pub const Cube = struct {
    up: Face,
    south: Face,
    east: Face,
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

    var blocks: std.ArrayList(Block) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try assets.list(arena, io, "blocktypes")) |name| {
        if (!std.mem.endsWith(u8, name.path, ".json")) continue;
        const blockType = expander.blockType(name) catch |err| {
            std.debug.print("storymap: skipped block type {s}:{s}: could not read ({s})\n", .{ name.domain, name.path, @errorName(err) });
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
            const look = describe(arena, blockType.json, variant) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => look: {
                    // As in the game, a variant whose …ByType properties can't be resolved
                    // keeps the defaults.
                    if (!warned) std.debug.print("storymap: {s}:{s}: could not resolve its …ByType properties ({s})\n", .{ name.domain, name.path, @errorName(err) });
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
};

/// A variant's `Look`, from its block type's properties with their `…ByType` forms resolved.
fn describe(arena: std.mem.Allocator, json: Json.Value, variant: Variant) !Look {
    const materialValue = try property(arena, json, "blockmaterial", variant);
    const material = canonicalMaterial(if (materialValue) |m| m.asString() orelse defaultMaterial else defaultMaterial);
    const attributes = try property(arena, json, "attributes", variant);
    const colorCode = if (attributes) |a| if (a.get("mapColorCode")) |c| c.asString() else null else null;
    // A …ByType may set one to null, for variants without.
    const climateColorMap = if (try property(arena, json, "climateColorMap", variant)) |c| c.asString() else null;
    const seasonColorMap = if (try property(arena, json, "seasonColorMap", variant)) |c| c.asString() else null;

    var textures: Textures = .{};
    var cube: ?Cube = null;
    if (try property(arena, json, "textures", variant)) |all| if (all == .object and all.object.len > 0) {
        const forColour = if (attributes) |a| if (a.get("textureCodeForBlockColor")) |c| c.asString() else null else null;
        const forGrain = if (try property(arena, json, "particlesTextureCode", variant)) |c| c.asString() else null;
        textures = .{
            .colour = try textureLocation(arena, pickTexture(all.object, forColour), variant.code.domain),
            .grain = try textureLocation(arena, pickTexture(all.object, forGrain), variant.code.domain),
        };
        const tinted = climateColorMap != null or seasonColorMap != null;
        cube = try cubeOf(arena, all.object, try drawingOf(arena, json, variant), tinted, variant.code.domain);
    };
    return .{
        .material = material,
        .colorCode = colorCode orelse defaultColorCode(material),
        .textures = textures,
        .climateColorMap = climateColorMap,
        .seasonColorMap = seasonColorMap,
        .cube = cube,
    };
}

/// How the game draws a block, as far as the isometric view tells them apart.
const Drawing = enum {
    /// A plain cube, each face its own texture.
    cube,
    /// Grassy soil (`TopSoil`): a cube of soil, with grass over its top and the top of its sides.
    topSoil,
    other,
};

/// From its `drawtype`, which is `json` without one: a JSON block whose shape is the game's
/// default, the plain cube, unturned, is drawn as a cube too (vsapi `Block.DrawType`,
/// `Block.DefaultCubeShape`).
fn drawingOf(arena: std.mem.Allocator, json: Json.Value, variant: Variant) !Drawing {
    const drawtype = if (try property(arena, json, "drawtype", variant)) |d| d.asString() orelse "json" else "json";
    if (std.ascii.eqlIgnoreCase(drawtype, "cube")) return .cube;
    if (std.ascii.eqlIgnoreCase(drawtype, "topsoil")) return .topSoil;
    if (!std.ascii.eqlIgnoreCase(drawtype, "json")) return .other;
    const shape = try property(arena, json, "shape", variant) orelse return .cube;
    const base = (shape.get("base") orelse return .other).asString() orelse return .other;
    const location: Location = try .parse(arena, base, Assets.gameDomain);
    // `cube-nozfight`, for glacier ice, insets each pair of faces by 0.006 of a pixel.
    const cubes = [_][]const u8{ "block/basic/cube", "block/basic/cube-nozfight" };
    for (cubes) |cube| {
        if (std.mem.eql(u8, location.path, cube)) break;
    } else return .other;
    for ([_][]const u8{ "rotateX", "rotateY", "rotateZ" }) |axis| {
        const angle = shape.get(axis) orelse continue;
        if (angle != .number or (std.fmt.parseFloat(f64, angle.number) catch 1) != 0) return .other;
    }
    return .cube;
}

/// A cube's faces from its block's textures, or null if it isn't drawn as one or a face has
/// no texture. A face takes the texture named for it, else its group's, else `all`. A block with
/// colour maps has every face tinted, except grassy soil, which tints only its grass, the
/// right half of its `specialSecondTexture` on top and the left half on the sides.
fn cubeOf(arena: std.mem.Allocator, textures: []const Json.Field, drawing: Drawing, tinted: bool, domain: []const u8) !?Cube {
    if (drawing == .other) return null;
    const up = try layerOf(arena, findTexture(textures, &.{ "up", "verticals", "all" }), domain) orelse return null;
    const south = try layerOf(arena, findTexture(textures, &.{ "south", "horizontals", "all" }), domain) orelse return null;
    const east = try layerOf(arena, findTexture(textures, &.{ "east", "horizontals", "all" }), domain) orelse return null;
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
                    std.debug.print("storymap: {s}:{s}: unknown world property {s}\n", .{ name.domain, name.path, key });
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
        std.debug.print("storymap: {s}:{s}: could not read variant pattern {s} ({s})\n", .{ name.domain, name.path, pattern.path, @errorName(err) });
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
    for (cases) |case| {
        const look = try describe(a, try Json.parse(a, case.json), variant);
        try std.testing.expectEqualDeep(case.colour, look.textures.colour);
        try std.testing.expectEqualDeep(case.grain, look.textures.grain);
    }
}

test "the cube a block is drawn as" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rock: Variant = .{ .code = .{ .domain = "game", .path = "rock-granite" }, .parts = &.{.{ .group = "rock", .state = "granite" }} };

    // `all` on every face, with an ore's overlay, untinted.
    const ore = (try describe(a, try Json.parse(a, "{ drawtype: 'cube', textures: { all: { base: 'block/stone/rock/{rock}1', overlays: [ 'block/stone/ore/gold1' ] } } }"), rock)).cube.?;
    try std.testing.expectEqualStrings("game:block/stone/rock/granite1", ore.east.plain.?.base);
    try std.testing.expectEqualStrings("game:block/stone/ore/gold1", ore.up.plain.?.overlays[0]);
    try std.testing.expectEqual(null, ore.south.tinted);

    // Its own name, then its group's, then `all`; no drawtype or shape is the game's cube.
    const log = (try describe(a, try Json.parse(a, "{ textures: { all: { base: 'a' }, verticals: { base: 'v' }, south: { base: 's' } } }"), rock)).cube.?;
    try std.testing.expectEqualStrings("game:v", log.up.plain.?.base);
    try std.testing.expectEqualStrings("game:s", log.south.plain.?.base);
    try std.testing.expectEqualStrings("game:a", log.east.plain.?.base);

    // Colour maps tint the whole face.
    const tinted = (try describe(a, try Json.parse(a, "{ drawtype: 'Cube', climateColorMap: 'climatePlantTint', textures: { all: { base: 'x' } } }"), rock)).cube.?;
    try std.testing.expectEqualStrings("game:x", tinted.up.tinted.?.base);
    try std.testing.expectEqual(null, tinted.up.plain);

    // Glacier ice's cube with its faces inset.
    const ice = (try describe(a, try Json.parse(a, "{ shape: { base: 'block/basic/cube-nozfight' }, textures: { all: { base: 'i' } } }"), rock)).cube.?;
    try std.testing.expectEqualStrings("game:i", ice.up.plain.?.base);

    // Grassy soil: soil under the grass's halves, the right on top and the left on the sides.
    const soil = (try describe(a, try Json.parse(a,
        \\{ drawtype: 'TopSoil', climateColorMap: 'climatePlantTint',
        \\  textures: { all: { base: 'block/soil/fertmedium' }, specialSecondTexture: { base: 'block/plant/grasscoverage/normal' } } }
    ), rock)).cube.?;
    try std.testing.expectEqualStrings("game:block/soil/fertmedium", soil.up.plain.?.base);
    try std.testing.expectEqual(.right, soil.up.tinted.?.half.?);
    try std.testing.expectEqual(.left, soil.east.tinted.?.half.?);
    try std.testing.expectEqualStrings("game:block/plant/grasscoverage/normal", soil.south.tinted.?.base);

    // Not cubes: another shape, a turned cube, another drawtype.
    for ([_][]const u8{
        "{ shape: { base: 'block/wood/log/noresin1' }, textures: { all: { base: 'x' } } }",
        "{ shape: { base: 'game:block/basic/cube', rotateY: 90 }, textures: { all: { base: 'x' } } }",
        "{ drawtype: 'liquid', textures: { all: { base: 'x' } } }",
    }) |json| try std.testing.expectEqual(null, (try describe(a, try Json.parse(a, json), rock)).cube);
}

test "the colour maps that tint a block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try Json.parse(a,
        \\{ climateColorMapByType: { "*-none": null, "*": "climatePlantTint" },
        \\  seasonColorMapByType: { "*-none": null, "*": "seasonalGrass" } }
    );
    const grassy = try describe(a, json, .{ .code = .{ .domain = "game", .path = "soil-low-normal" }, .parts = &.{} });
    try std.testing.expectEqualStrings("climatePlantTint", grassy.climateColorMap.?);
    try std.testing.expectEqualStrings("seasonalGrass", grassy.seasonColorMap.?);
    const bare = try describe(a, json, .{ .code = .{ .domain = "game", .path = "soil-low-none" }, .parts = &.{} });
    try std.testing.expectEqual(null, bare.climateColorMap);
    try std.testing.expectEqual(null, bare.seasonColorMap);
}
