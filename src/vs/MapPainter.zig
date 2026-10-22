//! Paints the game's map for a tile in one of the game's own styles (`MapStyle`), from what a
//! reader read for it, as vsessentialsmod's `ChunkMapLayer.GenerateChunkImage` draws it, in the
//! game's own colours (docs/rendering.md#how-the-game-draws-its-own-world-map). Each thread
//! drawing the map keeps one, with its shading.
const MapPainter = @This();

const std = @import("std");
const tiles = @import("tiles");
const world = @import("world");
const SaveFile = @import("SaveFile.zig");
const Tint = @import("Tint.zig");

const Rgb = world.Rgb;

style: MapStyle,
save: *const SaveFile,
/// The shading, a byte per pixel as the game keeps it, and a copy of it before blurring.
shade: []u8,
unblurred: []u8,

/// The game's own map styles, by the names a theme gives them after `game:`.
pub const MapStyle = enum {
    /// The world map: each column in its map type's colour, hill-shaded; lakes unshaded and
    /// edged in `wateredge`, and snow looked under.
    shaded,
    /// The colour-accurate world map (the world setting `colorAccurateWorldmap`): each column
    /// in its top block's texture colour, with grain, tinted by climate and season, and
    /// hill-shaded.
    coloured,

    /// What `game` alone means: the world map as players see it by default.
    pub const default: MapStyle = .shaded;
};

/// For drawing `save`'s world in `style`.
pub fn init(save: *const SaveFile, allocator: std.mem.Allocator, style: MapStyle) !MapPainter {
    const shade = try allocator.alloc(u8, tiles.size * tiles.size);
    errdefer allocator.free(shade);
    const unblurred = try allocator.alloc(u8, tiles.size * tiles.size);
    return .{ .style = style, .save = save, .shade = shade, .unblurred = unblurred };
}

pub fn deinit(self: MapPainter, allocator: std.mem.Allocator) void {
    allocator.free(self.unblurred);
    allocator.free(self.shade);
}

/// Paints the map of the tile `reader` just read, `surface`, into `pixels`. The reader must have
/// been made for this style. Columns without blocks are transparent.
pub fn paint(self: *MapPainter, reader: *const SaveFile.Reader, tile: tiles.Tile, surface: *const world.Surface, pixels: *tiles.Pixels) void {
    const palette = &SaveFile.palette;
    switch (self.style) {
        .shaded => self.paintShaded(reader, surface, palette, pixels),
        .coloured => self.paintColoured(reader, tile, surface, palette, pixels),
    }
    self.applyShading(pixels);
}

/// The world map: each column takes its type's colour; a column higher than its north-west,
/// west and north neighbours, as a whole, is lit, and one lower shaded, more for steeper slopes;
/// the shading is blurred within each chunk and multiplied in (`applyShading`). Lakes aren't
/// shaded, and are edged in `wateredge` where they meet anything else.
fn paintShaded(self: *MapPainter, reader: *const SaveFile.Reader, surface: *const world.Surface, palette: *const world.Palette, pixels: *tiles.Pixels) void {
    const save = self.save;
    const side = world.Surface.side;
    for (0..tiles.size) |py| for (0..tiles.size) |px| {
        const i = (py + 1) * side + px + 1;
        const p = py * tiles.size + px;
        self.shade[p] = 128;
        const here = surface.columnTop(i);
        const y = here.height() orelse {
            pixels[p] = tiles.transparent;
            continue;
        };
        var appearance = save.appearance(surface.shownBlock(i));
        // Under a cover such as snow, what's beneath shows, one block lower.
        var at = y;
        if (here == .land and appearance.cover and reader.under[i] != 0) {
            appearance = save.appearance(reader.under[i]);
            at = y - 1;
        }
        if (appearance.lake or (here == .liquid and !appearance.mapType.isLiquid())) {
            // An edge where any neighbour isn't lake at the same height. Next to a column that
            // isn't drawn, the game draws water, as it can't tell.
            const neighbours = [_]usize{ i - 1, i + 1, i - side, i + side };
            var surrounded = true;
            for (neighbours) |j| {
                if (surface.top[j] == null and surface.liquidTop[j] == null) {
                    surrounded = true;
                    break;
                }
                if (!lakeAt(save, surface, j, at)) surrounded = false;
            }
            const lakeType = if (appearance.mapType.isLiquid() or appearance.lake) appearance.mapType else .lake;
            pixels[p] = rgb(if (surrounded) palette.colours.get(lakeType) else palette.wateredge);
            continue;
        }
        pixels[p] = rgb(palette.colours.get(appearance.mapType));
        self.shade[p] = hillShade(surface, i, y);
    };
}

/// The colour-accurate world map: each column takes its top block's texture colour, with
/// grain, tinted as the reader read it, or its type's colour without a texture; every column
/// is shaded, lakes too, and nothing is looked under.
fn paintColoured(self: *MapPainter, reader: *const SaveFile.Reader, tile: tiles.Tile, surface: *const world.Surface, palette: *const world.Palette, pixels: *tiles.Pixels) void {
    const save = self.save;
    const side = world.Surface.side;
    for (0..tiles.size) |py| for (0..tiles.size) |px| {
        const i = (py + 1) * side + px + 1;
        const p = py * tiles.size + px;
        self.shade[p] = 128;
        const here = surface.columnTop(i);
        const y = here.height() orelse {
            pixels[p] = tiles.transparent;
            continue;
        };
        const appearance = save.appearance(surface.shownBlock(i));
        const x = tile.x * tiles.size + @as(i32, @intCast(px));
        const z = tile.y * tiles.size + @as(i32, @intCast(py));
        const tint = if (here == .liquid) reader.liquidTint[i] else reader.topTint[i];
        pixels[p] = rgb(textureColour(appearance, palette.colours.get(appearance.mapType), tint, x, y, z));
        self.shade[p] = hillShade(surface, i, y);
    };
}

/// Blurs the tile's shading within each chunk and multiplies it into the pixels that are
/// drawn, as the game does: the blurred shading in fifths, and the unblurred one's remainder.
fn applyShading(self: *MapPainter, pixels: *tiles.Pixels) void {
    @memcpy(self.unblurred, self.shade);
    var y: usize = 0;
    while (y < tiles.size) : (y += 32) {
        var x: usize = 0;
        while (x < tiles.size) : (x += 32) blurChunk(self.shade, x, y);
    }
    for (pixels, self.shade, self.unblurred) |*pixel, blurred, original| {
        if (pixel.* == tiles.transparent) continue;
        const coarse = @trunc((@as(f32, @floatFromInt(blurred)) / 128 - 1) * 5) / 5;
        const fine = @rem((@as(f32, @floatFromInt(original)) / 128 - 1) * 5, 1) / 5;
        pixel.* = multiply(pixel.*, coarse + fine + 1);
    }
}

/// Whether the block at height `y` in column `i`, which is drawn, is drawn as a lake.
fn lakeAt(save: *const SaveFile, surface: *const world.Surface, i: usize, y: u16) bool {
    if (surface.liquidTop[i]) |liquid| {
        // Liquid reaches down to `y` unless the solid block is in the way: below it is the
        // ground it stands on, above it something over it, like leaves.
        const solid = surface.top[i];
        if (liquid >= y and (solid == null or solid.? < y or solid.? > liquid)) return save.appearance(surface.liquidBlock[i]).lake;
    }
    if (surface.top[i]) |solid| if (solid == y) return save.appearance(surface.topBlock[i]).lake;
    return false;
}

/// -1, 0 or 1.
fn signOf(value: i32) i32 {
    return @as(i32, @intFromBool(value > 0)) - @intFromBool(value < 0);
}

/// How much higher a column at height `y` is than column `i`, or 0 if `i` isn't drawn.
fn rise(y: u16, surface: *const world.Surface, i: usize) i32 {
    const other = surface.columnTop(i).height() orelse return 0;
    return @as(i32, y) - other;
}

/// The hill shading for column `i` at height `y`, as a byte where 128 is level: a column higher
/// than its north-west, west and north neighbours, as a whole, is lit, and one lower shaded,
/// more for steeper slopes.
fn hillShade(surface: *const world.Surface, i: usize, y: u16) u8 {
    const side = world.Surface.side;
    const nw = rise(y, surface, i - side - 1);
    const w = rise(y, surface, i - 1);
    const n = rise(y, surface, i - side);
    const direction = signOf(nw) + signOf(w) + signOf(n);
    const steepness: f32 = @floatFromInt(@max(@abs(nw), @abs(w), @abs(n)));
    const light: f32 = if (direction > 0)
        1.08 + @min(0.5, steepness / 10) / 1.25
    else if (direction < 0)
        0.92 - @min(0.5, steepness / 10) / 1.25
    else
        1;
    return @intFromFloat(128 * light);
}

/// How much of a column's grain shows over its texture's average colour, as the game's world
/// setting `colorRandomizationWeight` has it by default.
const grainWeight: f32 = 0.6;

/// The colour of block `appearance` at (`x`, `y`, `z`) on the colour-accurate map: its texture's
/// average colour with one of its grain colours mixed in, picked by position with the game's
/// hash, so it stays put, each tinted by `tint`; or `fallback` without a texture.
fn textureColour(appearance: SaveFile.Appearance, fallback: Rgb, tint: Rgb, x: i32, y: u16, z: i32) Rgb {
    const average = tinted(appearance.colour orelse return fallback, tint);
    if (appearance.grain.len == 0) return average;
    const sample = tinted(appearance.grain[grainIndex(x, y, z, appearance.grain.len)], tint);
    var out: Rgb = undefined;
    // As `ColorUtil.ColorOverlay`, rounding down.
    for (&out, average, sample) |*channel, a, s| channel.* = @intFromFloat(@as(f32, @floatFromInt(a)) * (1 - grainWeight) + grainWeight * @as(f32, @floatFromInt(s)));
    return out;
}

/// `colour` multiplied by `tint`, each channel rounded down, as the game's
/// `ColorUtil.ColorMultiplyEach`.
fn tinted(colour: Rgb, tint: Rgb) Rgb {
    var out: Rgb = undefined;
    for (&out, colour, tint) |*channel, c, t| channel.* = @intCast(@as(u16, c) * t / 255);
    return out;
}

test textureColour {
    const grain = [_]Rgb{ .{ 0, 0, 0 }, .{ 200, 100, 50 } };
    const appearance: SaveFile.Appearance = .{ .mapType = .land, .colour = .{ 100, 100, 100 }, .grain = &grain };
    const colour = textureColour(appearance, .{ 1, 2, 3 }, Tint.none, 409, 111, -304);
    try std.testing.expect(std.meta.eql(colour, Rgb{ 40, 40, 40 }) or std.meta.eql(colour, Rgb{ 160, 100, 70 }));
    try std.testing.expectEqual(colour, textureColour(appearance, .{ 1, 2, 3 }, Tint.none, 409, 111, -304));
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, textureColour(.{ .mapType = .land }, .{ 1, 2, 3 }, .{ 0, 0, 0 }, 0, 0, 0));
    // Half green: the average and the grain are both tinted.
    const half = textureColour(appearance, .{ 1, 2, 3 }, .{ 0, 128, 0 }, 409, 111, -304);
    try std.testing.expect(std.meta.eql(half, Rgb{ 0, 20, 0 }) or std.meta.eql(half, Rgb{ 0, 50, 0 }));
}

/// The game's position hash (vsapi `GameMath.MurmurHash3`): MurmurHash3's mixing of the three
/// coordinates, with its seed.
fn murmurHash3(x: i32, y: i32, z: i32) u32 {
    const c1: u32 = 0xcc9e2d51;
    const c2: u32 = 0x1b873593;
    var h: u32 = 144;
    for ([_]i32{ x, y, z }) |value| {
        h ^= std.math.rotl(u32, @as(u32, @bitCast(value)) *% c1, 15) *% c2;
        h = std.math.rotl(u32, h, 13) *% 5 +% 0xe6546b64;
    }
    h ^= 3;
    h = (h ^ h >> 16) *% 0x85ebca6b;
    h = (h ^ h >> 13) *% 0xc2b2ae35;
    return h ^ h >> 16;
}

/// Which of `count` grain colours the column at (`x`, `y`, `z`) shows, as the game's
/// `GameMath.MurmurHash3Mod` picks it: the hash as a signed number, modulo `count`, from 0.
fn grainIndex(x: i32, y: i32, z: i32, count: usize) usize {
    return @intCast(@mod(@as(i32, @bitCast(murmurHash3(x, y, z))), @as(i32, @intCast(count))));
}

test grainIndex {
    // From a separate port of the game's code.
    try std.testing.expectEqual(0x744e1107, murmurHash3(1, 2, 3));
    try std.testing.expectEqual(0x3901e003, murmurHash3(409, 111, -304));
    try std.testing.expectEqual(15, grainIndex(409, 111, -304, 30));
    // A hash that's negative as a signed number.
    try std.testing.expectEqual(0x9d8b5138, murmurHash3(2, 0, 0));
    try std.testing.expectEqual(12, grainIndex(2, 0, 0, 30));
}

/// Each channel of `pixel` times `factor`, kept within 0 to 255 and rounded down, as the game's
/// `ColorUtil.ColorMultiply3Clamped` does.
fn multiply(pixel: u32, factor: f32) u32 {
    // Red, green, blue and alpha bytes in memory order (tiles.rgba).
    const channels = std.mem.asBytes(&pixel);
    var out: Rgb = undefined;
    for (&out, channels[0..3]) |*channel, value| {
        channel.* = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(value)) * factor, 0, 255));
    }
    return rgb(out);
}

/// Blurs the 32 × 32 shading of one chunk, at (`x0`, `y0`) in a tile, as the game's
/// `BlurTool.Blur(map, 32, 32, 2)` does: across, then down, each value the average of itself
/// and its neighbours on either side within the chunk, rounded down.
fn blurChunk(shade: []u8, x0: usize, y0: usize) void {
    var line: [32]u8 = undefined;
    for (0..32) |row| {
        for (0..32) |x| line[x] = shade[(y0 + row) * tiles.size + x0 + x];
        blurLine(&line);
        for (0..32) |x| shade[(y0 + row) * tiles.size + x0 + x] = line[x];
    }
    for (0..32) |column| {
        for (0..32) |y| line[y] = shade[(y0 + y) * tiles.size + x0 + column];
        blurLine(&line);
        for (0..32) |y| shade[(y0 + y) * tiles.size + x0 + column] = line[y];
    }
}

fn blurLine(line: *[32]u8) void {
    var blurred: [32]u8 = undefined;
    for (0..32) |i| {
        const from: usize = i -| 1;
        const to: usize = @min(i + 1, 31);
        var sum: u32 = 0;
        for (line[from .. to + 1]) |value| sum += value;
        blurred[i] = @intCast(sum / @as(u32, @intCast(to + 1 - from)));
    }
    line.* = blurred;
}

test blurLine {
    var line: [32]u8 = @splat(128);
    line[10] = 158;
    blurLine(&line);
    try std.testing.expectEqual(128, line[8]);
    try std.testing.expectEqual(138, line[9]);
    try std.testing.expectEqual(138, line[10]);
    try std.testing.expectEqual(138, line[11]);
    // At the ends, two values make the average.
    line = @splat(128);
    line[0] = 130;
    blurLine(&line);
    try std.testing.expectEqual(129, line[0]);
    try std.testing.expectEqual(128, line[1]);
}

/// An opaque pixel.
fn rgb(colour: Rgb) u32 {
    return tiles.rgba(colour[0], colour[1], colour[2], 0xFF);
}
