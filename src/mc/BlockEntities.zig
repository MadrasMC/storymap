//! Blocks the game draws in code rather than from a model, as it does a chest: their shapes, as
//! boxes whose faces are laid out on one texture the way the game's entity models are ("box
//! UV"). Their blockstate files name no properties, so each state is named by those its shape
//! goes by, which Storymap adds in `{}` (`Prepared.find`), e.g.
//! `minecraft:chest{facing=north,type=single}`.
const std = @import("std");
const world = @import("world");
const Models = @import("Models.zig");
const Side = world.Shape.Side;

pub const State = struct {
    /// The properties it's named by, in name order, as they follow its block's name in `{}`,
    /// e.g. "facing=north,type=single".
    properties: []const u8,
    shape: Models.Shape,
};

/// A box of an entity model, in sixteenths of a block, x east, y up and z south.
const Box = struct {
    from: [3]f32,
    size: [3]f32,
    /// Where its faces start on the texture, in pixels: its top left corner.
    texture: [2]f32,
    /// The sides it doesn't show: where another block's box joins it, or another of its own
    /// boxes always covers it.
    hidden: []const Side = &.{},
};

/// The entity textures' width and height, in pixels.
const textureSize = 64;

/// Where a corner of a box's side is on the texture, from 0 to 1 across and down; `corner` is
/// the corner's place in the box, 0 or 1 along each axis. A box d deep, w wide and h high has
/// its bottom and top side by side, each w × d, d pixels in from the left, above a strip of its
/// sides h high: west, north, east and south. The sides are upside down on the texture.
fn uvOf(box: Box, side: Side, corner: [3]f32) [2]f32 {
    const w, const h, const d = box.size;
    const x, const y, const z = corner;
    const north = box.texture[0] + d;
    const east = north + w;
    const sides = box.texture[1] + d;
    const at: [2]f32 = switch (side) {
        .down => .{ north + x * w, sides - z * d },
        .up => .{ east + x * w, sides - z * d },
        .west => .{ north - z * d, sides + y * h },
        .north => .{ north + x * w, sides + y * h },
        .east => .{ east + z * d, sides + y * h },
        .south => .{ east + d + w - x * w, sides + y * h },
    };
    return .{ at[0] / textureSize, at[1] / textureSize };
}

/// `box` placed in its block, turned `turns` quarters about the block's middle, clockwise seen
/// from above, each face in texture 0.
fn placed(box: Box, turns: u2) world.Shape.Box {
    var result: world.Shape.Box = .{
        .transform = Models.multiply(Models.blockTurn(0, turns), Models.translation(.{ box.from[0] / 16, box.from[1] / 16, box.from[2] / 16 })),
        .size = .{ box.size[0] / 16, box.size[1] / 16, box.size[2] / 16 },
        .shade = true,
        .faces = @splat(null),
    };
    for (std.enums.values(Side)) |side| {
        if (std.mem.indexOfScalar(Side, box.hidden, side) != null) continue;
        var uv: [4][2]f32 = undefined;
        for (&uv, side.corners()) |*at, corner| at.* = uvOf(box, side, corner);
        result.faces[@backingInt(side)] = .{ .texture = 0, .uv = uv };
    }
    return result;
}

/// How many quarters a model that faces south is turned, clockwise seen from above, to face
/// each way, by `facings`.
const facings = [_][]const u8{ "east", "north", "south", "west" };
const facingTurns = [facings.len]u2{ 3, 2, 0, 1 };

/// A chest's halves, by `type`, each with what its texture's name ends in.
const ChestHalf = struct { type: []const u8, suffix: []const u8, boxes: [3]Box };

/// A chest facing south: its bottom, its lid and its lock. The bottom's top and the lid's
/// bottom, inside a closed chest, aren't shown. A double chest's halves each reach the side where
/// they join, and don't show it.
const chestHalves = [_]ChestHalf{
    .{ .type = "left", .suffix = "_left", .boxes = .{
        .{ .from = .{ 0, 0, 1 }, .size = .{ 15, 10, 14 }, .texture = .{ 0, 19 }, .hidden = &.{ .west, .up } },
        .{ .from = .{ 0, 9, 1 }, .size = .{ 15, 5, 14 }, .texture = .{ 0, 0 }, .hidden = &.{ .west, .down } },
        .{ .from = .{ 0, 7, 15 }, .size = .{ 1, 4, 1 }, .texture = .{ 0, 0 }, .hidden = &.{.west} },
    } },
    .{ .type = "right", .suffix = "_right", .boxes = .{
        .{ .from = .{ 1, 0, 1 }, .size = .{ 15, 10, 14 }, .texture = .{ 0, 19 }, .hidden = &.{ .east, .up } },
        .{ .from = .{ 1, 9, 1 }, .size = .{ 15, 5, 14 }, .texture = .{ 0, 0 }, .hidden = &.{ .east, .down } },
        .{ .from = .{ 15, 7, 15 }, .size = .{ 1, 4, 1 }, .texture = .{ 0, 0 }, .hidden = &.{.east} },
    } },
    .{ .type = "single", .suffix = "", .boxes = .{
        .{ .from = .{ 1, 0, 1 }, .size = .{ 14, 10, 14 }, .texture = .{ 0, 19 }, .hidden = &.{.up} },
        .{ .from = .{ 1, 9, 1 }, .size = .{ 14, 5, 14 }, .texture = .{ 0, 0 }, .hidden = &.{.down} },
        .{ .from = .{ 7, 7, 15 }, .size = .{ 2, 4, 1 }, .texture = .{ 0, 0 } },
    } },
};
const singleChest = chestHalves.len - 1;

/// How high a chest reaches, in blocks.
const chestHeight = 14.0 / 16.0;

/// Each kind of chest, with its texture in `textures/entity/chest/`, and whether two join into a
/// double chest.
const Chest = struct { block: []const u8, texture: []const u8, doubles: bool = true };
const chests = [_]Chest{
    .{ .block = "chest", .texture = "normal" },
    .{ .block = "trapped_chest", .texture = "trapped" },
    .{ .block = "ender_chest", .texture = "ender", .doubles = false },
    .{ .block = "copper_chest", .texture = "copper" },
    .{ .block = "exposed_copper_chest", .texture = "copper_exposed" },
    .{ .block = "weathered_copper_chest", .texture = "copper_weathered" },
    .{ .block = "oxidized_copper_chest", .texture = "copper_oxidized" },
    .{ .block = "waxed_copper_chest", .texture = "copper" },
    .{ .block = "waxed_exposed_copper_chest", .texture = "copper_exposed" },
    .{ .block = "waxed_weathered_copper_chest", .texture = "copper_weathered" },
    .{ .block = "waxed_oxidized_copper_chest", .texture = "copper_oxidized" },
};

/// The states of block `short`, its name without `minecraft:`, if the game draws it in code,
/// kept in `arena`; null for any other block.
pub fn statesOf(arena: std.mem.Allocator, short: []const u8) !?[]const State {
    const chest = for (chests) |chest| {
        if (std.mem.eql(u8, chest.block, short)) break chest;
    } else return null;
    const halves: []const ChestHalf = if (chest.doubles) &chestHalves else chestHalves[singleChest..];
    var states: std.ArrayList(State) = .empty;
    for (facings, facingTurns) |facing, turns| for (halves) |half| {
        const boxes = try arena.alloc(world.Shape.Box, half.boxes.len);
        for (boxes, half.boxes) |*box, from| box.* = placed(from, turns);
        const textures = try arena.alloc(Models.Texture, 1);
        textures[0] = .{ .name = try std.fmt.allocPrint(arena, "minecraft:entity/chest/{s}{s}", .{ chest.texture, half.suffix }), .tinted = false };
        try states.append(arena, .{
            .properties = if (chest.doubles) try std.fmt.allocPrint(arena, "facing={s},type={s}", .{ facing, half.type }) else try std.fmt.allocPrint(arena, "facing={s}", .{facing}),
            .shape = .{ .boxes = boxes, .textures = textures, .top = 0, .height = chestHeight },
        });
    };
    return states.items;
}

fn expectUv(expected: [2]f32, actual: [2]f32) !void {
    try std.testing.expectApproxEqAbs(expected[0] / textureSize, actual[0], 1e-6);
    try std.testing.expectApproxEqAbs(expected[1] / textureSize, actual[1], 1e-6);
}

test uvOf {
    // A chest's bottom: 14 wide, 10 high and 14 deep, from (0, 19) on the texture.
    const box: Box = .{ .from = .{ 1, 0, 1 }, .size = .{ 14, 10, 14 }, .texture = .{ 0, 19 } };
    // The top is the second 14 × 14 square, its north edge at the bottom.
    try expectUv(.{ 28, 33 }, uvOf(box, .up, .{ 0, 1, 0 }));
    try expectUv(.{ 42, 19 }, uvOf(box, .up, .{ 1, 1, 1 }));
    // The south side is the last of the strip, its bottom edge at the top.
    try expectUv(.{ 56, 33 }, uvOf(box, .south, .{ 0, 0, 1 }));
    try expectUv(.{ 42, 43 }, uvOf(box, .south, .{ 1, 1, 1 }));
    try expectUv(.{ 0, 33 }, uvOf(box, .west, .{ 0, 0, 1 }));
}

test statesOf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, try statesOf(arena.allocator(), "stone"));
    const chest = (try statesOf(arena.allocator(), "chest")).?;
    try std.testing.expectEqual(12, chest.len);
    try std.testing.expectEqualStrings("facing=east,type=left", chest[0].properties);
    try std.testing.expectEqualStrings("minecraft:entity/chest/normal_left", chest[0].shape.textures[0].name);
    // A half doesn't show the side where it joins the other.
    try std.testing.expectEqual(null, chest[0].shape.boxes[0].faces[@backingInt(Side.west)]);
    const ender = (try statesOf(arena.allocator(), "ender_chest")).?;
    try std.testing.expectEqual(4, ender.len);
    try std.testing.expectEqualStrings("facing=north", ender[1].properties);
    // Facing north, the lock is on the north side: its corner at (7, 7, 15) is turned half way
    // round the block's middle.
    const lock = ender[1].shape.boxes[2];
    try std.testing.expectApproxEqAbs(@as(f32, 9.0 / 16.0), lock.transform[0][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0), lock.transform[2][3], 1e-6);
}
