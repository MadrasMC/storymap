//! The isometric view, looking north-west from above: every block drawn as a cube, its top,
//! south and east faces lit differently. In the `relief` style each is in its map type's relief
//! colour (`relief.zig`); in the `game` style, a block the game draws as a cube is in its
//! textures (`Picture`), one the game draws in another shape is in that shape (`shapePicture`),
//! and any other in its texture's average colour, each tinted by the climate where it is, as the
//! game tints grass, leaves and water. Otherwise, plants aren't drawn, nor low blocks, such as
//! loose stones, which a whole cube would make look much larger than they are.
//!
//! Each tile follows its lines of sight (`Line`) from the top of the world, and draws the first
//! block each meets, as Mapcrafter does, and past it those behind it while one leaves parts of
//! its square empty, as a plant or a fence does. A chunk is read only when a line enters it, and
//! each worker keeps the chunks it has read (`ChunkCache`), so chunks hidden underground are
//! never read.
//!
//! A `Source` is a game's save, opened for reading, with:
//! - `chunkColumns: []const world.ChunkColumn`, those that may have blocks;
//! - `heights() world.Heights`;
//! - `blockCount() usize`, `mapType(id: i32) world.MapType`, `isVisible(id: i32) bool` and
//!   `isLow(id: i32) bool`, a block taking up only the bottom of its place;
//! - for the `game` style, `colour(id: i32) world.Rgb`, `cubeFaces(id: i32) ?*const
//!   world.CubeFaces`, `shape(id: i32) ?*const world.Shape`, `isTinted(id: i32) bool`, and
//!   `variant(x: i64, y: i64, z: i64, count: u32) u32`, which of a texture's `count` variants
//!   the block at (x, y, z) shows;
//! - `Reader`, one per thread: `init(source: *const Source, allocator, null) !Reader`,
//!   `deinit(*Reader, allocator)`, `readChunk(*Reader, x: i32, y: i32, z: i32, chunk:
//!   *world.Chunk) !bool`, false where there's no chunk to draw, and `chunksRead: usize`; for
//!   the `game` style, `tint(*Reader, id: i32, x: i64, y: i64, z: i64) !world.Rgb`, the colour
//!   multiplied into a tinted block's colour, or its faces' tinted layers, where it is.
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const tiles = @import("tiles");
const Style = @import("theme").Style;
const relief = @import("relief.zig");
const rasterizer = @import("rasterizer.zig");

pub const folder = "isometric";
pub const title = "Isometric";
/// Level-0 pixels from blocks: a block at (x, y, z) is drawn in the `blockWidth`-pixel square
/// from ((x − z − 1) · `blockWidth` / 2, (x + z) · `blockWidth` / 4 − (y + 1) · `blockWidth` / 2).
pub const projection = "isometric";

/// A block's width in level-0 pixels. Its top is a diamond this wide and half as tall, over
/// sides half as tall again, so it fills a square this size.
pub const blockWidth = 32;
/// How far a block east or west is across the screen, and how far a block east or south is
/// down it, or a block below.
const across = blockWidth / 2;
const down = blockWidth / 4;
const below = blockWidth / 2;

const side = world.Chunk.side;

pub const Stats = struct {
    /// Tiles written, at every level.
    tiles: usize = 0,
    levels: usize = 0,
    chunksRead: usize = 0,
    /// Wall time of drawing and writing every tile; opening the source isn't in it.
    duration: Io.Duration = .zero,
    /// The time each part of the tile pipeline took, summed over all workers.
    pipeline: tiles.Stats = .{},
};

pub const Options = struct {
    /// How blocks are drawn: a theme's `isometric/style.txt`. The game has one style, `game`.
    style: Style,
};

/// Renders `source` into `output` and returns the tiles written, at every level, owned by the
/// caller. A game style other than `game` is error.UnknownStyle, and more different looks
/// than a chunk can number error.TooManyLooks.
pub fn render(comptime Source: type, allocator: std.mem.Allocator, io: Io, source: *const Source, output: tiles.Output, options: Options, stats: *Stats) ![]tiles.Written {
    const start: Io.Timestamp = .now(io, .awake);
    var view: View(Source) = try .init(allocator, source, options.style);
    defer view.deinit(allocator);
    const list = try tileList(allocator, source.chunkColumns, source.heights().world);
    defer allocator.free(list);

    var written: std.ArrayList(tiles.Written) = .empty;
    errdefer written.deinit(allocator);
    const rendered = try tiles.render(View(Source), allocator, io, &view, list, output, &written);
    const result = try written.toOwnedSlice(allocator);

    stats.* = .{
        .tiles = rendered.tiles,
        .levels = rendered.levels,
        .chunksRead = view.chunksRead,
        .duration = start.untilNow(io, .awake),
        .pipeline = rendered,
    };
    return result;
}

/// Where the blocks from (x0, y0, z0) to (x1, y1, z1), each included, are drawn, in level-0
/// pixels: from `left` and `top` up to but not including `right` and `bottom`.
const Box = struct {
    left: i64,
    top: i64,
    right: i64,
    bottom: i64,

    fn of(x0: i64, y0: i64, z0: i64, x1: i64, y1: i64, z1: i64) Box {
        return .{
            .left = (x0 - z1 - 1) * across,
            .top = (x0 + z0) * down - (y1 + 1) * below,
            .right = (x1 - z0 - 1) * across + blockWidth,
            .bottom = (x1 + z1) * down - (y0 + 1) * below + blockWidth,
        };
    }
};

/// A line of sight: the blocks drawn on one square, each one block west, north and down from
/// the one before, further from the viewer. `u` is x − z and `v` is x + z − 2y, which stay the
/// same along it; they're both even or both odd.
const Line = struct {
    u: i64,
    v: i64,

    /// The x and z of its block at height `y`.
    fn at(self: Line, y: i64) [2]i64 {
        const sum = self.v + 2 * y;
        return .{ @divExact(sum + self.u, 2), @divExact(sum - self.u, 2) };
    }

    /// Where its blocks are drawn, in level-0 pixels.
    fn square(self: Line) Box {
        const left = (self.u - 1) * across;
        const top = (self.v - 2) * down;
        return .{ .left = left, .top = top, .right = left + blockWidth, .bottom = top + blockWidth };
    }
};

test Line {
    const line: Line = .{ .u = 3, .v = -7 };
    for ([_]i64{ 0, 1, 40, 255 }) |y| {
        const x, const z = line.at(y);
        try std.testing.expectEqual(line.u, x - z);
        try std.testing.expectEqual(line.v, x + z - 2 * y);
        try std.testing.expectEqual(Box.of(x, y, z, x, y, z), line.square());
    }
}

/// The chunks a worker has read: how each of their blocks is drawn (`View.blockLooks`), or that
/// a chunk has nothing to draw, which takes no room. It holds a fixed number of each, set up
/// once, and makes room by forgetting the one used longest ago.
const ChunkCache = struct {
    pub const Position = struct { x: i32, y: i32, z: i32 };
    pub const Looks = [world.Chunk.volume]u16;
    pub const Lookup = union(enum) { uncached, empty, looks: *const Looks };

    /// Chunks remembered, and how many of them can have blocks to draw: 64 KB each.
    pub const defaultChunks = 4096;
    pub const defaultChunksWithBlocks = 128;

    const Entry = struct {
        position: Position,
        /// Where its looks are in `looks`, or null for a chunk with nothing to draw.
        slot: ?u32,
        /// When it was last used, by `clock`.
        used: u64,
    };

    entries: []Entry,
    count: usize = 0,
    /// Each position's index in `entries`.
    byPosition: std.AutoHashMapUnmanaged(Position, u32),
    looks: []Looks,
    /// Slots in `looks` no entry holds, the first `freeCount` of them.
    free: []u32,
    freeCount: usize,
    clock: u64 = 0,

    fn init(allocator: std.mem.Allocator, chunks: u32, chunksWithBlocks: u32) !ChunkCache {
        const entries = try allocator.alloc(Entry, chunks);
        errdefer allocator.free(entries);
        var byPosition: std.AutoHashMapUnmanaged(Position, u32) = .empty;
        try byPosition.ensureTotalCapacity(allocator, chunks);
        errdefer byPosition.deinit(allocator);
        const looks = try allocator.alloc(Looks, chunksWithBlocks);
        errdefer allocator.free(looks);
        const free = try allocator.alloc(u32, chunksWithBlocks);
        for (free, 0..) |*slot, i| slot.* = @intCast(i);
        return .{ .entries = entries, .byPosition = byPosition, .looks = looks, .free = free, .freeCount = free.len };
    }

    fn deinit(self: *ChunkCache, allocator: std.mem.Allocator) void {
        allocator.free(self.free);
        allocator.free(self.looks);
        self.byPosition.deinit(allocator);
        allocator.free(self.entries);
    }

    fn get(self: *ChunkCache, position: Position) Lookup {
        const index = self.byPosition.get(position) orelse return .uncached;
        const entry = &self.entries[index];
        self.clock += 1;
        entry.used = self.clock;
        return if (entry.slot) |slot| .{ .looks = &self.looks[slot] } else .empty;
    }

    /// Remembers `position`, which must not be cached yet, and returns where to write its looks
    /// if it has `blocks`, or null.
    fn put(self: *ChunkCache, position: Position, blocks: bool) ?*Looks {
        var index: usize = undefined;
        var slot: ?u32 = null;
        if (blocks and self.freeCount == 0) {
            // The chunk with blocks used longest ago makes room in both.
            index = self.leastRecent(true);
            slot = self.entries[index].slot;
            _ = self.byPosition.remove(self.entries[index].position);
        } else {
            if (self.count < self.entries.len) {
                index = self.count;
                self.count += 1;
            } else {
                index = self.leastRecent(false);
                _ = self.byPosition.remove(self.entries[index].position);
                if (self.entries[index].slot) |freed| {
                    self.free[self.freeCount] = freed;
                    self.freeCount += 1;
                }
            }
            if (blocks) {
                self.freeCount -= 1;
                slot = self.free[self.freeCount];
            }
        }
        self.clock += 1;
        self.entries[index] = .{ .position = position, .slot = slot, .used = self.clock };
        self.byPosition.putAssumeCapacity(position, @intCast(index));
        return if (slot) |s| &self.looks[s] else null;
    }

    /// The entry used longest ago, of those with blocks if `withBlocks`.
    fn leastRecent(self: *const ChunkCache, withBlocks: bool) usize {
        var oldest: usize = 0;
        var oldestUse: u64 = std.math.maxInt(u64);
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (withBlocks and entry.slot == null) continue;
            if (entry.used < oldestUse) {
                oldest = i;
                oldestUse = entry.used;
            }
        }
        return oldest;
    }
};

test ChunkCache {
    var cache: ChunkCache = try .init(std.testing.allocator, 3, 2);
    defer cache.deinit(std.testing.allocator);
    const a: ChunkCache.Position = .{ .x = 1, .y = 0, .z = 0 };
    const b: ChunkCache.Position = .{ .x = 2, .y = 0, .z = 0 };
    const c: ChunkCache.Position = .{ .x = 3, .y = 0, .z = 0 };
    const d: ChunkCache.Position = .{ .x = 4, .y = 0, .z = 0 };
    try std.testing.expect(cache.get(a) == .uncached);
    cache.put(a, true).?[0] = 7;
    cache.put(b, true).?[0] = 8;
    try std.testing.expect(cache.put(c, false) == null);
    try std.testing.expectEqual(7, cache.get(a).looks[0]);
    try std.testing.expect(cache.get(c) == .empty);
    // No slot is free for d's blocks: b, used longest ago of the chunks with blocks, makes room.
    cache.put(d, true).?[0] = 9;
    try std.testing.expect(cache.get(b) == .uncached);
    try std.testing.expectEqual(9, cache.get(d).looks[0]);
    try std.testing.expectEqual(7, cache.get(a).looks[0]);
    // Every entry is taken: c, now used longest ago, makes room for an empty chunk.
    try std.testing.expect(cache.put(b, false) == null);
    try std.testing.expect(cache.get(c) == .uncached);
    try std.testing.expect(cache.get(b) == .empty);
}

/// The tiles the chunk columns are drawn on, from the bottom of the world to its top.
fn tileList(allocator: std.mem.Allocator, columns: []const world.ChunkColumn, height: u16) ![]tiles.Tile {
    var set: std.AutoArrayHashMapUnmanaged(tiles.Tile, void) = .empty;
    defer set.deinit(allocator);
    for (columns) |column| {
        const x0 = @as(i64, column.x) * side;
        const z0 = @as(i64, column.z) * side;
        const box: Box = .of(x0, 0, z0, x0 + side - 1, @as(i64, height) - 1, z0 + side - 1);
        var ty = @divFloor(box.top, tiles.size);
        while (ty * tiles.size < box.bottom) : (ty += 1) {
            var tx = @divFloor(box.left, tiles.size);
            while (tx * tiles.size < box.right) : (tx += 1) {
                try set.put(allocator, .{ .x = @intCast(tx), .y = @intCast(ty) }, {});
            }
        }
    }
    return allocator.dupe(tiles.Tile, set.keys());
}

test tileList {
    // One chunk column 256 blocks high: 64 blocks of x − z wide, and 64 of x + z plus 256 high,
    // around screen x 0, from 256 blocks up down to its bottom corner.
    const box = Box.of(0, 0, 0, 31, 255, 31);
    try std.testing.expectEqual(Box{ .left = -32 * across, .top = -256 * below, .right = 32 * across, .bottom = 62 * down - below + blockWidth }, box);
    const list = try tileList(std.testing.allocator, &.{.{ .x = 0, .z = 0 }}, 256);
    defer std.testing.allocator.free(list);
    const columns = @divFloor(box.right - 1, tiles.size) - @divFloor(box.left, tiles.size) + 1;
    const rows = @divFloor(box.bottom - 1, tiles.size) - @divFloor(box.top, tiles.size) + 1;
    try std.testing.expectEqual(@as(usize, @intCast(columns * rows)), list.len);
}

/// How each face of a block's square is lit, by pixel.
const Face = enum { none, top, south, east };

/// Which face each pixel of a block's square shows, by where its centre falls.
const faces: [blockWidth][blockWidth]Face = faces: {
    @setEvalBranchQuota(10_000);
    var out: [blockWidth][blockWidth]Face = undefined;
    const a: f32 = across;
    const d: f32 = down;
    for (0..blockWidth) |row| for (0..blockWidth) |column| {
        const x = @as(f32, @floatFromInt(column)) + 0.5;
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        out[row][column] = if (@abs(x - a) / a + @abs(y - d) / d < 1)
            .top
        else if (x > a and y > 2 * d - (x - a) * d / a and y < 2 * d + below - (x - a) * d / a)
            .east
        else if (x < a and y > d + x * d / a and y < d + below + x * d / a)
            .south
        else
            .none;
    };
    break :faces out;
};

test faces {
    // The top face fills the middle of the top half, the south face the left of the bottom
    // half and the east face its right; the corners are empty.
    const w = blockWidth;
    try std.testing.expectEqual(Face.top, faces[w / 4][w / 2]);
    try std.testing.expectEqual(Face.none, faces[0][0]);
    try std.testing.expectEqual(Face.south, faces[w * 5 / 8][w / 4]);
    try std.testing.expectEqual(Face.east, faces[w * 5 / 8][w * 3 / 4]);
    try std.testing.expectEqual(Face.none, faces[w - 1][0]);
    // Each face is a quarter of the square.
    var counts: std.EnumArray(Face, usize) = .initFill(0);
    for (faces) |row| for (row) |face| {
        counts.getPtr(face).* += 1;
    };
    for ([_]Face{ .top, .south, .east }) |face| try std.testing.expectEqual(blockWidth * blockWidth / 4, counts.get(face));
    // Blocks at the same depth, x + y + z, never cover the same pixel, so the depth buffer can
    // draw blocks in any order.
    var drawn: [6 * blockWidth][6 * blockWidth]bool = @splat(@splat(false));
    for (0..3) |bx| for (0..3) |by| for (0..3) |bz| {
        if (bx + by + bz != 3) continue;
        const left = (bx + 2 - bz) * across;
        const top = (bx + bz) * down + (2 - by) * below;
        for (0..blockWidth) |row| for (0..blockWidth) |column| {
            if (faces[row][column] == .none) continue;
            try std.testing.expect(!drawn[top + row][left + column]);
            drawn[top + row][left + column] = true;
        };
    };
}

/// Each face's light, in 256ths.
const light = std.EnumArray(Face, u16).init(.{ .none = 0, .top = 256, .south = 208, .east = 176 });

/// What a tile's depth buffer counts in: `depthSteps`ths of a block, of x + y + z of the point
/// each pixel shows, larger nearer.
const depthSteps = 256;

/// How far into its block each pixel of a cube's square shows the cube: x + y + z of the point
/// there on the face it shows, the block being from 0 to 1, in `depthSteps`ths. At the middle of
/// a pixel, two cubes' faces are never less than a 64th of a block apart, so blocks keep the
/// order whole blocks' depths gave them.
const cubeDepths: [blockWidth][blockWidth]i16 = depths: {
    @setEvalBranchQuota(20_000);
    var out: [blockWidth][blockWidth]i16 = undefined;
    const a: f32 = across;
    const d: f32 = down;
    const b: f32 = below;
    for (0..blockWidth) |row| for (0..blockWidth) |column| {
        const x = @as(f32, @floatFromInt(column)) + 0.5;
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        // Where a point at (x, y, z) is drawn (`textureCoordinates`), turned round for each face.
        const depth: f32 = switch (faces[row][column]) {
            .none => 0,
            .top => y / d + 1,
            .south => x / a + (1 - (y - d * x / a - d) / b) + 1,
            .east => 1 + (1 - (y - d - d * (2 - x / a)) / b) + (2 - x / a),
        };
        out[row][column] = @intFromFloat(@round(depth * depthSteps));
    };
    break :depths out;
};

test cubeDepths {
    const w = blockWidth;
    // The top's far corner, at the top of the square, is (0, 1, 0), and the near corner, where
    // the three faces meet, is (1, 1, 1) on each of them.
    try std.testing.expectApproxEqAbs(@as(f32, depthSteps), @as(f32, @floatFromInt(cubeDepths[0][w / 2])), depthSteps / 8);
    for ([_][2]usize{ .{ w / 2 - 1, w / 2 - 1 }, .{ w / 2, w / 2 - 1 }, .{ w / 2, w / 2 } }) |at| {
        try std.testing.expectApproxEqAbs(@as(f32, 3 * depthSteps), @as(f32, @floatFromInt(cubeDepths[at[0]][at[1]])), depthSteps / 8);
    }
    // The bottom corner is (1, 0, 1).
    try std.testing.expectApproxEqAbs(@as(f32, 2 * depthSteps), @as(f32, @floatFromInt(cubeDepths[w - 1][w / 2])), depthSteps / 8);
}

/// Each map type's three face colours at each height in the relief style:
/// `(mapType * heights.world + y) * 3`, top, south, east.
fn reliefColours(allocator: std.mem.Allocator, palette: *const world.Palette, heights: world.Heights) ![]u32 {
    const types = std.enums.values(world.MapType);
    const colours = try allocator.alloc(u32, types.len * heights.world * 3);
    const shades: relief.Heights = .of(heights);
    for (types) |mapType| for (0..heights.world) |y| {
        const base = palette.colours.get(mapType);
        const colour = if (mapType.isLiquid()) relief.liquidColour(base, 0) else relief.groundColour(palette, base, @intCast(y), shades, 0);
        const at = (@backingInt(mapType) * heights.world + y) * 3;
        colours[at] = lit(colour, light.get(.top));
        colours[at + 1] = lit(colour, light.get(.south));
        colours[at + 2] = lit(colour, light.get(.east));
    };
    return colours;
}

/// A colour's top, south and east faces, lit.
fn faceColours(colour: world.Rgb) [3]u32 {
    const pixel = tiles.rgba(colour[0], colour[1], colour[2], 255);
    return .{ lit(pixel, light.get(.top)), lit(pixel, light.get(.south)), lit(pixel, light.get(.east)) };
}

/// A block's square drawn in its textures, its faces lit.
const Picture = struct {
    /// The faces' plain layers: opaque on every face, and transparent where none is.
    plain: Layer,
    /// The faces' tinted layers, lit but not yet tinted, each pixel's alpha how much of it the
    /// layer covers; null if no face has one.
    tinted: ?Layer,

    const Layer = [blockWidth * blockWidth]u32;
};

/// Points sampled across and down each pixel of a picture.
const samples = 2;

/// How many pictures `cube` has: as many as the most variants any of its layers has.
fn variantCount(cube: *const world.CubeFaces) usize {
    var count: usize = 1;
    for ([_]world.CubeFaces.Face{ cube.up, cube.south, cube.east }) |face| count = @max(count, face.plain.len, face.tinted.len);
    return count;
}

/// Draws `cube` in its textures, each layer in its variant `variant` (counting round again for
/// a layer with fewer): each pixel of a layer is the average of its texels under it. A plain
/// pixel over only transparent texels is `fallback`.
fn pictureOf(cube: *const world.CubeFaces, variant: usize, fallback: world.Rgb) Picture {
    var out: Picture = .{ .plain = undefined, .tinted = null };
    const anyTinted = cube.up.tinted.len > 0 or cube.south.tinted.len > 0 or cube.east.tinted.len > 0;
    var tinted: Picture.Layer = undefined;
    for (0..blockWidth) |row| for (0..blockWidth) |column| {
        const p = row * blockWidth + column;
        const face = faces[row][column];
        const layers = switch (face) {
            .none => {
                out.plain[p] = tiles.transparent;
                tinted[p] = tiles.transparent;
                continue;
            },
            .top => cube.up,
            .south => cube.south,
            .east => cube.east,
        };
        const plain = average(face, column, row, pick(layers.plain, variant));
        const colour = if (plain[3] == 0) fallback else plain[0..3].*;
        out.plain[p] = lit(tiles.rgba(colour[0], colour[1], colour[2], 255), light.get(face));
        var layer = average(face, column, row, pick(layers.tinted, variant));
        // A face that's all tinted, as leaves are, has its holes filled with `fallback` to be
        // tinted too, rather than showing what's under it untinted.
        if (layers.plain.len == 0 and layers.tinted.len > 0) layer = if (layer[3] == 0) fallback ++ [1]u8{255} else layer[0..3].* ++ [1]u8{255};
        tinted[p] = lit(tiles.rgba(layer[0], layer[1], layer[2], layer[3]), light.get(face));
    };
    if (anyTinted) out.tinted = tinted;
    return out;
}

/// A layer's variant `variant`, counting round again past its last; null without the layer.
fn pick(variants: []const *const world.Image, variant: usize) ?*const world.Image {
    return if (variants.len == 0) null else variants[variant % variants.len];
}

/// The average of `image`'s texels under a pixel of a face, by their opacity, and how opaque
/// they are on average; transparent without an image.
fn average(face: Face, column: usize, row: usize, image: ?*const world.Image) [4]u8 {
    const texture = image orelse return @splat(0);
    var sum: [4]u32 = @splat(0);
    for (0..samples) |sy| for (0..samples) |sx| {
        const x = @as(f32, @floatFromInt(column)) + (@as(f32, @floatFromInt(sx)) + 0.5) / samples;
        const y = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples;
        const u, const v = textureCoordinates(face, x, y);
        const texel = texelAt(texture, u, v);
        for (0..3) |c| sum[c] += @as(u32, texel[c]) * texel[3];
        sum[3] += texel[3];
    };
    if (sum[3] == 0) return @splat(0);
    return .{
        @intCast(sum[0] / sum[3]),
        @intCast(sum[1] / sum[3]),
        @intCast(sum[2] / sum[3]),
        @intCast(sum[3] / (samples * samples)),
    };
}

/// A picture's pixel: its tinted layer, times `tint`, drawn over its plain one by how much it
/// covers.
fn blend(plain: u32, layer: u32, tint: world.Rgb) u32 {
    const top = std.mem.asBytes(&layer);
    const a: u32 = top[3];
    if (a == 0) return plain;
    const under = std.mem.asBytes(&plain);
    var out: [3]u8 = undefined;
    for (&out, top[0..3], under[0..3], tint) |*channel, t, p, c| {
        const tinted = @as(u32, t) * c / 255;
        channel.* = @intCast((tinted * a + @as(u32, p) * (255 - a)) / 255);
    }
    return tiles.rgba(out[0], out[1], out[2], 255);
}

/// `colour` multiplied by `tint`, each channel rounded down, as the game tints.
fn multiply(colour: world.Rgb, tint: world.Rgb) world.Rgb {
    var out: world.Rgb = undefined;
    for (&out, colour, tint) |*channel, c, t| channel.* = @intCast(@as(u16, c) * t / 255);
    return out;
}

/// Where a point in a block's square falls on the texture of the face it's on: across and down
/// it, each from 0 to 1. A point at (x, y, z) in the world, block (0, 0, 0) being the cube from 0
/// to 1, is drawn at ((x − z + 1) · `across`, (x + z) · `down` − (y − 1) · `below`) in its square.
fn textureCoordinates(face: Face, x: f32, y: f32) [2]f32 {
    const a: f32 = across;
    const d: f32 = down;
    const b: f32 = below;
    const coordinates: [2]f32 = switch (face) {
        .none => unreachable,
        // At height 1, with north up.
        .top => .{ (x / a - 1 + y / d) / 2, (y / d - x / a + 1) / 2 },
        // At z = 1, with west on the left.
        .south => .{ x / a, 1 - ((x / a + 1) * d + b - y) / b },
        // At x = 1, with south on the left.
        .east => .{ x / a - 1, 1 - ((3 - x / a) * d + b - y) / b },
    };
    return .{ std.math.clamp(coordinates[0], 0, 1), std.math.clamp(coordinates[1], 0, 1) };
}

test textureCoordinates {
    const w: f32 = blockWidth;
    // Each face's corners: the top's highest is its texture's top left (north-west), and its
    // leftmost the bottom left (south-west).
    try std.testing.expectEqual([2]f32{ 0, 0 }, textureCoordinates(.top, w / 2, 0));
    try std.testing.expectEqual([2]f32{ 0, 1 }, textureCoordinates(.top, 0, w / 4));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.top, w / 2, w / 2));
    try std.testing.expectEqual([2]f32{ 0, 0 }, textureCoordinates(.south, 0, w / 4));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.south, w / 2, w));
    try std.testing.expectEqual([2]f32{ 0, 0 }, textureCoordinates(.east, w / 2, w / 2));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.east, w, w * 3 / 4));
}

const texelAt = rasterizer.texelAt;

/// How many pictures `shape` has: as many as the most variants any of its textures has.
fn shapeVariants(shape: *const world.Shape) usize {
    var count: usize = 1;
    for (shape.textures) |texture| count = @max(count, texture.plain.len, texture.tinted.len);
    return count;
}

/// How far beyond a cube's square a shape's picture reaches, in pixels, each way: parts of a
/// shape farther out are cut off.
const reach = blockWidth;

/// The side of what a shape's picture is drawn in (`ShapeTarget`), in pixels.
const shapeSide = blockWidth + 2 * reach;

/// What a shape's picture is drawn in first: `samples` × `samples` points for each of its
/// pixels, over the cube's square and `reach` around it.
const ShapeTarget = rasterizer.Target;

fn shapeTarget(allocator: std.mem.Allocator) !ShapeTarget {
    return .init(allocator, shapeSide * samples, shapeSide * samples);
}

/// A block's shape drawn in its textures, its faces lit (`shapePicture`): as much as it shows of
/// a cube's square and around it, each pixel with how far into the block its point is.
const ShapePicture = struct {
    /// Where its top left pixel is, from the top left of the cube's square.
    left: i16,
    top: i16,
    width: u16,
    height: u16,
    /// Row by row, as a cube's `Picture` has them.
    plain: []u32,
    tinted: ?[]u32,
    /// x + y + z of each pixel's point, the block being from 0 to 1, in `depthSteps`ths.
    depths: []i16,
    /// Whether it covers the whole of a cube's square, so nothing behind the block shows.
    fills: bool,

    /// Whether it shows anything at pixel `p`.
    fn shows(self: *const ShapePicture, p: usize) bool {
        if (self.plain[p] & 0xff000000 != 0) return true;
        const tinted = self.tinted orelse return false;
        return tinted[p] & 0xff000000 != 0;
    }

    fn destroy(self: *const ShapePicture, allocator: std.mem.Allocator) void {
        allocator.free(self.depths);
        if (self.tinted) |tinted| allocator.free(tinted);
        allocator.free(self.plain);
        allocator.destroy(self);
    }
};

/// Draws `shape` in its textures, each in its variant `variant` (counting round again for one
/// with fewer), its faces lit by the way they face. Each of its pixels is drawn at `samples` ×
/// `samples` points: it shows if at least half of them are covered, the average of their
/// colours, the depth of the nearest. Kept in `allocator`, trimmed to the pixels it shows.
fn shapePicture(allocator: std.mem.Allocator, shape: *const world.Shape, variant: usize, target: *ShapeTarget) !*const ShapePicture {
    std.debug.assert(target.width == shapeSide * samples and target.height == shapeSide * samples);
    target.clear();
    const scale: f32 = samples;
    for (shape.boxes) |box| for (box.faces, 0..) |maybeFace, sideIndex| {
        const face = maybeFace orelse continue;
        const texture = shape.textures[face.texture];
        // 1 for the plain layer and 2 for the tinted.
        const image, const tag: u8 = if (pick(texture.plain, variant)) |plain| .{ plain, 1 } else .{ pick(texture.tinted, variant) orelse continue, 2 };
        var corners: [4]rasterizer.Corner = undefined;
        var points: [4][3]f32 = undefined;
        for (&corners, &points, world.Shape.Side.corners(@fromBackingInt(@intCast(sideIndex))), face.uv) |*corner, *point, unit, uv| {
            const local = [3]f32{ unit[0] * box.size[0], unit[1] * box.size[1], unit[2] * box.size[2] };
            for (point, box.transform) |*coordinate, row| coordinate.* = row[0] * local[0] + row[1] * local[1] + row[2] * local[2] + row[3];
            corner.* = .{
                .x = ((point[0] - point[2] + 1) * across + reach) * scale,
                .y = ((point[0] + point[2]) * down - (point[1] - 1) * below + reach) * scale,
                .depth = point[0] + point[1] + point[2],
                .u = uv[0],
                .v = uv[1],
            };
        }
        const lighting = if (box.shade) lightOf(points) else light.get(.top);
        rasterizer.triangle(target, .{ corners[0], corners[1], corners[2] }, image, lighting, tag);
        rasterizer.triangle(target, .{ corners[0], corners[2], corners[3] }, image, lighting, tag);
    };

    // The pixels it shows, and where they are.
    var shown: [shapeSide][shapeSide]bool = undefined;
    var first: [2]usize = .{ shapeSide, shapeSide };
    var last: [2]usize = .{ 0, 0 };
    var fills = true;
    var anyTinted = false;
    for (0..shapeSide) |row| for (0..shapeSide) |column| {
        var covered: usize = 0;
        for (0..samples) |sy| for (0..samples) |sx| {
            const tag = target.tags[(row * samples + sy) * target.width + column * samples + sx];
            covered += @intFromBool(tag != 0);
            anyTinted = anyTinted or tag == 2;
        };
        shown[row][column] = covered * 2 >= samples * samples;
        const inSquare = row >= reach and row < reach + blockWidth and column >= reach and column < reach + blockWidth;
        if (inSquare and faces[row - reach][column - reach] != .none and !shown[row][column]) fills = false;
        if (!shown[row][column]) continue;
        first = .{ @min(first[0], row), @min(first[1], column) };
        last = .{ @max(last[0], row), @max(last[1], column) };
    };
    const height = if (first[0] > last[0]) 0 else last[0] - first[0] + 1;
    const width = if (first[1] > last[1]) 0 else last[1] - first[1] + 1;

    const out = try allocator.create(ShapePicture);
    errdefer allocator.destroy(out);
    const plain = try allocator.alloc(u32, width * height);
    errdefer allocator.free(plain);
    const tinted: ?[]u32 = if (anyTinted) try allocator.alloc(u32, width * height) else null;
    errdefer if (tinted) |layer| allocator.free(layer);
    const depths = try allocator.alloc(i16, width * height);
    out.* = .{
        .left = @as(i16, @intCast(first[1])) - reach,
        .top = @as(i16, @intCast(first[0])) - reach,
        .width = @intCast(width),
        .height = @intCast(height),
        .plain = plain,
        .tinted = tinted,
        .depths = depths,
        .fills = fills,
    };
    for (0..height) |y| for (0..width) |x| {
        const row = first[0] + y;
        const column = first[1] + x;
        const p = y * width + x;
        plain[p] = tiles.transparent;
        if (tinted) |layer| layer[p] = tiles.transparent;
        depths[p] = 0;
        if (!shown[row][column]) continue;
        var sums: [3][4]u32 = @splat(@splat(0));
        var nearest: f32 = -std.math.inf(f32);
        for (0..samples) |sy| for (0..samples) |sx| {
            const at = (row * samples + sy) * target.width + column * samples + sx;
            const tag = target.tags[at];
            for (0..3) |c| sums[tag][c] += target.colours[at][c];
            sums[tag][3] += 1;
            if (tag != 0) nearest = @max(nearest, target.depths[at]);
        };
        const covered = sums[1][3] + sums[2][3];
        // The tinted layer covers the plain one as much as it covers the pixel; a pixel all
        // tinted takes its plain layer from it, unseen under it.
        const under = if (sums[1][3] > 0) sums[1] else sums[2];
        plain[p] = tiles.rgba(@intCast(under[0] / under[3]), @intCast(under[1] / under[3]), @intCast(under[2] / under[3]), 255);
        if (sums[2][3] > 0) {
            const t = sums[2];
            tinted.?[p] = tiles.rgba(@intCast(t[0] / t[3]), @intCast(t[1] / t[3]), @intCast(t[2] / t[3]), @intCast(t[3] * 255 / covered));
        }
        depths[p] = @intFromFloat(@round(nearest * depthSteps));
    };
    return out;
}

/// A shape's picture in one of its variants, drawn the first time a tile needs it, by the first
/// worker to need it, while any other that does waits.
const LazyPicture = struct {
    shape: *const world.Shape,
    variant: u32,
    state: std.atomic.Value(State) = .init(.unmade),
    /// Once `state` is `made`.
    picture: *const ShapePicture = undefined,

    const State = enum(u8) { unmade, making, made };

    /// The picture, drawn in `target` and kept in memory from `allocator` the first time, which
    /// must allow allocating from any thread.
    fn get(self: *LazyPicture, allocator: std.mem.Allocator, target: *ShapeTarget) !*const ShapePicture {
        if (self.state.load(.acquire) == .made) return self.picture;
        if (self.state.cmpxchgStrong(.unmade, .making, .acquire, .acquire) == null) {
            errdefer self.state.store(.unmade, .release);
            const picture = try shapePicture(allocator, self.shape, self.variant, target);
            self.picture = picture;
            self.state.store(.made, .release);
            return picture;
        }
        while (true) switch (self.state.load(.acquire)) {
            .made => return self.picture,
            .making => std.atomic.spinLoopHint(),
            // The worker drawing it failed: this one tries.
            .unmade => return self.get(allocator, target),
        };
    }
};

/// How a face with corners at `points` is lit, in 256ths: as a cube's top, south and east faces
/// are, by how much it faces up, south and east, and a face turned away from the viewer as
/// though turned towards it, as a plant's leaf is seen from either side.
fn lightOf(points: [4][3]f32) u16 {
    const a = sub(points[1], points[0]);
    const b = sub(points[3], points[0]);
    var normal = [3]f32{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
    const length = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
    if (length == 0) return light.get(.top);
    if (normal[0] + normal[1] + normal[2] < 0) normal = .{ -normal[0], -normal[1], -normal[2] };
    const x = normal[0] / length;
    const y = normal[1] / length;
    const z = normal[2] / length;
    const top: f32 = @floatFromInt(if (y >= 0) light.get(.top) else light.get(.east));
    const sum = x * x * @as(f32, @floatFromInt(light.get(.east))) + y * y * top + z * z * @as(f32, @floatFromInt(light.get(.south)));
    return @intFromFloat(@round(sum));
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

test pictureOf {
    const red: [4][4]u8 = @splat(.{ 200, 0, 0, 255 });
    const grass = [_][4]u8{ .{ 0, 100, 0, 255 }, .{ 0, 100, 0, 255 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    const soil: world.Image = .{ .width = 2, .height = 2, .pixels = &red };
    const fringe: world.Image = .{ .width = 2, .height = 2, .pixels = &grass };
    const grassy: world.CubeFaces.Face = .{ .plain = &.{&soil}, .tinted = &.{&fringe} };
    const picture = pictureOf(&.{ .up = .{ .plain = &.{&soil} }, .south = grassy, .east = grassy }, 0, .{ 1, 2, 3 });
    const w = blockWidth;
    const white: world.Rgb = @splat(255);
    try std.testing.expectEqual(tiles.transparent, picture.plain[0]);
    const top = (w / 4) * w + w / 2;
    try std.testing.expectEqual(faceColours(.{ 200, 0, 0 })[0], blend(picture.plain[top], picture.tinted.?[top], white));
    // The sides' top half is the fringe over the soil, tinted, and their bottom half the soil.
    const fringed = (w * 3 / 8) * w + w / 4;
    try std.testing.expectEqual(faceColours(.{ 0, 100, 0 })[1], blend(picture.plain[fringed], picture.tinted.?[fringed], white));
    try std.testing.expectEqual(faceColours(.{ 0, 0, 0 })[1], blend(picture.plain[fringed], picture.tinted.?[fringed], .{ 255, 0, 255 }));
    const bare = (w * 3 / 4) * w + w * 3 / 4;
    try std.testing.expectEqual(faceColours(.{ 200, 0, 0 })[2], blend(picture.plain[bare], picture.tinted.?[bare], .{ 0, 0, 0 }));
    // Without a tinted layer, there's none to blend.
    const plain: world.CubeFaces.Face = .{ .plain = &.{&soil} };
    try std.testing.expectEqual(null, pictureOf(&.{ .up = plain, .south = plain, .east = plain }, 0, .{ 1, 2, 3 }).tinted);

    // A top with two variants: the second picture has the second, and the sides, with one,
    // their only one.
    const blue: [4][4]u8 = @splat(.{ 0, 0, 200, 255 });
    const water: world.Image = .{ .width = 2, .height = 2, .pixels = &blue };
    const varied: world.CubeFaces = .{ .up = .{ .plain = &.{ &soil, &water } }, .south = plain, .east = plain };
    try std.testing.expectEqual(2, variantCount(&varied));
    const second = pictureOf(&varied, 1, .{ 1, 2, 3 });
    try std.testing.expectEqual(faceColours(.{ 0, 0, 200 })[0], second.plain[top]);
    try std.testing.expectEqual(faceColours(.{ 200, 0, 0 })[2], second.plain[bare]);

    // Leaves, all tinted: the holes in the bottom half take the fallback, and are tinted too.
    const leafy: world.CubeFaces.Face = .{ .tinted = &.{&fringe} };
    const leaves = pictureOf(&.{ .up = leafy, .south = leafy, .east = leafy }, 0, .{ 100, 100, 100 });
    // Grey 100 lit as an east face is 68, then tinted by 127 of 255, 33.
    try std.testing.expectEqual(tiles.rgba(0, 33, 0, 255), blend(leaves.plain[bare], leaves.tinted.?[bare], .{ 0, 127, 0 }));
}

/// A box from (0, 0, 0) to `size`, unturned, each face showing the whole of texture 0.
fn testBox(size: [3]f32) world.Shape.Box {
    const face: world.Shape.Face = .{ .texture = 0, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } };
    return .{ .transform = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } }, .size = size, .shade = true, .faces = @splat(face) };
}

/// The index in `picture` of the pixel at (`row`, `column`) of the cube's square, or null if the
/// picture doesn't reach it.
fn pixelAt(picture: *const ShapePicture, row: i64, column: i64) ?usize {
    const y = row - picture.top;
    const x = column - picture.left;
    if (y < 0 or y >= picture.height or x < 0 or x >= picture.width) return null;
    return @intCast(y * picture.width + x);
}

test shapePicture {
    const allocator = std.testing.allocator;
    var target = try shapeTarget(allocator);
    defer target.deinit(allocator);
    const red: [4][4]u8 = @splat(.{ 200, 0, 0, 255 });
    const image: world.Image = .{ .width = 2, .height = 2, .pixels = &red };
    const textures = [_]world.CubeFaces.Face{.{ .plain = &.{&image} }};
    const w = blockWidth;
    const top = [2]i64{ w / 4, w / 2 };
    const south = [2]i64{ w * 5 / 8, w / 4 };
    const east = [2]i64{ w * 5 / 8, w * 3 / 4 };

    // A whole block's box is the cube, filling the square, its faces lit as a cube's and each
    // pixel as deep as a cube's.
    const cube = try shapePicture(allocator, &.{ .boxes = &.{testBox(.{ 1, 1, 1 })}, .textures = &textures }, 0, &target);
    defer cube.destroy(allocator);
    try std.testing.expectEqual([4]i64{ 0, 0, w, w }, [4]i64{ cube.left, cube.top, cube.width, cube.height });
    try std.testing.expect(cube.fills);
    try std.testing.expectEqual(null, cube.tinted);
    const colours = faceColours(.{ 200, 0, 0 });
    for ([_][2]i64{ top, south, east }, colours) |at, colour| {
        const p = pixelAt(cube, at[0], at[1]).?;
        try std.testing.expectEqual(colour, cube.plain[p]);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(cubeDepths[@intCast(at[0])][@intCast(at[1])])), @as(f32, @floatFromInt(cube.depths[p])), depthSteps / 16);
    }
    try std.testing.expect(!cube.shows(pixelAt(cube, 0, 0).?));

    // A slab leaves the top of the square empty, for what's behind it to show.
    const slab = try shapePicture(allocator, &.{ .boxes = &.{testBox(.{ 1, 0.5, 1 })}, .textures = &textures }, 0, &target);
    defer slab.destroy(allocator);
    try std.testing.expect(!slab.fills);
    try std.testing.expectEqual(w / 4, slab.top);
    try std.testing.expectEqual(null, pixelAt(slab, w / 8, w / 2));
    try std.testing.expectEqual(colours[1], slab.plain[pixelAt(slab, w * 3 / 4, w / 4).?]);

    // A plank twice as long as the block reaches out of its square both ways, drawn whole.
    var plank = testBox(.{ 2, 1.0 / 16.0, 1 });
    plank.transform[0][3] = -0.5;
    const long = try shapePicture(allocator, &.{ .boxes = &.{plank}, .textures = &textures }, 0, &target);
    defer long.destroy(allocator);
    try std.testing.expectEqual(-w / 4, long.left);
    try std.testing.expectEqual(w + w / 2, long.width);

    // A tinted texture goes into the tinted layer, covering the plain one.
    const tinted = [_]world.CubeFaces.Face{.{ .tinted = &.{&image} }};
    const grass = try shapePicture(allocator, &.{ .boxes = &.{testBox(.{ 1, 1, 1 })}, .textures = &tinted }, 0, &target);
    defer grass.destroy(allocator);
    const p = pixelAt(grass, top[0], top[1]).?;
    try std.testing.expectEqual(colours[0], grass.tinted.?[p]);
    try std.testing.expectEqual(colours[0], blend(grass.plain[p], grass.tinted.?[p], @splat(255)));
}

test lightOf {
    // A face lit as it faces: up, south and east as a cube's, and halfway between up and south,
    // halfway between their lights. Seen from behind, it's lit as from the front.
    const up = [4][3]f32{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 } };
    const south = [4][3]f32{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } };
    try std.testing.expectEqual(light.get(.top), lightOf(up));
    try std.testing.expectEqual(light.get(.south), lightOf(south));
    try std.testing.expectEqual(light.get(.south), lightOf(.{ south[0], south[3], south[2], south[1] }));
    try std.testing.expectEqual(light.get(.east), lightOf(.{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } }));
    const slope = [4][3]f32{ .{ 0, 0, 1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 1 } };
    try std.testing.expectEqual((light.get(.top) + light.get(.south)) / 2, lightOf(slope));
}

test LazyPicture {
    var target = try shapeTarget(std.testing.allocator);
    defer target.deinit(std.testing.allocator);
    const red: [1][4]u8 = .{.{ 200, 0, 0, 255 }};
    const image: world.Image = .{ .width = 1, .height = 1, .pixels = &red };
    const textures = [_]world.CubeFaces.Face{.{ .plain = &.{&image} }};
    var lazy: LazyPicture = .{ .shape = &.{ .boxes = &.{testBox(.{ 1, 1, 1 })}, .textures = &textures }, .variant = 0 };
    // Drawn once, the first time.
    const picture = try lazy.get(std.testing.allocator, &target);
    defer picture.destroy(std.testing.allocator);
    try std.testing.expectEqual(picture, try lazy.get(std.testing.allocator, &target));
    try std.testing.expect(picture.fills);
}

/// What every worker shares, read-only while they draw, and their totals once they're done.
fn View(comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const name = folder;

        source: *const Source,
        /// How each block ID is drawn: 0 not at all, otherwise its look's index in `looks` + 1.
        blockLooks: []u16,
        looks: []Look,
        /// In the `relief` style, each map type's three face colours at each height:
        /// `(mapType * height + y) * 3`, top, south, east.
        colours: []u32,
        pictures: []Picture,
        /// Each shape's pictures, one for each variant, drawn as tiles first need them.
        shapePictures: []LazyPicture,
        /// How far beyond its square a block's picture can reach: `reach` with shapes, else 0.
        reach: i64,
        /// What `shapePictures` are kept in.
        allocator: std.mem.Allocator,
        height: u16,
        chunksRead: usize = 0,

        /// How a block is drawn.
        const Look = union(enum) {
            /// In its map type's relief colours, which change with height (`colours`).
            relief: world.MapType,
            /// Each face in one colour: top, south and east.
            colours: [3]u32,
            /// Each face in a colour times the tint of a block where it is.
            tintedColour: struct { colour: world.Rgb, block: i32 },
            /// In its textures, as a cube: the index in `pictures` of its first picture, how
            /// many it has, one for each variant, and the block whose tint colours its tinted
            /// layer, or null to leave it as it is.
            picture: Pictured,
            /// In its shape: the same, its pictures in `shapePictures`.
            shape: Pictured,

            const Pictured = struct { index: u32, variants: u32 = 1, tintedBy: ?i32 = null };
        };

        /// Cube faces by their variants' slices, which a game's reader shares between blocks
        /// with the same faces.
        const FacesContext = struct {
            pub fn hash(_: FacesContext, cube: world.CubeFaces) u64 {
                var hasher: std.hash.Wyhash = .init(0);
                std.hash.autoHashStrat(&hasher, cube, .Shallow);
                return hasher.final();
            }

            pub fn eql(_: FacesContext, a: world.CubeFaces, b: world.CubeFaces) bool {
                return std.meta.eql(a, b);
            }
        };

        /// Shapes by their boxes' slice and their textures' variants' slices, which a game's
        /// reader shares between blocks with the same shape and textures.
        const ShapeContext = struct {
            pub fn hash(_: ShapeContext, shape: *const world.Shape) u64 {
                var hasher: std.hash.Wyhash = .init(0);
                std.hash.autoHash(&hasher, @intFromPtr(shape.boxes.ptr));
                for (shape.textures) |texture| std.hash.autoHashStrat(&hasher, texture, .Shallow);
                return hasher.final();
            }

            pub fn eql(_: ShapeContext, a: *const world.Shape, b: *const world.Shape) bool {
                if (a.boxes.ptr != b.boxes.ptr or a.textures.len != b.textures.len) return false;
                for (a.textures, b.textures) |x, y| if (!std.meta.eql(x, y)) return false;
                return true;
            }
        };

        fn init(allocator: std.mem.Allocator, source: *const Source, style: Style) !Self {
            const heights = source.heights();
            const blockLooks = try allocator.alloc(u16, source.blockCount());
            errdefer allocator.free(blockLooks);
            var looks: std.ArrayList(Look) = .empty;
            errdefer looks.deinit(allocator);
            var pictures: std.ArrayList(Picture) = .empty;
            errdefer pictures.deinit(allocator);
            var shapePictures: std.ArrayList(LazyPicture) = .empty;
            errdefer shapePictures.deinit(allocator);
            var colours: []u32 = &.{};
            errdefer allocator.free(colours);
            switch (style) {
                .relief => |palette| {
                    colours = try reliefColours(allocator, &palette, heights);
                    for (std.enums.values(world.MapType)) |mapType| try looks.append(allocator, .{ .relief = mapType });
                    for (blockLooks, 0..) |*look, id| {
                        look.* = if (isDrawn(source, @intCast(id))) @backingInt(source.mapType(@intCast(id))) + 1 else 0;
                    }
                },
                .game => |gameStyle| {
                    if (gameStyle != null) return error.UnknownStyle;
                    // Blocks with the same faces share a picture, and untinted blocks that look
                    // the same share a look. A tinted block has a look of its own, naming it,
                    // as its tint is its own.
                    var byFaces: std.HashMapUnmanaged(world.CubeFaces, u32, FacesContext, std.hash_map.default_max_load_percentage) = .empty;
                    defer byFaces.deinit(allocator);
                    var byShape: std.HashMapUnmanaged(*const world.Shape, u32, ShapeContext, std.hash_map.default_max_load_percentage) = .empty;
                    defer byShape.deinit(allocator);
                    var byPicture: std.AutoHashMapUnmanaged(u32, u16) = .empty;
                    defer byPicture.deinit(allocator);
                    var byShapePicture: std.AutoHashMapUnmanaged(u32, u16) = .empty;
                    defer byShapePicture.deinit(allocator);
                    var byColour: std.AutoHashMapUnmanaged(world.Rgb, u16) = .empty;
                    defer byColour.deinit(allocator);
                    for (blockLooks, 0..) |*look, i| {
                        const id: i32 = @intCast(i);
                        // A block in a shape is drawn in it, plants and low blocks too.
                        const shape = if (source.isVisible(id)) source.shape(id) else null;
                        if (shape == null and !isDrawn(source, id)) {
                            look.* = 0;
                            continue;
                        }
                        const colour = source.colour(id);
                        const isTinted = source.isTinted(id);
                        if (source.cubeFaces(id)) |cube| {
                            const variants = variantCount(cube);
                            const picture = try byFaces.getOrPut(allocator, cube.*);
                            if (!picture.found_existing) {
                                picture.value_ptr.* = @intCast(pictures.items.len);
                                for (0..variants) |variant| try pictures.append(allocator, pictureOf(cube, variant, colour));
                            }
                            const pictured: Look.Pictured = .{ .index = picture.value_ptr.*, .variants = @intCast(variants) };
                            const tinted = pictures.items[pictured.index].tinted != null;
                            look.* = try addPictured(allocator, &looks, &byPicture, .picture, pictured, if (isTinted and tinted) id else null);
                        } else if (shape) |drawn| {
                            const variants = shapeVariants(drawn);
                            const picture = try byShape.getOrPut(allocator, drawn);
                            if (!picture.found_existing) {
                                picture.value_ptr.* = @intCast(shapePictures.items.len);
                                for (0..variants) |variant| try shapePictures.append(allocator, .{ .shape = drawn, .variant = @intCast(variant) });
                            }
                            const pictured: Look.Pictured = .{ .index = picture.value_ptr.*, .variants = @intCast(variants) };
                            const tinted = for (drawn.textures) |texture| {
                                if (texture.tinted.len > 0) break true;
                            } else false;
                            look.* = try addPictured(allocator, &looks, &byShapePicture, .shape, pictured, if (isTinted and tinted) id else null);
                        } else if (isTinted) {
                            look.* = try addLook(allocator, &looks, .{ .tintedColour = .{ .colour = colour, .block = id } });
                        } else {
                            const entry = try byColour.getOrPut(allocator, colour);
                            if (!entry.found_existing) entry.value_ptr.* = try addLook(allocator, &looks, .{ .colours = faceColours(colour) });
                            look.* = entry.value_ptr.*;
                        }
                    }
                },
            }
            const lookList = try looks.toOwnedSlice(allocator);
            errdefer allocator.free(lookList);
            const pictureList = try pictures.toOwnedSlice(allocator);
            errdefer allocator.free(pictureList);
            return .{
                .source = source,
                .blockLooks = blockLooks,
                .looks = lookList,
                .colours = colours,
                .pictures = pictureList,
                .reach = if (shapePictures.items.len > 0) reach else 0,
                .shapePictures = try shapePictures.toOwnedSlice(allocator),
                .allocator = allocator,
                .height = heights.world,
            };
        }

        /// The look of a block drawn in pictures: its own, naming it, for a block whose tint
        /// colours them (`tintedBy`), as its tint is its own; else one shared by every block in
        /// the same pictures.
        fn addPictured(allocator: std.mem.Allocator, looks: *std.ArrayList(Look), byPictures: *std.AutoHashMapUnmanaged(u32, u16), comptime kind: std.meta.Tag(Look), pictured: Look.Pictured, tintedBy: ?i32) !u16 {
            if (tintedBy) |id| {
                var own = pictured;
                own.tintedBy = id;
                return addLook(allocator, looks, @unionInit(Look, @tagName(kind), own));
            }
            const entry = try byPictures.getOrPut(allocator, pictured.index);
            if (!entry.found_existing) entry.value_ptr.* = try addLook(allocator, looks, @unionInit(Look, @tagName(kind), pictured));
            return entry.value_ptr.*;
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void {
            for (self.shapePictures) |*lazy| if (lazy.state.load(.acquire) == .made) lazy.picture.destroy(allocator);
            allocator.free(self.shapePictures);
            allocator.free(self.pictures);
            allocator.free(self.colours);
            allocator.free(self.looks);
            allocator.free(self.blockLooks);
        }

        /// Plants aren't drawn, nor low blocks, nor blocks not seen in play.
        fn isDrawn(source: *const Source, id: i32) bool {
            return source.isVisible(id) and source.mapType(id) != .plant and !source.isLow(id);
        }

        /// Adds `look` and returns its number in a chunk's looks, its index + 1.
        fn addLook(allocator: std.mem.Allocator, looks: *std.ArrayList(Look), look: Look) !u16 {
            if (looks.items.len >= std.math.maxInt(u16)) return error.TooManyLooks;
            try looks.append(allocator, look);
            return @intCast(looks.items.len);
        }

        pub fn collect(self: *Self, worker: *const Worker) void {
            self.chunksRead += worker.reader.chunksRead;
        }

        /// One thread's reader, chunk cache and buffers, reused for every tile it draws.
        pub const Worker = struct {
            view: *const Self,
            reader: Source.Reader,
            /// Where a chunk is read into, and its blocks' looks worked out, before they go into
            /// the cache.
            chunk: *world.Chunk,
            looks: *ChunkCache.Looks,
            cache: ChunkCache,
            /// The depth of what each pixel shows: x + y + z of its point, in `depthSteps`ths of
            /// a block, larger nearer.
            depth: *[tiles.size * tiles.size]i64,
            /// Where it draws the shapes' pictures it's the first to need.
            target: ShapeTarget,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                var reader: Source.Reader = try .init(view.source, allocator, null);
                errdefer reader.deinit(allocator);
                const chunk = try allocator.create(world.Chunk);
                errdefer allocator.destroy(chunk);
                const looks = try allocator.create(ChunkCache.Looks);
                errdefer allocator.destroy(looks);
                var cache: ChunkCache = try .init(allocator, ChunkCache.defaultChunks, ChunkCache.defaultChunksWithBlocks);
                errdefer cache.deinit(allocator);
                const depth = try allocator.create([tiles.size * tiles.size]i64);
                errdefer allocator.destroy(depth);
                const target = try shapeTarget(allocator);
                return .{ .view = view, .reader = reader, .chunk = chunk, .looks = looks, .cache = cache, .depth = depth, .target = target };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                self.target.deinit(allocator);
                allocator.destroy(self.depth);
                self.cache.deinit(allocator);
                allocator.destroy(self.looks);
                allocator.destroy(self.chunk);
                self.reader.deinit(allocator);
            }

            /// Draws the nearest block on each line of sight through the tile. Returns false if
            /// none has one.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                @memset(pixels, tiles.transparent);
                @memset(self.depth, std.math.minInt(i64));
                const x0 = @as(i64, tile.x) * tiles.size;
                const y0 = @as(i64, tile.y) * tiles.size;
                var any = false;
                // The lines whose squares fall on the tile (`Line.square`), or near enough for
                // a shape on them to reach into it.
                const margin = self.view.reach;
                var u = @divFloor(x0 - margin - blockWidth, across) + 2;
                while (u <= @divFloor(x0 + tiles.size + margin - 1, across) + 1) : (u += 1) {
                    var v = @divFloor(y0 - margin - blockWidth, down) + 3;
                    while (v <= @divFloor(y0 + tiles.size + margin - 1, down) + 2) : (v += 1) {
                        if (@mod(u + v, 2) != 0) continue;
                        const line: Line = .{ .u = u, .v = v };
                        var y: i64 = @as(i64, self.view.height) - 1;
                        // A block whose picture leaves parts of its square empty, such as a
                        // plant, shows what's behind it on the line there.
                        while (try self.nextBlock(line, &y)) |block| {
                            const drawn = try self.drawLook(line, block, x0, y0, pixels);
                            if (drawn.any) any = true;
                            if (drawn.fills) break;
                        }
                    }
                }
                return any;
            }

            /// Draws `block`, on `line`, in its look. Returns whether it drew any pixel, and
            /// whether it fills its square, hiding what's behind it on the line.
            fn drawLook(self: *Worker, line: Line, block: Block, x0: i64, y0: i64, pixels: *tiles.Pixels) !struct { any: bool, fills: bool } {
                var tintedColours: [3]u32 = undefined;
                var fills = true;
                const paint: Paint = switch (self.view.looks[block.look - 1]) {
                    .relief => |mapType| relief: {
                        const at = (@as(usize, @backingInt(mapType)) * self.view.height + @as(usize, @intCast(block.y))) * 3;
                        break :relief .{ .faces = self.view.colours[at..][0..3] };
                    },
                    .colours => |*colours| .{ .faces = colours },
                    .tintedColour => |look| colour: {
                        const tint = try self.reader.tint(look.block, block.x, block.y, block.z);
                        tintedColours = faceColours(multiply(look.colour, tint));
                        break :colour .{ .faces = &tintedColours };
                    },
                    .picture => |look| picture: {
                        const variant = if (look.variants > 1) self.view.source.variant(block.x, block.y, block.z, look.variants) else 0;
                        const picture = &self.view.pictures[look.index + variant];
                        if (picture.tinted == null) break :picture .{ .picture = &picture.plain };
                        break :picture .{ .tintedPicture = .{ .picture = picture, .tint = try self.tintOf(look, block) } };
                    },
                    .shape => |look| shape: {
                        const variant = if (look.variants > 1) self.view.source.variant(block.x, block.y, block.z, look.variants) else 0;
                        const picture = try self.view.shapePictures[look.index + variant].get(self.view.allocator, &self.target);
                        fills = picture.fills;
                        const tint = if (picture.tinted == null) @as(world.Rgb, @splat(255)) else try self.tintOf(look, block);
                        break :shape .{ .shape = .{ .picture = picture, .tint = tint } };
                    },
                };
                const square = line.square();
                const depth = (block.x + block.y + block.z) * depthSteps;
                const any = self.drawBlock(square.left - x0, square.top - y0, depth, paint, pixels);
                return .{ .any = any, .fills = fills };
            }

            /// The tint of a block drawn in pictures with a tinted layer: its own where it is, or
            /// none to leave the layer as it is.
            fn tintOf(self: *Worker, look: Look.Pictured, block: Block) !world.Rgb {
                const id = look.tintedBy orelse return @splat(255);
                return self.reader.tint(id, block.x, block.y, block.z);
            }

            const Block = struct { x: i64, y: i64, z: i64, look: u16 };

            /// What a block's pixels come from: a colour for each face, top, south and east, or
            /// a picture.
            const Paint = union(enum) {
                faces: *const [3]u32,
                picture: *const Picture.Layer,
                /// A picture with its tinted layer, tinted by `tint`.
                tintedPicture: struct { picture: *const Picture, tint: world.Rgb },
                /// A shape's picture, its tinted layer, if it has one, tinted by `tint`.
                shape: struct { picture: *const ShapePicture, tint: world.Rgb },
            };

            /// The next drawn block on a line of sight, following it down from height `y.*`, or
            /// null if none is; `y.*` is then just below it. A chunk without one is passed in one
            /// step.
            fn nextBlock(self: *Worker, line: Line, y: *i64) !?Block {
                while (y.* >= 0) {
                    const x, const z = line.at(y.*);
                    const cx = @divFloor(x, side);
                    const cy = @divFloor(y.*, side);
                    const cz = @divFloor(z, side);
                    var lx: usize = @intCast(x - cx * side);
                    var ly: usize = @intCast(y.* - cy * side);
                    var lz: usize = @intCast(z - cz * side);
                    // The line's blocks in this chunk, from here until it leaves it.
                    const steps = @min(lx, ly, lz) + 1;
                    if (try self.chunkLooks(cx, cy, cz)) |looks| {
                        for (0..steps) |step| {
                            const look = looks[(ly * side + lz) * side + lx];
                            if (look != 0) {
                                const back: i64 = @intCast(step);
                                const found: Block = .{ .x = x - back, .y = y.* - back, .z = z - back, .look = look };
                                y.* = found.y - 1;
                                return found;
                            }
                            lx -%= 1;
                            ly -%= 1;
                            lz -%= 1;
                        }
                    }
                    y.* -= @intCast(steps);
                }
                return null;
            }

            /// How each block of chunk (x, y, z) is drawn, from the cache or else read; null for a
            /// chunk with nothing to draw.
            fn chunkLooks(self: *Worker, x: i64, y: i64, z: i64) !?*const ChunkCache.Looks {
                const limit = std.math.maxInt(i32);
                if (@abs(x) > limit or @abs(y) > limit or @abs(z) > limit) return null;
                const position: ChunkCache.Position = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) };
                switch (self.cache.get(position)) {
                    .empty => return null,
                    .looks => |looks| return looks,
                    .uncached => {},
                }
                if (!try self.reader.readChunk(position.x, position.y, position.z, self.chunk)) {
                    _ = self.cache.put(position, false);
                    return null;
                }
                const byId = self.view.blockLooks;
                var drawn: u16 = 0;
                for (self.looks, self.chunk.solid, self.chunk.liquid) |*look, solid, liquid| {
                    const solidLook = if (solid >= 0 and solid < byId.len) byId[@intCast(solid)] else 0;
                    const liquidLook = if (liquid >= 0 and liquid < byId.len) byId[@intCast(liquid)] else 0;
                    look.* = if (solidLook != 0) solidLook else liquidLook;
                    drawn |= look.*;
                }
                // A chunk of only air, plants or invisible blocks, such as those in the sky, is kept
                // as having nothing to draw: lines pass it in one step, and it takes no slot.
                if (drawn == 0) {
                    _ = self.cache.put(position, false);
                    return null;
                }
                const looks = self.cache.put(position, true).?;
                looks.* = self.looks.*;
                return looks;
            }

            /// Draws a block whose square's top left is at (`left`, `top`) in the tile, at
            /// `depth`, x + y + z of the block in `depthSteps`ths, on each pixel where what it
            /// shows is nearer than what's there. Returns whether it drew any.
            fn drawBlock(self: *Worker, left: i64, top: i64, depth: i64, paint: Paint, pixels: *tiles.Pixels) bool {
                var any = false;
                switch (paint) {
                    .shape => |from| {
                        const picture = from.picture;
                        for (0..picture.height) |row| {
                            const py = top + picture.top + @as(i64, @intCast(row));
                            if (py < 0 or py >= tiles.size) continue;
                            for (0..picture.width) |column| {
                                const px = left + picture.left + @as(i64, @intCast(column));
                                if (px < 0 or px >= tiles.size) continue;
                                const at = row * picture.width + column;
                                // Where it shows nothing, what's behind it does.
                                if (!picture.shows(at)) continue;
                                const p: usize = @intCast(py * tiles.size + px);
                                const pointDepth = depth + picture.depths[at];
                                if (pointDepth <= self.depth[p]) continue;
                                self.depth[p] = pointDepth;
                                pixels[p] = if (picture.tinted) |tinted| blend(picture.plain[at], tinted[at], from.tint) else picture.plain[at];
                                any = true;
                            }
                        }
                    },
                    inline else => |from, kind| for (0..blockWidth) |row| {
                        const py = top + @as(i64, @intCast(row));
                        if (py < 0 or py >= tiles.size) continue;
                        for (0..blockWidth) |column| {
                            const px = left + @as(i64, @intCast(column));
                            if (px < 0 or px >= tiles.size) continue;
                            const face = faces[row][column];
                            if (face == .none) continue;
                            const at = row * blockWidth + column;
                            const p: usize = @intCast(py * tiles.size + px);
                            const pointDepth = depth + cubeDepths[row][column];
                            if (pointDepth <= self.depth[p]) continue;
                            self.depth[p] = pointDepth;
                            pixels[p] = switch (kind) {
                                .faces => from[@backingInt(face) - 1],
                                .picture => from[at],
                                .tintedPicture => blend(from.picture.plain[at], from.picture.tinted.?[at], from.tint),
                                .shape => comptime unreachable,
                            };
                            any = true;
                        }
                    },
                }
                return any;
            }
        };
    };
}

/// `pixel`'s colour times `factor` 256ths.
fn lit(pixel: u32, factor: u16) u32 {
    const channels = std.mem.asBytes(&pixel);
    var out: [3]u8 = undefined;
    for (&out, channels[0..3]) |*channel, value| channel.* = @intCast(@min(255, @as(u32, value) * factor / 256));
    return tiles.rgba(out[0], out[1], out[2], channels[3]);
}
