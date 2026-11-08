//! Minecraft's biomes' colours, from the client jar's biome files
//! (`data/minecraft/worldgen/biome/<biome>.json`): the colours grass, leaves and water take in
//! each. Grass and leaves take a biome's own colour where it gives one, or else the colour map's
//! (`textures/colormap/grass.png` and `foliage.png`) at its temperature and downfall.
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const Jar = @import("Jar.zig");
const Rgb = world.Rgb;
const Json = std.json.Value;

pub const Biome = struct {
    /// E.g. "minecraft:plains".
    name: []const u8,
    grass: Rgb,
    foliage: Rgb,
    water: Rgb,
};

/// The colours of a biome whose file can't be read, and of a block with no biome: plains'.
pub const plains: Biome = .{ .name = "minecraft:plains", .grass = .{ 0x91, 0xBD, 0x59 }, .foliage = .{ 0x77, 0xAB, 0x2F }, .water = .{ 0x3F, 0x76, 0xE4 } };

/// Swamp grass, which the game colours by noise between two colours: the one it shows most.
const swampGrass: Rgb = .{ 0x6A, 0x70, 0x39 };

/// Every biome in `jar`, in the order of their files' names, kept in `arena`; `grass` and
/// `foliage` are the colour maps, null where they can't be read. A biome file that can't be read
/// is left out, and named in `failed`.
pub fn read(arena: std.mem.Allocator, io: Io, jar: *const Jar, grass: ?*const world.Image, foliage: ?*const world.Image, failed: *std.ArrayList([]const u8)) ![]Biome {
    const folder = "worldgen/biome/";
    var paths: std.ArrayList([]const u8) = .empty;
    var keys = jar.data.keyIterator();
    while (keys.next()) |key| {
        if (std.mem.startsWith(u8, key.*, folder) and std.mem.endsWith(u8, key.*, ".json")) try paths.append(arena, key.*);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var biomes: std.ArrayList(Biome) = .empty;
    for (paths.items) |path| {
        const name = try std.fmt.allocPrint(arena, "minecraft:{s}", .{path[folder.len .. path.len - ".json".len]});
        const json = try jar.readData(arena, io, path) orelse unreachable;
        const biome = parse(name, json, arena, grass, foliage) orelse {
            try failed.append(arena, path);
            continue;
        };
        try biomes.append(arena, biome);
    }
    return biomes.items;
}

/// A biome's colours from its file `json`; null if it can't be read.
fn parse(name: []const u8, json: []const u8, arena: std.mem.Allocator, grassMap: ?*const world.Image, foliageMap: ?*const world.Image) ?Biome {
    const root = std.json.parseFromSliceLeaky(Json, arena, json, .{}) catch return null;
    if (root != .object) return null;
    const temperature = number(root.object.get("temperature")) orelse return null;
    const downfall = number(root.object.get("downfall")) orelse return null;
    const effects = if (root.object.get("effects")) |value| (if (value == .object) value.object else null) else null;
    const effect = struct {
        fn of(object: ?std.json.ObjectMap, key: []const u8) ?Json {
            return (object orelse return null).get(key);
        }
    }.of;
    var grass = colourOf(effect(effects, "grass_color")) orelse fromMap(grassMap, temperature, downfall) orelse plains.grass;
    if (effect(effects, "grass_color_modifier")) |modifier| {
        if (modifier == .string and std.mem.eql(u8, modifier.string, "swamp")) grass = swampGrass;
        if (modifier == .string and std.mem.eql(u8, modifier.string, "dark_forest")) grass = darkForest(grass);
    }
    return .{
        .name = name,
        .grass = grass,
        .foliage = colourOf(effect(effects, "foliage_color")) orelse fromMap(foliageMap, temperature, downfall) orelse plains.foliage,
        .water = colourOf(effect(effects, "water_color")) orelse plains.water,
    };
}

fn number(value: ?Json) ?f32 {
    return switch (value orelse return null) {
        .integer => |n| @floatFromInt(n),
        .float => |f| @floatCast(f),
        else => null,
    };
}

/// A colour written as `#rrggbb`, or as a number.
fn colourOf(value: ?Json) ?Rgb {
    const rgb: u24 = switch (value orelse return null) {
        .string => |text| if (text.len == 7 and text[0] == '#') std.fmt.parseInt(u24, text[1..], 16) catch return null else return null,
        .integer => |n| std.math.cast(u24, n) orelse return null,
        else => return null,
    };
    return .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) };
}

/// The colour map's pixel for a biome's climate: across from hot to cold, and down from wet to
/// dry, its downfall counting less the colder it is.
fn fromMap(map: ?*const world.Image, temperature: f32, downfall: f32) ?Rgb {
    const image = map orelse return null;
    const warmth = std.math.clamp(temperature, 0, 1);
    const wetness = std.math.clamp(downfall, 0, 1) * warmth;
    const x: usize = @intFromFloat((1 - warmth) * @as(f32, @floatFromInt(image.width - 1)));
    const y: usize = @intFromFloat((1 - wetness) * @as(f32, @floatFromInt(image.height - 1)));
    return image.pixels[y * image.width + x][0..3].*;
}

/// Dark forests' grass: halfway between the biome's and a dark green.
fn darkForest(grass: Rgb) Rgb {
    const dark: Rgb = .{ 0x28, 0x34, 0x0A };
    var result: Rgb = undefined;
    for (&result, grass, dark) |*channel, own, with| channel.* = @intCast(((@as(u16, own) & 0xFE) + with) >> 1);
    return result;
}

test fromMap {
    // Hot and wet at the top left, cold at the right, dry at the bottom.
    const pixels = [_][4]u8{ .{ 1, 0, 0, 255 }, .{ 2, 0, 0, 255 }, .{ 3, 0, 0, 255 }, .{ 4, 0, 0, 255 } };
    const map: world.Image = .{ .width = 2, .height = 2, .pixels = &pixels };
    try std.testing.expectEqual(Rgb{ 1, 0, 0 }, fromMap(&map, 1, 1).?);
    try std.testing.expectEqual(Rgb{ 3, 0, 0 }, fromMap(&map, 1, 0).?);
    // Cold: its downfall counts for nothing.
    try std.testing.expectEqual(Rgb{ 4, 0, 0 }, fromMap(&map, 0, 1).?);
    try std.testing.expectEqual(Rgb{ 1, 0, 0 }, fromMap(&map, 2, 3).?);
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const swamp = parse("minecraft:swamp",
        \\{"temperature": 0.8, "downfall": 0.9, "effects": {"foliage_color": "#6a7039", "grass_color_modifier": "swamp", "water_color": "#617b64"}}
    , arena.allocator(), null, null).?;
    try std.testing.expectEqual(swampGrass, swamp.grass);
    try std.testing.expectEqual(Rgb{ 0x6A, 0x70, 0x39 }, swamp.foliage);
    try std.testing.expectEqual(Rgb{ 0x61, 0x7B, 0x64 }, swamp.water);
    const forest = parse("minecraft:dark_forest",
        \\{"temperature": 0.7, "downfall": 0.8, "effects": {"grass_color": 8434768, "grass_color_modifier": "dark_forest", "water_color": "#3f76e4"}}
    , arena.allocator(), null, null).?;
    try std.testing.expectEqual(darkForest(.{ 0x80, 0xB4, 0x50 }), forest.grass);
    try std.testing.expectEqual(plains.foliage, forest.foliage);
    try std.testing.expectEqual(null, parse("minecraft:broken", "{\"downfall\": 1}", arena.allocator(), null, null));
}
