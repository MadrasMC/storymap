//! Storymap's relief colours, which every view draws with: ground by height, from ink below
//! sea level to pale above it, and liquids by depth.
const std = @import("std");
const world = @import("world");
const tiles = @import("tiles");
const Rgb = world.Rgb;

/// Water this deep or deeper takes the darkest colour.
pub const maxDepth = 16;
/// How much the deepest liquid darkens towards black, in 256ths: a faded wash when shallow,
/// as on an old map.
const deepening = 102;

/// `base` darkened for liquid `depth` blocks deep.
pub fn liquidColour(base: Rgb, depth: u16) u32 {
    const fraction = @as(usize, @min(depth, maxDepth)) * deepening / maxDepth;
    return rgb(mix(base, .{ 0, 0, 0 }, fraction));
}

const testPalette: world.Palette = .{ .colours = .initFill(.{ 0xE4, 0xD2, 0xA0 }), .ink = .{ 0x4A, 0x30, 0x1A }, .wateredge = .{ 0x5C, 0x46, 0x2E } };

test liquidColour {
    const lake = testPalette.colours.get(.lake);
    try std.testing.expectEqual(rgb(lake), liquidColour(lake, 0));
    try std.testing.expectEqual(liquidColour(lake, maxDepth), liquidColour(lake, 200));
    try std.testing.expect(liquidColour(lake, maxDepth) & 0xFF < rgb(lake) & 0xFF);
}

/// `from` blended towards `to` by `fraction` 256ths.
pub fn mix(from: [3]u8, to: [3]u8, fraction: usize) [3]u8 {
    var mixed: [3]u8 = undefined;
    for (&mixed, from, to) |*channel, a, b| {
        channel.* = @intCast((@as(usize, a) * (256 - fraction) + @as(usize, b) * fraction) / 256);
    }
    return mixed;
}

/// How much the highest ground pales towards white, in 256ths.
const paling = 154;

/// The surface heights ground colours are spread over. They depend only on the world, so every
/// tile is coloured the same way.
pub const Heights = struct {
    /// The darkest ground, all ink, and everything below it.
    low: u16,
    /// Sea level: each type's own colour.
    ground: u16,
    /// The palest ground, and everything above it.
    high: u16,

    /// In a default 256-block world: 70, 110 (sea level) and 174; test worlds' surfaces have a
    /// median of 112. The ends scale with world height, assuming taller worlds have taller terrain.
    pub fn of(heights: world.Heights) Heights {
        const height: u32 = heights.world;
        const sea: u32 = heights.sea;
        return .{
            .low = @intCast(sea -| height * 40 / 256),
            .ground = @intCast(sea),
            .high = @intCast(sea + height * 64 / 256),
        };
    }
};

test "Heights.of" {
    try std.testing.expectEqual(Heights{ .low = 70, .ground = 110, .high = 174 }, Heights.of(.{ .world = 256, .sea = 110 }));
}

/// `base` at sea level, darkening towards the palette's ink below and paling towards white
/// above. `slope` is how much higher the column is than its west and north neighbours together:
/// slopes facing the north-west light are brightened, others darkened, as on a hand-shaded map.
pub fn groundColour(palette: *const world.Palette, base: Rgb, y: u16, heights: Heights, slope: i32) u32 {
    const clamped = std.math.clamp(y, heights.low, heights.high);
    var channels = if (clamped <= heights.ground)
        mix(base, palette.ink, share(heights.ground - clamped, heights.ground - heights.low))
    else
        mix(base, .{ 255, 255, 255 }, share(clamped - heights.ground, heights.high - heights.ground) * paling / 256);
    // Light in 1/256ths: each block of slope changes the brightness by 1/16, up to ±3/8.
    const light: i32 = 256 + std.math.clamp(slope * 16, -96, 96);
    for (&channels) |*channel| {
        channel.* = @intCast(std.math.clamp(@divTrunc(@as(i32, channel.*) * light, 256), 0, 255));
    }
    return rgb(channels);
}

/// `offset` out of `span`, in 256ths.
fn share(offset: u16, span: u16) usize {
    if (span == 0) return 256;
    return @as(usize, offset) * 256 / span;
}

pub fn rgb(colour: Rgb) u32 {
    return tiles.rgba(colour[0], colour[1], colour[2], 0xFF);
}

test groundColour {
    const palette = &testPalette;
    const land = palette.colours.get(.land);
    const heights: Heights = .{ .low = 10, .ground = 60, .high = 110 };
    // Level ground: ink at the low end, its own colour at sea level, pale at the high end.
    try std.testing.expectEqual(rgb(palette.ink), groundColour(palette, land, 10, heights, 0));
    try std.testing.expectEqual(rgb(land), groundColour(palette, land, 60, heights, 0));
    try std.testing.expectEqual(groundColour(palette, land, 110, heights, 0), groundColour(palette, land, 200, heights, 0));
    try std.testing.expect(groundColour(palette, land, 110, heights, 0) & 0xFF > rgb(land) & 0xFF);
    // A slope facing the light is brighter, one facing away darker.
    const level = groundColour(palette, land, 40, heights, 0);
    try std.testing.expect(groundColour(palette, land, 40, heights, 2) & 0xFF > level & 0xFF);
    try std.testing.expect(groundColour(palette, land, 40, heights, -2) & 0xFF < level & 0xFF);
}
