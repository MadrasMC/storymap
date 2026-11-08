//! What a block's name, such as `minecraft:oak_leaves`, says about it: the game's assets don't
//! say what a block is on a map, or which blocks are liquids or air.
const std = @import("std");
const world = @import("world");

/// `name` without its namespace, if that's the game's, and without its properties.
pub fn shortName(name: []const u8) []const u8 {
    const prefix = "minecraft:";
    const short = if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else name;
    return short[0 .. std.mem.indexOfScalar(u8, short, '[') orelse short.len];
}

/// Water and lava, and a bubble column, which is water a player can't stand in.
pub fn isLiquid(short: []const u8) bool {
    return isWater(short) or std.mem.eql(u8, short, "lava");
}

pub fn isWater(short: []const u8) bool {
    return std.mem.eql(u8, short, "water") or std.mem.eql(u8, short, "bubble_column");
}

/// Plants that grow only under water, and stand in it without a `waterlogged` property.
pub fn isInWater(short: []const u8) bool {
    for ([_][]const u8{ "seagrass", "tall_seagrass", "kelp", "kelp_plant" }) |plant| {
        if (std.mem.eql(u8, short, plant)) return true;
    }
    return false;
}

pub fn isAir(short: []const u8) bool {
    return std.mem.eql(u8, short, "air") or std.mem.eql(u8, short, "cave_air") or std.mem.eql(u8, short, "void_air");
}

/// What a block is on a map, from its short name.
pub fn mapTypeOf(short: []const u8) world.MapType {
    const has = struct {
        fn any(text: []const u8, parts: []const []const u8) bool {
            for (parts) |part| if (std.mem.indexOf(u8, text, part) != null) return true;
            return false;
        }
    }.any;
    if (std.mem.eql(u8, short, "water")) return .lake;
    if (std.mem.eql(u8, short, "lava")) return .lava;
    if (has(short, &.{ "seagrass", "kelp" })) return .lake;
    if (has(short, &.{ "ice", "snow" })) return .glacier;
    if (has(short, &.{ "leaves", "_log", "_wood", "mangrove_roots" })) return .forest;
    if (has(short, &.{ "sand", "terracotta" })) return .desert;
    if (has(short, &.{ "short_grass", "tall_grass", "fern", "bush", "flower", "tulip", "poppy", "dandelion", "orchid", "allium", "bluet", "daisy", "cornflower", "lily", "vine", "sugar_cane", "bamboo", "cactus", "mushroom", "wheat", "carrots", "potatoes", "beetroots", "melon", "pumpkin" })) return .plant;
    if (has(short, &.{"dirt_path"})) return .road;
    if (has(short, &.{ "planks", "bricks", "door", "fence", "stairs", "slab", "glass", "wool", "torch", "bed", "chest", "furnace", "crafting_table" })) return .settlement;
    return .land;
}

/// What a block's tinted faces are multiplied by: the colour its biome gives grass, leaves or
/// water, or one of its own.
pub const Tint = union(enum) {
    grass,
    foliage,
    water,
    fixed: world.Rgb,
};

/// What a block's tinted faces are multiplied by, from its short name; the game's assets don't
/// say.
pub fn tintOf(short: []const u8) Tint {
    if (std.mem.eql(u8, short, "birch_leaves")) return .{ .fixed = .{ 0x80, 0xA7, 0x55 } };
    if (std.mem.eql(u8, short, "spruce_leaves")) return .{ .fixed = .{ 0x61, 0x99, 0x61 } };
    if (std.mem.eql(u8, short, "mangrove_leaves")) return .{ .fixed = .{ 0x92, 0xC6, 0x48 } };
    if (std.mem.eql(u8, short, "lily_pad")) return .{ .fixed = .{ 0x20, 0x80, 0x30 } };
    // Its tint goes with its power, which its states aren't named by: half power.
    if (std.mem.eql(u8, short, "redstone_wire")) return .{ .fixed = .{ 0xB0, 0x00, 0x00 } };
    if (std.mem.indexOf(u8, short, "water") != null or std.mem.eql(u8, short, "bubble_column")) return .water;
    if (std.mem.indexOf(u8, short, "leaves") != null or std.mem.indexOf(u8, short, "vine") != null) return .foliage;
    return .grass;
}

test shortName {
    try std.testing.expectEqualStrings("grass_block", shortName("minecraft:grass_block[snowy=false]"));
    try std.testing.expectEqualStrings("stone", shortName("minecraft:stone"));
    try std.testing.expectEqualStrings("other:stone", shortName("other:stone"));
}

test mapTypeOf {
    try std.testing.expectEqual(world.MapType.lake, mapTypeOf("water"));
    try std.testing.expectEqual(world.MapType.forest, mapTypeOf("oak_leaves"));
    try std.testing.expectEqual(world.MapType.desert, mapTypeOf("red_sandstone"));
    try std.testing.expectEqual(world.MapType.land, mapTypeOf("stone"));
}
