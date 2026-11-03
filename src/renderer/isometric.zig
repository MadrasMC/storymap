//! The isometric view, looking down from above, north-west or turned from there (`Rotation`):
//! every block drawn as a cube, its top, left and right faces lit differently. Everything here
//! works in the view's coordinates, the same in every rotation, and only blocks, the sides of
//! cubes and the corners of shapes are turned to it. In the `relief` style each is in its map
//! type's relief colour (`relief.zig`); in the `game` style, a block the game draws as a cube is in its
//! textures (`cubeLayers`), one the game draws in another shape is in that shape, or the one of
//! its shapes its place picks (`shapeSprite`), each sprite drawn once, when the game's blocks
//! are prepared (`drawSprites`), and any other block in its texture's average colour, each
//! tinted by the climate where it is, as the game tints grass, leaves and water. Otherwise,
//! plants aren't drawn, nor low blocks, such as loose stones, which a whole cube would make look
//! much larger than they are.
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
//! - for the `game` style, `colour(id: i32) world.Rgb`, `spritesOf(id: i32)
//!   ?world.BlockSprites`, the block's sprites (`Options.sprites`), `isTinted(id: i32) bool`,
//!   `isLiquid(id: i32) bool`, `isSeeThrough(id: i32) bool`, a block that shows what's behind it,
//!   `variant(id: i32, x: i64, y: i64, z: i64, count: u32) u32`, which of `count` variants of
//!   its textures, `count` shapes or `count` turns the block at (x, y, z) shows, `drawOffset(id:
//!   i32, x: i64, y: i64, z: i64) ?[2]f32`, how far east and south of the middle of its place
//!   it's drawn, in blocks, and `isPlacedByPosition(id: i32) bool`, whether any of those depends
//!   on more than its sprites and its position;
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
pub const Sprites = @import("Sprites.zig");

/// Level-0 pixels from blocks: a block at (x, y, z) in the view's coordinates (`Rotation.toView`)
/// is drawn in the `blockWidth`-pixel square from ((x − z − 1) · `blockWidth` / 2,
/// (x + z) · `blockWidth` / 4 − (y + 1) · `blockWidth` / 2).
pub const projection = "isometric";

/// A block's width in level-0 pixels. Its top is a diamond this wide and half as tall, and its
/// sides reach down the other half of the square this size it fills.
pub const blockWidth = 32;
/// How far a block east or west is across the screen, and how far a block east or south is
/// down it, or a block below.
const across = blockWidth / 2;
const down = blockWidth / 4;
const below = blockWidth / 2;

const side = world.Chunk.side;

/// How far the viewer has moved clockwise, seen from above, from looking north-west. The view's
/// x runs right and down the screen and its z left and down, as east and south do at `deg0`, so
/// the sides of a cube it shows are those towards +z and +x.
pub const Rotation = enum(u2) {
    deg0,
    deg90,
    deg180,
    deg270,

    /// Its tiles' folder in the output.
    pub fn folder(self: Rotation) []const u8 {
        return switch (self) {
            .deg0 => "isometric",
            .deg90 => "isometric-90",
            .deg180 => "isometric-180",
            .deg270 => "isometric-270",
        };
    }

    pub fn title(self: Rotation) []const u8 {
        return switch (self) {
            .deg0 => "Isometric",
            .deg90 => "Isometric 90°",
            .deg180 => "Isometric 180°",
            .deg270 => "Isometric 270°",
        };
    }

    /// The view's coordinates of the block at (x, z) in the world.
    fn toView(self: Rotation, x: i64, z: i64) [2]i64 {
        return switch (self) {
            .deg0 => .{ x, z },
            .deg90 => .{ z, -1 - x },
            .deg180 => .{ -1 - x, -1 - z },
            .deg270 => .{ -1 - z, x },
        };
    }

    /// The world's coordinates of the block at (x, z) in the view.
    fn toWorld(self: Rotation, x: i64, z: i64) [2]i64 {
        return switch (self) {
            .deg0 => .{ x, z },
            .deg90 => .{ -1 - z, x },
            .deg180 => .{ -1 - x, -1 - z },
            .deg270 => .{ z, -1 - x },
        };
    }

    /// The view's coordinates of a point in a block, from 0 to 1 across it.
    fn pointToView(self: Rotation, x: f32, z: f32) [2]f32 {
        return switch (self) {
            .deg0 => .{ x, z },
            .deg90 => .{ z, 1 - x },
            .deg180 => .{ 1 - x, 1 - z },
            .deg270 => .{ 1 - z, x },
        };
    }

    /// The world's coordinates of a point in a block, from 0 to 1 across it.
    fn pointToWorld(self: Rotation, x: f32, z: f32) [2]f32 {
        return switch (self) {
            .deg0 => .{ x, z },
            .deg90 => .{ 1 - z, x },
            .deg180 => .{ 1 - x, 1 - z },
            .deg270 => .{ z, 1 - x },
        };
    }

    /// How far a distance east and south is along the view's x and z.
    fn distanceToView(self: Rotation, east: f32, south: f32) [2]f32 {
        return switch (self) {
            .deg0 => .{ east, south },
            .deg90 => .{ south, -east },
            .deg180 => .{ -east, -south },
            .deg270 => .{ -south, east },
        };
    }

    /// The change in the world's x and z from one block on a line of sight to the next.
    fn lineStep(self: Rotation) [2]i64 {
        return switch (self) {
            .deg0 => .{ -1, -1 },
            .deg90 => .{ 1, -1 },
            .deg180 => .{ 1, 1 },
            .deg270 => .{ -1, 1 },
        };
    }

    /// The faces of `cube` the view shows on its left and right.
    fn sides(self: Rotation, cube: *const world.CubeFaces) [2]world.CubeFaces.Face {
        return switch (self) {
            .deg0 => .{ cube.south, cube.east },
            .deg90 => .{ cube.west, cube.south },
            .deg180 => .{ cube.north, cube.west },
            .deg270 => .{ cube.east, cube.north },
        };
    }
};

test Rotation {
    for (std.enums.values(Rotation)) |rotation| {
        const x, const z = rotation.toView(5, -7);
        try std.testing.expectEqual([2]i64{ 5, -7 }, rotation.toWorld(x, z));
        const px, const pz = rotation.pointToView(0.25, 0.75);
        try std.testing.expectEqual([2]f32{ 0.25, 0.75 }, rotation.pointToWorld(px, pz));
        // Going further along a line of sight is one less in the view's x and z.
        const step = rotation.lineStep();
        try std.testing.expectEqual([2]i64{ x - 1, z - 1 }, rotation.toView(5 + step[0], -7 + step[1]));
    }
    // The way each rotation faces is away from the viewer, one less in the view's x and z.
    try std.testing.expectEqual([2]f32{ -1, -1 }, Rotation.deg0.distanceToView(-1, -1));
    try std.testing.expectEqual([2]f32{ -1, -1 }, Rotation.deg90.distanceToView(1, -1));
    try std.testing.expectEqual([2]f32{ -1, -1 }, Rotation.deg180.distanceToView(1, 1));
    try std.testing.expectEqual([2]f32{ -1, -1 }, Rotation.deg270.distanceToView(-1, 1));
}

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
    /// The sprites the `game` style draws blocks in (`drawSprites`), each block in those its
    /// source gives it (`spritesOf`); without them, it draws every block in its colour.
    sprites: ?*const Sprites = null,
    rotation: Rotation = .deg0,
};

/// Renders `source` into `output` and returns the tiles written, at every level, owned by the
/// caller. A game style other than `game` is error.UnknownStyle, and more different looks
/// than a chunk can number error.TooManyLooks.
pub fn render(comptime Source: type, allocator: std.mem.Allocator, io: Io, source: *const Source, output: tiles.Output, options: Options, stats: *Stats) ![]tiles.Written {
    const start: Io.Timestamp = .now(io, .awake);
    const rotated = if (options.sprites) |sprites| sprites.ofRotation(@backingInt(options.rotation)) else null;
    var view: View(Source) = try .init(allocator, source, options.style, if (rotated) |*sprites| sprites else null, options.rotation);
    defer view.deinit(allocator);
    const list = try tileList(allocator, source.chunkColumns, source.heights().world, options.rotation);
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

/// Where the blocks from (x0, y0, z0) to (x1, y1, z1), each included, in the view's coordinates,
/// are drawn, in level-0 pixels: from `left` and `top` up to but not including `right` and
/// `bottom`.
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

/// A line of sight: the blocks drawn on one square, each one less in the view's x and z and one
/// lower than the one before, further from the viewer. `u` is x − z and `v` is x + z − 2y, which
/// stay the same along it; they're both even or both odd.
const Line = struct {
    u: i64,
    v: i64,

    /// The view's x and z of its block at height `y`.
    fn at(self: Line, y: i64) [2]i64 {
        const sum = self.v + 2 * y;
        return .{ @divExact(sum + self.u, 2), @divExact(sum - self.u, 2) };
    }

    /// x + y + z of its block at height `y`, larger nearer.
    fn depth(self: Line, y: i64) i64 {
        return self.v + 3 * y;
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
        try std.testing.expectEqual(x + y + z, line.depth(y));
        try std.testing.expectEqual(Box.of(x, y, z, x, y, z), line.square());
    }
}

/// The chunks a worker has read: how each of their blocks is drawn (`View.blockLooks`), or that
/// a chunk has nothing to draw, which takes no room. It holds a fixed number of each, set up
/// once, and makes room by forgetting the one used longest ago.
const ChunkCache = struct {
    pub const Position = struct { x: i32, y: i32, z: i32 };
    pub const Looks = [world.Chunk.volume]u16;
    pub const Lookup = union(enum) { uncached, empty, slot: *const Slot };

    /// A liquid at the same place as a block that doesn't fill it: `place` in `Looks`, and the
    /// liquid's look.
    pub const Liquid = struct { place: u16, look: u16 };

    /// A chunk's looks: a place's block, and the liquids in the places of those that don't fill
    /// theirs, by place.
    pub const Slot = struct {
        looks: Looks,
        liquids: [maxLiquids]Liquid,
        liquidCount: u16,

        /// The test saves' fullest chunk has 980. Past it, a place shows without its liquid.
        pub const maxLiquids = 4096;

        fn addLiquid(self: *Slot, place: usize, look: u16) void {
            if (self.liquidCount == maxLiquids) return;
            self.liquids[self.liquidCount] = .{ .place = @intCast(place), .look = look };
            self.liquidCount += 1;
        }

        /// The look of the liquid in `place`, with a block; 0 for none.
        fn liquidAt(self: *const Slot, place: usize) u16 {
            const list = self.liquids[0..self.liquidCount];
            const i = std.sort.binarySearch(Liquid, list, place, struct {
                fn order(target: usize, item: Liquid) std.math.Order {
                    return std.math.order(target, item.place);
                }
            }.order) orelse return 0;
            return list[i].look;
        }
    };

    /// Chunks remembered, and how many of them can have blocks to draw: 80 KB each.
    pub const defaultChunks = 4096;
    pub const defaultChunksWithBlocks = 128;

    const Entry = struct {
        position: Position,
        /// Where its looks are in `slots`, or null for a chunk with nothing to draw.
        slot: ?u32,
        /// When it was last used, by `clock`.
        used: u64,
    };

    entries: []Entry,
    count: usize = 0,
    /// Each position's index in `entries`.
    byPosition: std.AutoHashMapUnmanaged(Position, u32),
    slots: []Slot,
    /// Slots no entry holds, the first `freeCount` of them.
    free: []u32,
    freeCount: usize,
    clock: u64 = 0,

    fn init(allocator: std.mem.Allocator, chunks: u32, chunksWithBlocks: u32) !ChunkCache {
        const entries = try allocator.alloc(Entry, chunks);
        errdefer allocator.free(entries);
        var byPosition: std.AutoHashMapUnmanaged(Position, u32) = .empty;
        try byPosition.ensureTotalCapacity(allocator, chunks);
        errdefer byPosition.deinit(allocator);
        const slots = try allocator.alloc(Slot, chunksWithBlocks);
        errdefer allocator.free(slots);
        const free = try allocator.alloc(u32, chunksWithBlocks);
        for (free, 0..) |*slot, i| slot.* = @intCast(i);
        return .{ .entries = entries, .byPosition = byPosition, .slots = slots, .free = free, .freeCount = free.len };
    }

    fn deinit(self: *ChunkCache, allocator: std.mem.Allocator) void {
        allocator.free(self.free);
        allocator.free(self.slots);
        self.byPosition.deinit(allocator);
        allocator.free(self.entries);
    }

    fn get(self: *ChunkCache, position: Position) Lookup {
        const index = self.byPosition.get(position) orelse return .uncached;
        const entry = &self.entries[index];
        self.clock += 1;
        entry.used = self.clock;
        return if (entry.slot) |slot| .{ .slot = &self.slots[slot] } else .empty;
    }

    /// Remembers `position`, which must not be cached yet, and returns where to write its looks
    /// if it has `blocks`, or null.
    fn put(self: *ChunkCache, position: Position, blocks: bool) ?*Slot {
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
        return if (slot) |s| &self.slots[s] else null;
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
    cache.put(a, true).?.looks[0] = 7;
    cache.put(b, true).?.looks[0] = 8;
    try std.testing.expect(cache.put(c, false) == null);
    try std.testing.expectEqual(7, cache.get(a).slot.looks[0]);
    try std.testing.expect(cache.get(c) == .empty);
    // No slot is free for d's blocks: b, used longest ago of the chunks with blocks, makes room.
    cache.put(d, true).?.looks[0] = 9;
    try std.testing.expect(cache.get(b) == .uncached);
    try std.testing.expectEqual(9, cache.get(d).slot.looks[0]);
    try std.testing.expectEqual(7, cache.get(a).slot.looks[0]);
    // Every entry is taken: c, now used longest ago, makes room for an empty chunk.
    try std.testing.expect(cache.put(b, false) == null);
    try std.testing.expect(cache.get(c) == .uncached);
    try std.testing.expect(cache.get(b) == .empty);
}

test "ChunkCache.Slot.liquidAt" {
    const slot = try std.testing.allocator.create(ChunkCache.Slot);
    defer std.testing.allocator.destroy(slot);
    slot.liquidCount = 0;
    try std.testing.expectEqual(0, slot.liquidAt(7));
    slot.addLiquid(7, 3);
    slot.addLiquid(900, 4);
    try std.testing.expectEqual(3, slot.liquidAt(7));
    try std.testing.expectEqual(4, slot.liquidAt(900));
    try std.testing.expectEqual(0, slot.liquidAt(8));
    // Past what it holds, a place has none.
    for (0..ChunkCache.Slot.maxLiquids) |i| slot.addLiquid(1000 + i, 5);
    try std.testing.expectEqual(ChunkCache.Slot.maxLiquids, slot.liquidCount);
    try std.testing.expectEqual(5, slot.liquidAt(1000));
    try std.testing.expectEqual(0, slot.liquidAt(1000 + ChunkCache.Slot.maxLiquids - 1));
}

/// The tiles the chunk columns are drawn on, from the bottom of the world to its top.
fn tileList(allocator: std.mem.Allocator, columns: []const world.ChunkColumn, height: u16, rotation: Rotation) ![]tiles.Tile {
    var set: std.AutoArrayHashMapUnmanaged(tiles.Tile, void) = .empty;
    defer set.deinit(allocator);
    for (columns) |column| {
        const x = @as(i64, column.x) * side;
        const z = @as(i64, column.z) * side;
        const ax, const az = rotation.toView(x, z);
        const bx, const bz = rotation.toView(x + side - 1, z + side - 1);
        const box: Box = .of(@min(ax, bx), 0, @min(az, bz), @max(ax, bx), @as(i64, height) - 1, @max(az, bz));
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
    const list = try tileList(std.testing.allocator, &.{.{ .x = 0, .z = 0 }}, 256, .deg0);
    defer std.testing.allocator.free(list);
    const columns = @divFloor(box.right - 1, tiles.size) - @divFloor(box.left, tiles.size) + 1;
    const rows = @divFloor(box.bottom - 1, tiles.size) - @divFloor(box.top, tiles.size) + 1;
    try std.testing.expectEqual(@as(usize, @intCast(columns * rows)), list.len);

    // Turned half way, the column is in the blocks from −32 to −1 of the view.
    const turned = try tileList(std.testing.allocator, &.{.{ .x = 0, .z = 0 }}, 256, .deg180);
    defer std.testing.allocator.free(turned);
    const far = Box.of(-32, 0, -32, -1, 255, -1);
    try std.testing.expect(turned.len > 0);
    for (turned) |tile| {
        try std.testing.expect(tile.x * tiles.size < far.right and (tile.x + 1) * tiles.size > far.left);
        try std.testing.expect(tile.y * tiles.size < far.bottom and (tile.y + 1) * tiles.size > far.top);
    }
}

/// How each face of a block's square is lit, by pixel. The left and right faces are those towards
/// the view's +z and +x, which are south and east only at `Rotation.deg0`.
const Face = enum { none, top, left, right };

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
            .right
        else if (x < a and y > d + x * d / a and y < d + below + x * d / a)
            .left
        else
            .none;
    };
    break :faces out;
};

test faces {
    // The top face fills the middle of the top half, and the other two the left and right of the
    // bottom half; the corners are empty.
    const w = blockWidth;
    try std.testing.expectEqual(Face.top, faces[w / 4][w / 2]);
    try std.testing.expectEqual(Face.none, faces[0][0]);
    try std.testing.expectEqual(Face.left, faces[w * 5 / 8][w / 4]);
    try std.testing.expectEqual(Face.right, faces[w * 5 / 8][w * 3 / 4]);
    try std.testing.expectEqual(Face.none, faces[w - 1][0]);
    // Each face is a quarter of the square.
    var counts: std.EnumArray(Face, usize) = .initFill(0);
    for (faces) |row| for (row) |face| {
        counts.getPtr(face).* += 1;
    };
    for ([_]Face{ .top, .left, .right }) |face| try std.testing.expectEqual(blockWidth * blockWidth / 4, counts.get(face));
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
const light = std.EnumArray(Face, u16).init(.{ .none = 0, .top = 256, .left = 208, .right = 176 });

/// What a tile's depth buffer counts in: `depthSteps`ths of a block, of x + y + z of the point
/// each pixel shows in the view's coordinates, larger nearer.
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
            .left => x / a + (1 - (y - d * x / a - d) / b) + 1,
            .right => 1 + (1 - (y - d - d * (2 - x / a)) / b) + (2 - x / a),
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
/// `(mapType * heights.world + y) * 3`, top, left, right.
fn reliefColours(allocator: std.mem.Allocator, palette: *const world.Palette, heights: world.Heights) ![]u32 {
    const types = std.enums.values(world.MapType);
    const colours = try allocator.alloc(u32, types.len * heights.world * 3);
    const shades: relief.Heights = .of(heights);
    for (types) |mapType| for (0..heights.world) |y| {
        const base = palette.colours.get(mapType);
        const colour = if (mapType.isLiquid()) relief.liquidColour(base, 0) else relief.groundColour(palette, base, @intCast(y), shades, 0);
        const at = (@backingInt(mapType) * heights.world + y) * 3;
        colours[at] = lit(colour, light.get(.top));
        colours[at + 1] = lit(colour, light.get(.left));
        colours[at + 2] = lit(colour, light.get(.right));
    };
    return colours;
}

/// A colour's top, left and right faces, lit.
fn faceColours(colour: world.Rgb) [3]u32 {
    const pixel = tiles.rgba(colour[0], colour[1], colour[2], 255);
    return .{ lit(pixel, light.get(.top)), lit(pixel, light.get(.left)), lit(pixel, light.get(.right)) };
}

const Sprite = Sprites.Sprite;
const SpriteLayers = Sprites.SpriteLayers;

/// Draws `cube`'s sprite in its variant `variant`, as `rotation` shows it, into `sections`.
fn cubeSprite(sections: *Sprites.Sections, allocator: std.mem.Allocator, cube: *const world.CubeFaces, variant: usize, fallback: world.Rgb, rotation: Rotation) !void {
    const left, const right = rotation.sides(cube);
    const room = try sections.add(allocator, .{
        .left = 0,
        .top = 0,
        .width = blockWidth,
        .height = blockWidth,
        .flags = .{ .tinted = cube.up.tinted.len > 0 or left.tinted.len > 0 or right.tinted.len > 0, .fills = true },
    });
    cubeLayers(cube, variant, fallback, rotation, room.plain, room.tinted);
    @memcpy(room.depths, @as(*const [blockWidth * blockWidth]i16, @ptrCast(&cubeDepths)));
}

/// Points sampled across and down each pixel of a sprite.
const samples = 2;

/// How many sprites `cube` has: as many as the most variants any of its layers has.
fn variantCount(cube: *const world.CubeFaces) usize {
    var count: usize = 1;
    for ([_]world.CubeFaces.Face{ cube.up, cube.south, cube.east, cube.north, cube.west }) |face| count = @max(count, face.plain.len, face.tinted.len);
    return count;
}

/// Draws `cube` in its textures, as `rotation` shows it, each layer in its variant `variant`
/// (counting round again for a layer with fewer): each pixel of a layer is the average of its
/// texels under it. A plain pixel over only transparent texels is `fallback`. `plain` takes the
/// faces' plain layers, opaque on every face and transparent where none is, and `tinted`, where
/// any face has one, their tinted layers, lit but not yet tinted, each pixel's alpha how much of
/// it the layer covers.
fn cubeLayers(cube: *const world.CubeFaces, variant: usize, fallback: world.Rgb, rotation: Rotation, plain: []u32, tinted: ?[]u32) void {
    const left, const right = rotation.sides(cube);
    for (0..blockWidth) |row| for (0..blockWidth) |column| {
        const p = row * blockWidth + column;
        const face = faces[row][column];
        const layers = switch (face) {
            .none => {
                plain[p] = tiles.transparent;
                if (tinted) |out| out[p] = tiles.transparent;
                continue;
            },
            .top => cube.up,
            .left => left,
            .right => right,
        };
        const texel = average(face, rotation, column, row, pick(layers.plain, variant));
        const colour = if (texel[3] == 0) fallback else texel[0..3].*;
        plain[p] = lit(tiles.rgba(colour[0], colour[1], colour[2], 255), light.get(face));
        const out = tinted orelse continue;
        var layer = average(face, rotation, column, row, pick(layers.tinted, variant));
        // A face that's all tinted, as leaves are, has its holes filled with `fallback` to be
        // tinted too, rather than showing what's under it untinted.
        if (layers.plain.len == 0 and layers.tinted.len > 0) layer = if (layer[3] == 0) fallback ++ [1]u8{255} else layer[0..3].* ++ [1]u8{255};
        out[p] = lit(tiles.rgba(layer[0], layer[1], layer[2], layer[3]), light.get(face));
    };
}

/// A layer's variant `variant`, counting round again past its last; null without the layer.
fn pick(variants: []const *const world.Image, variant: usize) ?*const world.Image {
    return if (variants.len == 0) null else variants[variant % variants.len];
}

/// The average of `image`'s texels under a pixel of a face, by their opacity, and how opaque
/// they are on average; transparent without an image.
fn average(face: Face, rotation: Rotation, column: usize, row: usize, image: ?*const world.Image) [4]u8 {
    const texture = image orelse return @splat(0);
    var sum: [4]u32 = @splat(0);
    for (0..samples) |sy| for (0..samples) |sx| {
        const x = @as(f32, @floatFromInt(column)) + (@as(f32, @floatFromInt(sx)) + 0.5) / samples;
        const y = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples;
        const u, const v = textureCoordinates(face, rotation, x, y);
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

/// A sprite's pixel: its tinted layer, times `tint`, drawn over its plain one by how much it
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
/// it, each from 0 to 1. A point at (x, y, z) in the view, block (0, 0, 0) being the cube from 0
/// to 1, is drawn at ((x − z + 1) · `across`, (x + z) · `down` − (y − 1) · `below`) in its square.
/// Seen from outside, a side's texture reads the same way round in every rotation, and a top's
/// turns with the view, as its north stays north.
fn textureCoordinates(face: Face, rotation: Rotation, x: f32, y: f32) [2]f32 {
    const a: f32 = across;
    const d: f32 = down;
    const b: f32 = below;
    const coordinates: [2]f32 = switch (face) {
        .none => unreachable,
        // At height 1.
        .top => rotation.pointToWorld((x / a - 1 + y / d) / 2, (y / d - x / a + 1) / 2),
        // At the view's z = 1.
        .left => .{ x / a, 1 - ((x / a + 1) * d + b - y) / b },
        // At the view's x = 1.
        .right => .{ x / a - 1, 1 - ((3 - x / a) * d + b - y) / b },
    };
    return .{ std.math.clamp(coordinates[0], 0, 1), std.math.clamp(coordinates[1], 0, 1) };
}

test textureCoordinates {
    const w: f32 = blockWidth;
    // Each face's corners: the top's highest is its texture's top left (north-west), and its
    // leftmost the bottom left (south-west).
    try std.testing.expectEqual([2]f32{ 0, 0 }, textureCoordinates(.top, .deg0, w / 2, 0));
    try std.testing.expectEqual([2]f32{ 0, 1 }, textureCoordinates(.top, .deg0, 0, w / 4));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.top, .deg0, w / 2, w / 2));
    try std.testing.expectEqual([2]f32{ 0, 0 }, textureCoordinates(.left, .deg0, 0, w / 4));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.left, .deg0, w / 2, w));
    try std.testing.expectEqual([2]f32{ 0, 0 }, textureCoordinates(.right, .deg0, w / 2, w / 2));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.right, .deg0, w, w * 3 / 4));
    // The top's highest corner is the far one: north-east at 90°, south-east at 180° and
    // south-west at 270°.
    try std.testing.expectEqual([2]f32{ 1, 0 }, textureCoordinates(.top, .deg90, w / 2, 0));
    try std.testing.expectEqual([2]f32{ 1, 1 }, textureCoordinates(.top, .deg180, w / 2, 0));
    try std.testing.expectEqual([2]f32{ 0, 1 }, textureCoordinates(.top, .deg270, w / 2, 0));
    // The sides are the same whichever faces they are.
    try std.testing.expectEqual(textureCoordinates(.left, .deg0, 3, w / 2), textureCoordinates(.left, .deg180, 3, w / 2));
}

const texelAt = rasterizer.texelAt;

/// How many sprites `shape` has: as many as the most variants any of its textures has.
fn shapeVariants(shape: *const world.Shape) usize {
    var count: usize = 1;
    for (shape.textures) |texture| count = @max(count, texture.plain.len, texture.tinted.len);
    return count;
}

/// How far beyond a cube's square a shape's sprite reaches, in pixels, each way: parts of a
/// shape farther out are cut off.
const reach = blockWidth;

/// How far a block moved off the middle of its place (`drawOffset`), less than half a block
/// east and south, can move its sprite, in pixels.
const shift = blockWidth / 2;

/// The side of what a shape's sprite is drawn in (`ShapeTarget`), in pixels.
const shapeSide = blockWidth + 2 * reach;

/// What a shape's sprite is drawn in first: `samples` × `samples` points for each of its
/// pixels, over the cube's square and `reach` around it.
const ShapeTarget = rasterizer.Target;

fn shapeTarget(allocator: std.mem.Allocator) !ShapeTarget {
    return .init(allocator, shapeSide * samples, shapeSide * samples);
}

/// How many ways a block turned by where it is can be turned (`Drawable.turned`), about the
/// vertical line through the middle of its place: turn i by −22.5° + 45° · i, as vsapi
/// `TesselationMetaData.randomRotations` lists them, from east towards north.
pub const turns = 8;

/// Draws `shape` in its textures, as `rotation` shows it, each in its variant `variant` (counting
/// round again for one with fewer), in turn `turn` of `turns`, or unturned for null, its faces lit
/// by the way they face in the view. Each of its pixels is drawn at `samples` × `samples` points:
/// it shows if at least half of them are covered, the average of their colours, the depth of the
/// nearest. Added to `sections`, trimmed to the pixels it shows, and returned with its layers
/// there.
fn shapeSprite(sections: *Sprites.Sections, allocator: std.mem.Allocator, shape: *const world.Shape, variant: usize, turn: ?usize, rotation: Rotation, target: *ShapeTarget) !struct { Sprite, SpriteLayers } {
    std.debug.assert(target.width == shapeSide * samples and target.height == shapeSide * samples);
    target.clear();
    const scale: f32 = samples;
    const angle = if (turn) |i| (@as(f32, @floatFromInt(i)) - 0.5) * std.math.tau / turns else 0;
    const cos = @cos(angle);
    const sin = @sin(angle);
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
            const east = point[0] - 0.5;
            const south = point[2] - 0.5;
            point[0] = cos * east + sin * south + 0.5;
            point[2] = cos * south - sin * east + 0.5;
            point[0], point[2] = rotation.pointToView(point[0], point[2]);
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
        var opaque_: usize = 0;
        for (0..samples) |sy| for (0..samples) |sx| {
            const at = (row * samples + sy) * target.width + column * samples + sx;
            const tag = target.tags[at];
            covered += @intFromBool(tag != 0);
            opaque_ += @intFromBool(tag != 0 and target.colours[at][3] == 255);
            anyTinted = anyTinted or tag == 2;
        };
        shown[row][column] = covered * 2 >= samples * samples;
        const inSquare = row >= reach and row < reach + blockWidth and column >= reach and column < reach + blockWidth;
        if (inSquare and faces[row - reach][column - reach] != .none and (!shown[row][column] or opaque_ < covered)) fills = false;
        if (!shown[row][column]) continue;
        first = .{ @min(first[0], row), @min(first[1], column) };
        last = .{ @max(last[0], row), @max(last[1], column) };
    };
    const height = if (first[0] > last[0]) 0 else last[0] - first[0] + 1;
    const width = if (first[1] > last[1]) 0 else last[1] - first[1] + 1;

    const sprite: Sprite = .{
        .left = @as(i16, @intCast(first[1])) - reach,
        .top = @as(i16, @intCast(first[0])) - reach,
        .width = @intCast(width),
        .height = @intCast(height),
        .flags = .{ .tinted = anyTinted, .fills = fills },
    };
    const room = try sections.add(allocator, sprite);
    const plain = room.plain;
    const tinted = room.tinted;
    const depths = room.depths;
    for (0..height) |y| for (0..width) |x| {
        const row = first[0] + y;
        const column = first[1] + x;
        const p = y * width + x;
        plain[p] = tiles.transparent;
        if (tinted) |layer| layer[p] = tiles.transparent;
        depths[p] = 0;
        if (!shown[row][column]) continue;
        var sums: [3][4]u32 = @splat(@splat(0));
        var opacity: u32 = 0;
        var nearest: f32 = -std.math.inf(f32);
        for (0..samples) |sy| for (0..samples) |sx| {
            const at = (row * samples + sy) * target.width + column * samples + sx;
            const tag = target.tags[at];
            for (0..3) |c| sums[tag][c] += target.colours[at][c];
            sums[tag][3] += 1;
            opacity += target.colours[at][3];
            if (tag != 0) nearest = @max(nearest, target.depths[at]);
        };
        const covered = sums[1][3] + sums[2][3];
        // The tinted layer covers the plain one as much as it covers the pixel; a pixel all
        // tinted takes its plain layer from it, unseen under it.
        const under = if (sums[1][3] > 0) sums[1] else sums[2];
        plain[p] = tiles.rgba(@intCast(under[0] / under[3]), @intCast(under[1] / under[3]), @intCast(under[2] / under[3]), @intCast(opacity / covered));
        if (sums[2][3] > 0) {
            const t = sums[2];
            tinted.?[p] = tiles.rgba(@intCast(t[0] / t[3]), @intCast(t[1] / t[3]), @intCast(t[2] / t[3]), @intCast(t[3] * 255 / covered));
        }
        depths[p] = @intFromFloat(@round(nearest * depthSteps));
    };
    return .{ sprite, .{ .plain = plain, .tinted = tinted, .depths = depths } };
}

/// What a game's reader has for drawing one of its blocks in sprites: a cube's faces, or the
/// shapes it picks one of by where it is, the colour that fills a cube's texture's holes, whether
/// a shape is turned by where it is, which draws it in each of its `turns`, and whether a shape
/// keeps how opaque its textures are (`rasterizer.Target.keepsOpacity`), as glass does.
pub const Drawable = struct {
    cube: ?*const world.CubeFaces = null,
    shapes: []const world.Shape = &.{},
    colour: world.Rgb = @splat(0),
    turned: bool = false,
    seeThrough: bool = false,
};

/// Which sprites every block has, before any is drawn, so `sprite_layers` has its place in the
/// file (`Sprites.Sections`) ahead of the `sprites` section, whose length depends on `count`. The
/// same in every rotation.
pub const SpritePlan = struct {
    /// By the block's index in the `Drawable`s.
    blocks: []world.BlockSprites,
    count: usize,
};

/// Whether any face of `cube` has a tinted layer, as whichever faces a rotation shows might.
fn hasTintedFace(cube: *const world.CubeFaces) bool {
    for ([_]world.CubeFaces.Face{ cube.up, cube.south, cube.east, cube.north, cube.west }) |face| {
        if (face.tinted.len > 0) return true;
    }
    return false;
}

/// Whether any texture of `shapes` has a tinted layer.
fn hasTintedTexture(shapes: []const world.Shape) bool {
    for (shapes) |shape| for (shape.textures) |texture| {
        if (texture.tinted.len > 0) return true;
    };
    return false;
}

/// One run of sprites for each variant of a block's textures, in each of its shapes, in each of
/// its turns. Blocks with the same faces, or the same shapes and textures turned alike, share
/// a run. A block's textures have as many variants as the most any of its shapes' has, each with
/// fewer counting round again.
pub fn planSprites(arena: std.mem.Allocator, drawables: []const Drawable) !SpritePlan {
    const blocks = try arena.alloc(world.BlockSprites, drawables.len);
    var byFaces: std.HashMapUnmanaged(world.CubeFaces, world.BlockSprites, FacesContext, std.hash_map.default_max_load_percentage) = .empty;
    var byShape: std.HashMapUnmanaged(ShapeKey, world.BlockSprites, ShapeContext, std.hash_map.default_max_load_percentage) = .empty;
    var count: usize = 0;
    for (blocks, drawables) |*block, drawable| {
        block.* = .{};
        if (drawable.cube) |cube| {
            const found = try byFaces.getOrPut(arena, cube.*);
            if (!found.found_existing) {
                found.value_ptr.* = .{ .first = @intCast(count), .variants = @intCast(variantCount(cube)), .tinted = hasTintedFace(cube) };
                count += found.value_ptr.count();
            }
            block.* = found.value_ptr.*;
        } else if (drawable.shapes.len > 0) {
            const found = try byShape.getOrPut(arena, .{ .shapes = drawable.shapes, .turned = drawable.turned, .seeThrough = drawable.seeThrough });
            if (!found.found_existing) {
                var variants: usize = 1;
                for (drawable.shapes) |*shape| variants = @max(variants, shapeVariants(shape));
                found.value_ptr.* = .{
                    .first = @intCast(count),
                    .variants = @intCast(variants),
                    .alternates = @intCast(drawable.shapes.len),
                    .turns = if (drawable.turned) turns else 1,
                    .shape = true,
                    .tinted = hasTintedTexture(drawable.shapes),
                };
                count += found.value_ptr.count();
            }
            block.* = found.value_ptr.*;
        }
    }
    return .{ .blocks = blocks, .count = count };
}

/// Draws the sprites `plan` lists into `sections`, in every rotation, one rotation after another
/// and one sprite at a time, each run by the first block that has it. Sprites that come out the
/// same share their layers, as most of a rotation's are another's: a turned plant's every eighth
/// of a circle, for one.
pub fn drawSprites(arena: std.mem.Allocator, drawables: []const Drawable, plan: SpritePlan, sections: *Sprites.Sections) !void {
    var target = try shapeTarget(arena);
    try sections.ensureCapacity(arena, plan.count * Sprites.rotationCount);
    for (std.enums.values(Rotation), 0..) |rotation, quarter| {
        const earlier = quarter * plan.count;
        for (plan.blocks, drawables) |block, drawable| {
            if (block.variants == 0 or block.first + earlier != sections.entries.items.len) continue;
            if (drawable.cube) |cube| {
                for (0..block.variants) |variant| {
                    try cubeSprite(sections, arena, cube, variant, drawable.colour, rotation);
                    try sections.shareLast(arena);
                }
            } else {
                target.keepsOpacity = drawable.seeThrough;
                for (0..block.turns) |turn| for (drawable.shapes) |*shape| for (0..block.variants) |variant| {
                    _ = try shapeSprite(sections, arena, shape, variant, if (drawable.turned) turn else null, rotation, &target);
                    try sections.shareLast(arena);
                };
            }
        }
    }
}

/// Cube faces by their variants' slices, which a game's reader shares between blocks with the
/// same faces.
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

const ShapeKey = struct { shapes: []const world.Shape, turned: bool, seeThrough: bool };

/// A block's shapes by their boxes' slices and their textures' variants' slices, which a game's
/// reader shares between blocks with the same shapes and textures, and whether they're turned and
/// see-through.
const ShapeContext = struct {
    pub fn hash(_: ShapeContext, key: ShapeKey) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        std.hash.autoHash(&hasher, key.turned);
        std.hash.autoHash(&hasher, key.seeThrough);
        for (key.shapes) |shape| {
            std.hash.autoHashStrat(&hasher, shape.boxes, .Shallow);
            for (shape.textures) |texture| std.hash.autoHashStrat(&hasher, texture, .Shallow);
        }
        return hasher.final();
    }

    pub fn eql(_: ShapeContext, a: ShapeKey, b: ShapeKey) bool {
        if (a.turned != b.turned or a.seeThrough != b.seeThrough or a.shapes.len != b.shapes.len) return false;
        for (a.shapes, b.shapes) |x, y| {
            if (x.boxes.ptr != y.boxes.ptr or x.boxes.len != y.boxes.len or x.textures.len != y.textures.len) return false;
            for (x.textures, y.textures) |p, q| if (!std.meta.eql(p, q)) return false;
        }
        return true;
    }
};

/// How a face with corners at `points`, in the view's coordinates, is lit, in 256ths: as a cube's
/// top, left and right faces are, by how much it faces up, +z and +x, and a face turned away from
/// the viewer as though turned towards it, as a plant's leaf is seen from either side.
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
    const top: f32 = @floatFromInt(if (y >= 0) light.get(.top) else light.get(.right));
    const sum = x * x * @as(f32, @floatFromInt(light.get(.right))) + y * y * top + z * z * @as(f32, @floatFromInt(light.get(.left)));
    return @intFromFloat(@round(sum));
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

/// A cube's square drawn in its textures, for testing `cubeLayers`.
const CubeLayers = struct {
    plain: [blockWidth * blockWidth]u32,
    tinted: ?[blockWidth * blockWidth]u32,

    fn of(cube: *const world.CubeFaces, variant: usize, fallback: world.Rgb) CubeLayers {
        var out: CubeLayers = .{ .plain = undefined, .tinted = undefined };
        out.tinted = if (cube.up.tinted.len > 0 or cube.south.tinted.len > 0 or cube.east.tinted.len > 0) out.plain else null;
        cubeLayers(cube, variant, fallback, .deg0, &out.plain, if (out.tinted) |*tinted| tinted else null);
        return out;
    }
};

test cubeLayers {
    const red: [4][4]u8 = @splat(.{ 200, 0, 0, 255 });
    const grass = [_][4]u8{ .{ 0, 100, 0, 255 }, .{ 0, 100, 0, 255 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    const soil: world.Image = .{ .width = 2, .height = 2, .pixels = &red };
    const fringe: world.Image = .{ .width = 2, .height = 2, .pixels = &grass };
    const grassy: world.CubeFaces.Face = .{ .plain = &.{&soil}, .tinted = &.{&fringe} };
    const layers: CubeLayers = .of(&.{ .up = .{ .plain = &.{&soil} }, .south = grassy, .east = grassy, .north = grassy, .west = grassy }, 0, .{ 1, 2, 3 });
    const w = blockWidth;
    const white: world.Rgb = @splat(255);
    try std.testing.expectEqual(tiles.transparent, layers.plain[0]);
    const top = (w / 4) * w + w / 2;
    try std.testing.expectEqual(faceColours(.{ 200, 0, 0 })[0], blend(layers.plain[top], layers.tinted.?[top], white));
    // The sides' top half is the fringe over the soil, tinted, and their bottom half the soil.
    const fringed = (w * 3 / 8) * w + w / 4;
    try std.testing.expectEqual(faceColours(.{ 0, 100, 0 })[1], blend(layers.plain[fringed], layers.tinted.?[fringed], white));
    try std.testing.expectEqual(faceColours(.{ 0, 0, 0 })[1], blend(layers.plain[fringed], layers.tinted.?[fringed], .{ 255, 0, 255 }));
    const bare = (w * 3 / 4) * w + w * 3 / 4;
    try std.testing.expectEqual(faceColours(.{ 200, 0, 0 })[2], blend(layers.plain[bare], layers.tinted.?[bare], .{ 0, 0, 0 }));
    // Without a tinted layer, there's none to blend.
    const plain: world.CubeFaces.Face = .{ .plain = &.{&soil} };
    try std.testing.expectEqual(null, CubeLayers.of(&.{ .up = plain, .south = plain, .east = plain, .north = plain, .west = plain }, 0, .{ 1, 2, 3 }).tinted);

    // A top with two variants: the second sprite has the second, and the sides, with one,
    // their only one.
    const blue: [4][4]u8 = @splat(.{ 0, 0, 200, 255 });
    const water: world.Image = .{ .width = 2, .height = 2, .pixels = &blue };
    const varied: world.CubeFaces = .{ .up = .{ .plain = &.{ &soil, &water } }, .south = plain, .east = plain, .north = plain, .west = plain };
    try std.testing.expectEqual(2, variantCount(&varied));
    const second: CubeLayers = .of(&varied, 1, .{ 1, 2, 3 });
    try std.testing.expectEqual(faceColours(.{ 0, 0, 200 })[0], second.plain[top]);
    try std.testing.expectEqual(faceColours(.{ 200, 0, 0 })[2], second.plain[bare]);

    // Leaves, all tinted: the holes in the bottom half take the fallback, and are tinted too.
    const leafy: world.CubeFaces.Face = .{ .tinted = &.{&fringe} };
    const leaves: CubeLayers = .of(&.{ .up = leafy, .south = leafy, .east = leafy, .north = leafy, .west = leafy }, 0, .{ 100, 100, 100 });
    // Grey 100 lit as a right face is 68, then tinted by 127 of 255, 33.
    try std.testing.expectEqual(tiles.rgba(0, 33, 0, 255), blend(leaves.plain[bare], leaves.tinted.?[bare], .{ 0, 127, 0 }));

    // Each rotation shows the two sides towards the viewer, each lit by where it is on the
    // screen, and a top turned with the view.
    const sideColours = [4][1][4]u8{ .{.{ 10, 0, 0, 255 }}, .{.{ 20, 0, 0, 255 }}, .{.{ 30, 0, 0, 255 }}, .{.{ 40, 0, 0, 255 }} };
    const southImage: world.Image = .{ .width = 1, .height = 1, .pixels = &sideColours[0] };
    const eastImage: world.Image = .{ .width = 1, .height = 1, .pixels = &sideColours[1] };
    const northImage: world.Image = .{ .width = 1, .height = 1, .pixels = &sideColours[2] };
    const westImage: world.Image = .{ .width = 1, .height = 1, .pixels = &sideColours[3] };
    const cornered: [4][4]u8 = .{ .{ 50, 0, 0, 255 }, .{ 60, 0, 0, 255 }, .{ 70, 0, 0, 255 }, .{ 80, 0, 0, 255 } };
    const topImage: world.Image = .{ .width = 2, .height = 2, .pixels = &cornered };
    const sided: world.CubeFaces = .{
        .up = .{ .plain = &.{&topImage} },
        .south = .{ .plain = &.{&southImage} },
        .east = .{ .plain = &.{&eastImage} },
        .north = .{ .plain = &.{&northImage} },
        .west = .{ .plain = &.{&westImage} },
    };
    const expected = [4]struct { left: u8, right: u8, far: u8 }{
        .{ .left = 10, .right = 20, .far = 50 },
        .{ .left = 40, .right = 10, .far = 60 },
        .{ .left = 30, .right = 40, .far = 80 },
        .{ .left = 20, .right = 30, .far = 70 },
    };
    for (std.enums.values(Rotation), expected) |rotation, want| {
        var pixels: [w * w]u32 = undefined;
        cubeLayers(&sided, 0, .{ 0, 0, 0 }, rotation, &pixels, null);
        try std.testing.expectEqual(faceColours(.{ want.left, 0, 0 })[1], pixels[(w * 5 / 8) * w + w / 4]);
        try std.testing.expectEqual(faceColours(.{ want.right, 0, 0 })[2], pixels[(w * 5 / 8) * w + w * 3 / 4]);
        try std.testing.expectEqual(faceColours(.{ want.far, 0, 0 })[0], pixels[1 * w + w / 2]);
    }
}

/// A box from (0, 0, 0) to `size`, unturned, each face showing the whole of texture 0.
fn testBox(size: [3]f32) world.Shape.Box {
    const face: world.Shape.Face = .{ .texture = 0, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } };
    return .{ .transform = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } }, .size = size, .shade = true, .faces = @splat(face) };
}

/// The index in `sprite` of the pixel at (`row`, `column`) of the cube's square, or null if the
/// sprite doesn't reach it.
fn pixelAt(sprite: *const Sprite, row: i64, column: i64) ?usize {
    const y = row - sprite.top;
    const x = column - sprite.left;
    if (y < 0 or y >= sprite.height or x < 0 or x >= sprite.width) return null;
    return @intCast(y * sprite.width + x);
}

test shapeSprite {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var target = try shapeTarget(allocator);
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "sprites", .{ .read = true });
    defer file.close(io);
    var buffer: [Sprites.Sections.bufferLength]u8 align(4) = undefined;
    var sections: Sprites.Sections = .init(io, file, 0, &buffer);
    const red: [4][4]u8 = @splat(.{ 200, 0, 0, 255 });
    const image: world.Image = .{ .width = 2, .height = 2, .pixels = &red };
    const textures = [_]world.CubeFaces.Face{.{ .plain = &.{&image} }};
    const w = blockWidth;
    const top = [2]i64{ w / 4, w / 2 };
    const south = [2]i64{ w * 5 / 8, w / 4 };
    const east = [2]i64{ w * 5 / 8, w * 3 / 4 };

    // A whole block's box is the cube, filling the square, its faces lit as a cube's and each
    // pixel as deep as a cube's.
    const cube, const cubePixels = try shapeSprite(&sections, allocator, &.{ .boxes = &.{testBox(.{ 1, 1, 1 })}, .textures = &textures }, 0, null, .deg0, &target);
    try std.testing.expectEqual([4]i64{ 0, 0, w, w }, [4]i64{ cube.left, cube.top, cube.width, cube.height });
    try std.testing.expect(cube.flags.fills);
    try std.testing.expect(!cube.flags.tinted);
    try std.testing.expectEqual(null, cubePixels.tinted);
    const colours = faceColours(.{ 200, 0, 0 });
    for ([_][2]i64{ top, south, east }, colours) |at, colour| {
        const p = pixelAt(&cube, at[0], at[1]).?;
        try std.testing.expectEqual(colour, cubePixels.plain[p]);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(cubeDepths[@intCast(at[0])][@intCast(at[1])])), @as(f32, @floatFromInt(cubePixels.depths[p])), depthSteps / 16);
    }
    try std.testing.expect(!cubePixels.shows(pixelAt(&cube, 0, 0).?));

    // A slab leaves the top of the square empty, for what's behind it to show.
    const slab, const slabPixels = try shapeSprite(&sections, allocator, &.{ .boxes = &.{testBox(.{ 1, 0.5, 1 })}, .textures = &textures }, 0, null, .deg0, &target);
    try std.testing.expect(!slab.flags.fills);
    try std.testing.expectEqual(w / 4, slab.top);
    try std.testing.expectEqual(null, pixelAt(&slab, w / 8, w / 2));
    try std.testing.expectEqual(colours[1], slabPixels.plain[pixelAt(&slab, w * 3 / 4, w / 4).?]);

    // A plank twice as long as the block reaches out of its square both ways, drawn whole.
    var plank = testBox(.{ 2, 1.0 / 16.0, 1 });
    plank.transform[0][3] = -0.5;
    const long, _ = try shapeSprite(&sections, allocator, &.{ .boxes = &.{plank}, .textures = &textures }, 0, null, .deg0, &target);
    try std.testing.expectEqual(-w / 4, long.left);
    try std.testing.expectEqual(w + w / 2, long.width);

    // A tinted texture goes into the tinted layer, covering the plain one.
    const tinted = [_]world.CubeFaces.Face{.{ .tinted = &.{&image} }};
    const grass, const grassPixels = try shapeSprite(&sections, allocator, &.{ .boxes = &.{testBox(.{ 1, 1, 1 })}, .textures = &tinted }, 0, null, .deg0, &target);
    try std.testing.expect(grass.flags.tinted);
    const p = pixelAt(&grass, top[0], top[1]).?;
    try std.testing.expectEqual(colours[0], grassPixels.tinted.?[p]);
    try std.testing.expectEqual(colours[0], blend(grassPixels.plain[p], grassPixels.tinted.?[p], @splat(255)));

    // A wall along the east of its place, in turn 4, 157.5°, is along the west: its face towards
    // the middle shows where, unturned, nothing did.
    var wall = testBox(.{ 0.25, 1, 1 });
    wall.transform[0][3] = 0.75;
    const shape: world.Shape = .{ .boxes = &.{wall}, .textures = &textures };
    const middle = [2]i64{ w / 2, w * 5 / 16 };
    const unturned, _ = try shapeSprite(&sections, allocator, &shape, 0, null, .deg0, &target);
    try std.testing.expectEqual(null, pixelAt(&unturned, middle[0], middle[1]));
    const turned, const turnedPixels = try shapeSprite(&sections, allocator, &shape, 0, turns / 2, .deg0, &target);
    try std.testing.expect(turnedPixels.shows(pixelAt(&turned, middle[0], middle[1]).?));

    // Turns 0 and 7, −22.5° and −67.5°, are as far either side of south-east, where the view
    // looks from, so a post east of the middle is drawn as far right of the middle in one as
    // left in the other.
    var post = testBox(.{ 0.125, 1, 0.125 });
    post.transform[0][3] = 0.8125;
    post.transform[2][3] = 0.4375;
    const postShape: world.Shape = .{ .boxes = &.{post}, .textures = &textures };
    const right, _ = try shapeSprite(&sections, allocator, &postShape, 0, 0, .deg0, &target);
    const left, _ = try shapeSprite(&sections, allocator, &postShape, 0, 7, .deg0, &target);
    try std.testing.expect(right.left > w / 2);
    try std.testing.expectEqual(@as(i32, w) - right.left - right.width, left.left);
    try std.testing.expectEqual(right.top, left.top);

    // At 90° a wall along the east of its place is at the back, as one along the north is at 0°.
    var northWall = testBox(.{ 1, 1, 0.25 });
    northWall.transform[2][3] = 0;
    const atBack, const atBackPixels = try shapeSprite(&sections, allocator, &.{ .boxes = &.{northWall}, .textures = &textures }, 0, null, .deg0, &target);
    const fromEast, const fromEastPixels = try shapeSprite(&sections, allocator, &shape, 0, null, .deg90, &target);
    try std.testing.expectEqual(atBack.left, fromEast.left);
    try std.testing.expectEqual(atBack.top, fromEast.top);
    try std.testing.expectEqual(atBack.width, fromEast.width);
    try std.testing.expectEqual(atBack.height, fromEast.height);
    const count = @as(usize, atBack.width) * atBack.height;
    try std.testing.expectEqualSlices(u32, atBackPixels.plain[0..count], fromEastPixels.plain[0..count]);
    try std.testing.expectEqualSlices(i16, atBackPixels.depths[0..count], fromEastPixels.depths[0..count]);
}

test lightOf {
    // A face lit as it faces: up, +z and +x as a cube's, and halfway between up and +z, halfway
    // between their lights. Seen from behind, it's lit as from the front.
    const up = [4][3]f32{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 } };
    const south = [4][3]f32{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } };
    try std.testing.expectEqual(light.get(.top), lightOf(up));
    try std.testing.expectEqual(light.get(.left), lightOf(south));
    try std.testing.expectEqual(light.get(.left), lightOf(.{ south[0], south[3], south[2], south[1] }));
    try std.testing.expectEqual(light.get(.right), lightOf(.{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } }));
    const slope = [4][3]f32{ .{ 0, 0, 1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 1 } };
    try std.testing.expectEqual((light.get(.top) + light.get(.left)) / 2, lightOf(slope));
}

test drawSprites {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const red: [1][4]u8 = .{.{ 200, 0, 0, 255 }};
    const image: world.Image = .{ .width = 1, .height = 1, .pixels = &red };
    const blue: [1][4]u8 = .{.{ 0, 0, 200, 255 }};
    const other: world.Image = .{ .width = 1, .height = 1, .pixels = &blue };
    const plain: world.CubeFaces.Face = .{ .plain = &.{ &image, &other } };
    const cube: world.CubeFaces = .{ .up = plain, .south = plain, .east = plain, .north = plain, .west = plain };
    const textures = [_]world.CubeFaces.Face{.{ .tinted = &.{&image} }};
    const boxes = [_]world.Shape.Box{testBox(.{ 1, 0.5, 1 })};
    const slab: world.Shape = .{ .boxes = &boxes, .textures = &textures };
    const slabs = [_]world.Shape{slab};
    const sameSlabs = [_]world.Shape{.{ .boxes = &boxes, .textures = &textures }};
    const wholeBoxes = [_]world.Shape.Box{testBox(.{ 1, 1, 1 })};
    const wholeTextures = [_]world.CubeFaces.Face{plain};
    const picked = [_]world.Shape{ slab, .{ .boxes = &wholeBoxes, .textures = &wholeTextures }, .{ .boxes = &.{}, .textures = &.{} } };
    // A cube with two variants, a block with neither, two slabs sharing their sprites, the slab
    // turned, in sprites of its own, and a block picking the slab, a whole block in a texture
    // with two variants, or nothing.
    const drawables = [_]Drawable{ .{ .cube = &cube }, .{}, .{ .shapes = &slabs }, .{ .shapes = &sameSlabs }, .{ .shapes = &slabs, .turned = true }, .{ .shapes = &picked } };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "sprites", .{ .read = true });
    defer file.close(io);
    var buffer: [Sprites.Sections.bufferLength]u8 align(4) = undefined;
    var sections: Sprites.Sections = .init(io, file, 0, &buffer);
    const plan = try planSprites(allocator, &drawables);
    try std.testing.expectEqual(3 + turns + 6, plan.count);
    try drawSprites(allocator, &drawables, plan, &sections);
    try sections.flush();
    const blocks = plan.blocks;

    const sprites = try Sprites.parse(try sections.entryBytes(allocator, blockWidth), try sections.readLayers(allocator));
    try std.testing.expectEqual(plan.count, sprites.count);
    try std.testing.expectEqual(plan.count * Sprites.rotationCount, sprites.entries.len);
    try std.testing.expectEqual(blockWidth, sprites.blockWidth);
    // A cube of one colour is the same from every side, in the same layers.
    for (1..Sprites.rotationCount) |quarter| {
        try std.testing.expectEqual(sprites.entries[0].offset, sprites.entries[quarter * plan.count].offset);
    }
    try std.testing.expectEqual(world.BlockSprites{ .first = 3, .variants = 1, .turns = turns, .shape = true, .tinted = true }, blocks[4]);
    // Each of its shapes in as many variants as the most any has, the slab's one counting
    // round again.
    const choice = blocks[5];
    try std.testing.expectEqual(world.BlockSprites{ .first = 3 + turns, .variants = 2, .alternates = 3, .shape = true, .tinted = true }, choice);
    try std.testing.expect(!sprites.entries[choice.index(1, 0, 0)].flags.fills);
    try std.testing.expectEqual(sprites.layersOf(choice.index(0, 0, 0)).plain[0], sprites.layersOf(choice.index(1, 0, 0)).plain[0]);
    const whole = sprites.entries[choice.index(1, 1, 0)];
    try std.testing.expect(whole.flags.fills);
    try std.testing.expectEqual(faceColours(.{ 0, 0, 200 })[0], sprites.layersOf(choice.index(1, 1, 0)).plain[pixelAt(&whole, blockWidth / 4, blockWidth / 2).?]);
    const nothing = sprites.entries[choice.index(1, 2, 0)];
    try std.testing.expectEqual(0, nothing.width);
    try std.testing.expect(!nothing.flags.fills);
    try std.testing.expectEqual(world.BlockSprites{ .first = 0, .variants = 2 }, blocks[0]);
    try std.testing.expectEqual(0, blocks[1].variants);
    try std.testing.expectEqual(world.BlockSprites{ .first = 2, .variants = 1, .shape = true, .tinted = true }, blocks[2]);
    try std.testing.expectEqual(blocks[2], blocks[3]);
    // The cube's second variant is the blue one, each pixel as deep as a cube's.
    try std.testing.expect(sprites.entries[1].flags.fills);
    const second = sprites.layersOf(1);
    try std.testing.expectEqual(faceColours(.{ 0, 0, 200 })[0], second.plain[(blockWidth / 4) * blockWidth + blockWidth / 2]);
    try std.testing.expectEqual(cubeDepths[blockWidth / 4][blockWidth / 2], second.depths[(blockWidth / 4) * blockWidth + blockWidth / 2]);
    try std.testing.expect(!sprites.entries[2].flags.fills);
}

/// A world of a few blocks, each its own colour, for following lines of sight.
const TestSource = struct {
    const Place = struct { x: i64, y: i64, z: i64, id: i32 };

    places: []const Place,
    chunkColumns: []const world.ChunkColumn = &.{},

    pub fn heights(_: *const TestSource) world.Heights {
        return .{ .world = 64, .sea = 0 };
    }

    pub fn blockCount(_: *const TestSource) usize {
        return 3;
    }

    pub fn mapType(_: *const TestSource, _: i32) world.MapType {
        return .land;
    }

    pub fn isVisible(_: *const TestSource, id: i32) bool {
        return id != 0;
    }

    pub fn isLow(_: *const TestSource, _: i32) bool {
        return false;
    }

    pub fn colour(_: *const TestSource, id: i32) world.Rgb {
        return .{ @intCast(id * 100), 0, 0 };
    }

    pub fn spritesOf(_: *const TestSource, _: i32) ?world.BlockSprites {
        return null;
    }

    pub fn isTinted(_: *const TestSource, _: i32) bool {
        return false;
    }

    pub fn isLiquid(_: *const TestSource, _: i32) bool {
        return false;
    }

    pub fn isSeeThrough(_: *const TestSource, _: i32) bool {
        return false;
    }

    pub fn variant(_: *const TestSource, _: i32, _: i64, _: i64, _: i64, _: u32) u32 {
        return 0;
    }

    pub fn drawOffset(_: *const TestSource, _: i32, _: i64, _: i64, _: i64) ?[2]f32 {
        return null;
    }

    pub fn isPlacedByPosition(_: *const TestSource, _: i32) bool {
        return false;
    }

    pub const Reader = struct {
        source: *const TestSource,
        chunksRead: usize = 0,

        pub fn init(source: *const TestSource, _: std.mem.Allocator, _: ?*anyopaque) !Reader {
            return .{ .source = source };
        }

        pub fn deinit(_: *Reader, _: std.mem.Allocator) void {}

        pub fn readChunk(self: *Reader, x: i32, y: i32, z: i32, chunk: *world.Chunk) !bool {
            @memset(&chunk.solid, 0);
            @memset(&chunk.liquid, -1);
            var any = false;
            for (self.source.places) |place| {
                if (@divFloor(place.x, side) != x or @divFloor(place.y, side) != y or @divFloor(place.z, side) != z) continue;
                const at: usize = @intCast((@mod(place.y, side) * side + @mod(place.z, side)) * side + @mod(place.x, side));
                chunk.solid[at] = place.id;
                any = true;
            }
            return any;
        }

        pub fn tint(_: *Reader, _: i32, _: i64, _: i64, _: i64) !world.Rgb {
            return @splat(255);
        }
    };
};

test "lines of sight in every rotation" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.create(tiles.Pixels);
    defer allocator.destroy(pixels);

    for (std.enums.values(Rotation)) |rotation| {
        // A block just inside a corner of a chunk, and one nearer on its line of sight, across
        // the chunk's edge whichever way the view looks.
        const far = [3]i64{ 31, 20, -33 };
        const step = rotation.lineStep();
        const near = [3]i64{ far[0] - step[0], far[1] + 1, far[2] - step[1] };
        const places = [_]TestSource.Place{ .{ .x = far[0], .y = far[1], .z = far[2], .id = 1 }, .{ .x = near[0], .y = near[1], .z = near[2], .id = 2 } };
        const onlyFar = [_]TestSource.Place{places[0]};

        for ([_][]const TestSource.Place{ &onlyFar, &places }, [_]u8{ 100, 200 }) |list, red| {
            const source: TestSource = .{ .places = list };
            var view: View(TestSource) = try .init(allocator, &source, .{ .game = null }, null, rotation);
            defer view.deinit(allocator);
            var worker: View(TestSource).Worker = try .init(&view, allocator);
            defer worker.deinit(allocator);

            // The middle of the top of the far block's square, and of its two sides.
            const x, const z = rotation.toView(far[0], far[2]);
            const square = Box.of(x, far[1], z, x, far[1], z);
            const row = square.top + blockWidth / 4;
            const column = square.left + blockWidth / 2;
            const tile: tiles.Tile = .{ .x = @intCast(@divFloor(column, tiles.size)), .y = @intCast(@divFloor(row, tiles.size)) };
            try std.testing.expect(try worker.draw(tile, pixels));
            const at: usize = @intCast(@mod(row, tiles.size) * tiles.size + @mod(column, tiles.size));
            try std.testing.expectEqual(faceColours(.{ red, 0, 0 })[0], pixels[at]);
        }
    }
}

/// What every worker shares, read-only while they draw, and their totals once they're done.
fn View(comptime Source: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        source: *const Source,
        /// How each block ID is drawn: 0 not at all, otherwise its look's index in `looks` + 1.
        blockLooks: []u16,
        looks: []Look,
        /// In the `relief` style, each map type's three face colours at each height:
        /// `(mapType * height + y) * 3`, top, left, right.
        colours: []u32,
        /// In the `game` style, the blocks' sprites; with none, every block is drawn in its
        /// colour.
        sprites: ?*const Sprites,
        rotation: Rotation,
        /// How far beyond its square a block's sprite can reach: `reach` with shapes, and
        /// `shift` more with blocks moved off the middle of their place.
        reach: i64,
        height: u16,
        chunksRead: usize = 0,

        /// How a block is drawn.
        const Look = union(enum) {
            /// In its map type's relief colours, which change with height (`colours`).
            relief: world.MapType,
            /// Each face in one colour: top, left and right.
            colours: [3]u32,
            /// Each face in a colour times the tint of a block where it is.
            tintedColour: struct { colour: world.Rgb, block: i32 },
            /// In its sprites, the block that picks its variant, shape, turn and offset by where
            /// it is, whether its tint colours their tinted layer, and whether it's see-through.
            sprite: SpriteLook,

            const SpriteLook = struct { sprites: world.BlockSprites, block: i32, tinted: bool = false, seeThrough: bool = false };
        };

        fn init(allocator: std.mem.Allocator, source: *const Source, style: Style, sprites: ?*const Sprites, rotation: Rotation) !Self {
            const heights = source.heights();
            const blockLooks = try allocator.alloc(u16, source.blockCount());
            errdefer allocator.free(blockLooks);
            var looks: std.ArrayList(Look) = .empty;
            errdefer looks.deinit(allocator);
            var anyShape = false;
            var anyPlaced = false;
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
                    // Untinted blocks that look the same share a look. A tinted block has a look
                    // of its own, naming it, as its tint is its own, and so does one placed by
                    // where it is.
                    var bySprites: std.AutoHashMapUnmanaged(u32, u16) = .empty;
                    defer bySprites.deinit(allocator);
                    var byColour: std.AutoHashMapUnmanaged(world.Rgb, u16) = .empty;
                    defer byColour.deinit(allocator);
                    for (blockLooks, 0..) |*look, i| {
                        const id: i32 = @intCast(i);
                        const own: world.BlockSprites = if (sprites != null) source.spritesOf(id) orelse .{} else .{};
                        // A block in a shape is drawn in it, plants and low blocks too.
                        const shaped = own.variants > 0 and own.shape and source.isVisible(id);
                        if (!shaped and !isDrawn(source, id)) {
                            look.* = 0;
                            continue;
                        }
                        anyShape = anyShape or shaped;
                        const colour = source.colour(id);
                        const isTinted = source.isTinted(id);
                        if (own.variants > 0) {
                            const spriteLook: Look.SpriteLook = .{ .sprites = own, .block = id };
                            const tinted = isTinted and own.tinted;
                            const placed = source.isPlacedByPosition(id);
                            anyPlaced = anyPlaced or placed;
                            const seeThrough = source.isSeeThrough(id);
                            if (tinted or placed or own.cover != null or seeThrough) {
                                var ownLook = spriteLook;
                                ownLook.tinted = tinted;
                                ownLook.seeThrough = seeThrough;
                                look.* = try addLook(allocator, &looks, .{ .sprite = ownLook });
                                continue;
                            }
                            const found = try bySprites.getOrPut(allocator, own.first);
                            if (!found.found_existing) found.value_ptr.* = try addLook(allocator, &looks, .{ .sprite = spriteLook });
                            look.* = found.value_ptr.*;
                        } else if (isTinted) {
                            look.* = try addLook(allocator, &looks, .{ .tintedColour = .{ .colour = colour, .block = id } });
                        } else {
                            const found = try byColour.getOrPut(allocator, colour);
                            if (!found.found_existing) found.value_ptr.* = try addLook(allocator, &looks, .{ .colours = faceColours(colour) });
                            look.* = found.value_ptr.*;
                        }
                    }
                },
            }
            return .{
                .name = rotation.folder(),
                .source = source,
                .blockLooks = blockLooks,
                .looks = try looks.toOwnedSlice(allocator),
                .colours = colours,
                .sprites = sprites,
                .rotation = rotation,
                .reach = @as(i64, if (anyShape) reach else 0) + @as(i64, if (anyPlaced) shift else 0),
                .height = heights.world,
            };
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.colours);
            allocator.free(self.looks);
            allocator.free(self.blockLooks);
        }

        /// Whether blocks of `look` fill their place, top and sides, so nothing behind them on
        /// a line shows. A look without sprites is a cube.
        fn isFilled(self: *const Self, look: u16) bool {
            return switch (self.looks[look - 1]) {
                .sprite => |own| self.sprites.?.entries[own.sprites.first].flags.fills,
                else => true,
            };
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
            slot: *ChunkCache.Slot,
            cache: ChunkCache,
            /// The depth of what each pixel shows: x + y + z of its point, in `depthSteps`ths of
            /// a block, larger nearer.
            depth: *[tiles.size * tiles.size]i64,
            /// The tile's see-through blocks with something to show, painted once its other blocks
            /// are drawn (`paintSeeThrough`), the first `seeThroughCount` of them.
            seeThrough: *[maxSeeThroughBlocks]SeeThroughBlock,
            seeThroughCount: usize = 0,
            /// The chunk last asked for, as neighbouring blocks are mostly in the same one.
            recent: ?struct { position: ChunkCache.Position, slot: ?*const ChunkCache.Slot } = null,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                var reader: Source.Reader = try .init(view.source, allocator, null);
                errdefer reader.deinit(allocator);
                const chunk = try allocator.create(world.Chunk);
                errdefer allocator.destroy(chunk);
                const slot = try allocator.create(ChunkCache.Slot);
                errdefer allocator.destroy(slot);
                var cache: ChunkCache = try .init(allocator, ChunkCache.defaultChunks, ChunkCache.defaultChunksWithBlocks);
                errdefer cache.deinit(allocator);
                const depth = try allocator.create([tiles.size * tiles.size]i64);
                errdefer allocator.destroy(depth);
                const seeThrough = try allocator.create([maxSeeThroughBlocks]SeeThroughBlock);
                return .{ .view = view, .reader = reader, .chunk = chunk, .slot = slot, .cache = cache, .depth = depth, .seeThrough = seeThrough };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                allocator.destroy(self.seeThrough);
                allocator.destroy(self.depth);
                self.cache.deinit(allocator);
                allocator.destroy(self.slot);
                allocator.destroy(self.chunk);
                self.reader.deinit(allocator);
            }

            /// Draws the nearest block on each line of sight through the tile. Returns false if
            /// none has one.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                @memset(pixels, tiles.transparent);
                @memset(self.depth, std.math.minInt(i64));
                self.seeThroughCount = 0;
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
                        // A block whose sprite leaves parts of its square empty, such as a
                        // plant, shows what's behind it on the line there, and so does a
                        // see-through one, painted once the line has been followed. A liquid in
                        // its place covers what of it is inside the liquid.
                        while (try self.nextBlock(line, &y)) |block| {
                            const drawn = try self.drawLook(line, block, x0, y0, pixels);
                            if (drawn.any) any = true;
                            if (drawn.fills) break;
                            if (block.liquid == 0) continue;
                            var liquid = block;
                            liquid.look = block.liquid;
                            const around = try self.drawLook(line, liquid, x0, y0, pixels);
                            if (around.any) any = true;
                            if (around.fills) break;
                        }
                    }
                }
                if (self.paintSeeThrough(pixels)) any = true;
                return any;
            }

            /// Paints the listed blocks from far to near, so each mixes over all that's behind it.
            /// x + y + z goes up by 1 from each block a line of sight crosses to the next, so it
            /// orders them on every pixel. Returns whether any pixel was painted.
            fn paintSeeThrough(self: *Worker, pixels: *tiles.Pixels) bool {
                const blocks = self.seeThrough[0..self.seeThroughCount];
                std.mem.sortUnstable(SeeThroughBlock, blocks, {}, SeeThroughBlock.isFarther);
                var any = false;
                for (blocks) |*block| {
                    const sprites = self.view.sprites.?;
                    if (paintBlock(block, sprites.entries[block.sprite], sprites.layersOf(block.sprite), pixels, self.depth)) any = true;
                }
                return any;
            }

            /// Lists see-through `block`, on `line`, to paint, unless it's a cube all of whose
            /// faces touch its own material, so a stack of it is one thick surface.
            fn listSeeThrough(self: *Worker, line: Line, look: Look.SpriteLook, block: Block, x0: i64, y0: i64) !void {
                const inShape = look.sprites.shape;
                const exposed: std.EnumSet(Face) = if (inShape) .{} else try self.exposedFaces(line, block, look.sprites.first);
                if ((!inShape and exposed.count() == 0) or self.seeThroughCount == self.seeThrough.len) return;
                const picked = try self.pickSprite(look, block);
                const square = line.square();
                self.seeThrough[self.seeThroughCount] = .{
                    .sprite = picked.index,
                    .left = @intCast(square.left - x0),
                    .top = @intCast(square.top - y0),
                    .depth = @intCast(line.depth(block.y)),
                    .tint = picked.tint,
                    .inShape = inShape,
                    .exposed = exposed,
                };
                self.seeThroughCount += 1;
            }

            /// The faces of `block`, on `line`, the view sees that don't touch `material`.
            fn exposedFaces(self: *Worker, line: Line, block: Block, material: u32) !std.EnumSet(Face) {
                const rotation = self.view.rotation;
                const x, const z = line.at(block.y);
                const leftX, const leftZ = rotation.toWorld(x, z + 1);
                const rightX, const rightZ = rotation.toWorld(x + 1, z);
                var exposed: std.EnumSet(Face) = .{};
                exposed.setPresent(.top, try self.materialAt(block.x, block.y + 1, block.z) != material);
                exposed.setPresent(.left, try self.materialAt(leftX, block.y, leftZ) != material);
                exposed.setPresent(.right, try self.materialAt(rightX, block.y, rightZ) != material);
                return exposed;
            }

            /// The see-through material at a place, in a liquid around a block too, by its first
            /// sprite; null for none.
            fn materialAt(self: *Worker, x: i64, y: i64, z: i64) !?u32 {
                if (y < 0 or y >= self.view.height) return null;
                const cx = @divFloor(x, side);
                const cy = @divFloor(y, side);
                const cz = @divFloor(z, side);
                const slot = try self.chunkLooks(cx, cy, cz) orelse return null;
                const lx: usize = @intCast(x - cx * side);
                const ly: usize = @intCast(y - cy * side);
                const lz: usize = @intCast(z - cz * side);
                const place = (ly * side + lz) * side + lx;
                const liquid = slot.liquidAt(place);
                const look = if (liquid != 0) liquid else slot.looks[place];
                if (look == 0) return null;
                return switch (self.view.looks[look - 1]) {
                    .sprite => |own| if (own.seeThrough) own.sprites.first else null,
                    else => null,
                };
            }

            /// The sprite `block` shows in `look`, picked by where it is, and its tint.
            fn pickSprite(self: *Worker, look: Look.SpriteLook, block: Block) !struct { index: u32, tint: world.Rgb } {
                const own = look.sprites;
                const source = self.view.source;
                const variant = if (own.variants > 1) source.variant(look.block, block.x, block.y, block.z, own.variants) else 0;
                // Shapes and turns are picked as variants are.
                const alternate = if (own.alternates > 1) source.variant(look.block, block.x, block.y, block.z, own.alternates) else 0;
                const turn = if (own.turns > 1) source.variant(look.block, block.x, block.y, block.z, own.turns) else 0;
                const index = own.index(variant, alternate, turn);
                const tinted = self.view.sprites.?.entries[index].flags.tinted and look.tinted;
                return .{ .index = index, .tint = if (tinted) try self.reader.tint(look.block, block.x, block.y, block.z) else @splat(255) };
            }

            /// Draws `block`, on `line`, in its look, or lists it if it's see-through. Returns
            /// whether it drew any pixel, and whether it fills its square, hiding what's behind
            /// it on the line.
            fn drawLook(self: *Worker, line: Line, block: Block, x0: i64, y0: i64, pixels: *tiles.Pixels) !struct { any: bool, fills: bool } {
                var tintedColours: [3]u32 = undefined;
                var fills = true;
                // The block that picks a sprite's variant and offset.
                var placedBy: ?i32 = null;
                var cover: ?u32 = null;
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
                    .sprite => |look| sprite: {
                        if (look.seeThrough) {
                            try self.listSeeThrough(line, look, block, x0, y0);
                            return .{ .any = false, .fills = false };
                        }
                        placedBy = look.block;
                        cover = look.sprites.cover;
                        const picked = try self.pickSprite(look, block);
                        const sprites = self.view.sprites.?;
                        const sprite = sprites.entries[picked.index];
                        fills = sprite.flags.fills;
                        break :sprite .{ .sprite = .{ .sprite = sprite, .layers = sprites.layersOf(picked.index), .tint = picked.tint } };
                    },
                };
                const square = line.square();
                var left = square.left - x0;
                var top = square.top - y0;
                var depth = line.depth(block.y) * depthSteps;
                var any = false;
                if (cover) |index| if (try self.isFilledBelow(block)) {
                    const sprites = self.view.sprites.?;
                    const paintCover: Paint = .{ .sprite = .{ .sprite = sprites.entries[index], .layers = sprites.layersOf(index), .tint = @splat(255) } };
                    any = self.drawBlock(left, top, depth, paintCover, pixels);
                };
                // Moved off the middle of its place, its sprite moves across and down, and nearer,
                // and no longer covers its square.
                if (placedBy) |id| if (self.view.source.drawOffset(id, block.x, block.y, block.z)) |by| {
                    fills = false;
                    const x, const z = self.view.rotation.distanceToView(by[0], by[1]);
                    left += @intFromFloat(@round((x - z) * across));
                    top += @intFromFloat(@round((x + z) * down));
                    depth += @intFromFloat(@round((x + z) * depthSteps));
                };
                if (self.drawBlock(left, top, depth, paint, pixels)) any = true;
                return .{ .any = any, .fills = fills };
            }

            /// Whether a solid block under `block` fills its place, top and sides. What it's drawn
            /// in tells: a look without sprites is a cube.
            fn isFilledBelow(self: *Worker, block: Block) !bool {
                const y = block.y - 1;
                if (y < 0) return false;
                const cx = @divFloor(block.x, side);
                const cy = @divFloor(y, side);
                const cz = @divFloor(block.z, side);
                const slot = try self.chunkLooks(cx, cy, cz) orelse return false;
                const lx: usize = @intCast(block.x - cx * side);
                const ly: usize = @intCast(y - cy * side);
                const lz: usize = @intCast(block.z - cz * side);
                const look = slot.looks[(ly * side + lz) * side + lx];
                if (look == 0 or !self.view.isFilled(look)) return false;
                return switch (self.view.looks[look - 1]) {
                    .sprite => |spriteLook| !self.view.source.isLiquid(spriteLook.block),
                    else => true,
                };
            }

            /// Where it is in the world. `liquid` is the look of a liquid in its place; 0 for none.
            const Block = struct { x: i64, y: i64, z: i64, look: u16, liquid: u16 };

            /// What a block's pixels come from: a colour for each face, top, left and right, or
            /// a sprite.
            const Paint = union(enum) {
                faces: *const [3]u32,
                /// A sprite, its tinted layer, if it has one, tinted by `tint`.
                sprite: struct { sprite: Sprite, layers: SpriteLayers, tint: world.Rgb },
            };

            /// The next drawn block on a line of sight, following it down from height `y.*`, or
            /// null if none is; `y.*` is then just below it. A chunk without one is passed in one
            /// step.
            fn nextBlock(self: *Worker, line: Line, y: *i64) !?Block {
                const rotation = self.view.rotation;
                const stepX, const stepZ = rotation.lineStep();
                while (y.* >= 0) {
                    const viewX, const viewZ = line.at(y.*);
                    const x, const z = rotation.toWorld(viewX, viewZ);
                    const cx = @divFloor(x, side);
                    const cy = @divFloor(y.*, side);
                    const cz = @divFloor(z, side);
                    var lx: usize = @intCast(x - cx * side);
                    var ly: usize = @intCast(y.* - cy * side);
                    var lz: usize = @intCast(z - cz * side);
                    // The line's blocks in this chunk, from here until it leaves it.
                    const stepsX = if (stepX < 0) lx else side - 1 - lx;
                    const stepsZ = if (stepZ < 0) lz else side - 1 - lz;
                    const steps = @min(stepsX, ly, stepsZ) + 1;
                    if (try self.chunkLooks(cx, cy, cz)) |slot| {
                        for (0..steps) |step| {
                            const place = (ly * side + lz) * side + lx;
                            const look = slot.looks[place];
                            if (look != 0) {
                                const along: i64 = @intCast(step);
                                const found: Block = .{ .x = x + stepX * along, .y = y.* - along, .z = z + stepZ * along, .look = look, .liquid = slot.liquidAt(place) };
                                y.* = found.y - 1;
                                return found;
                            }
                            lx +%= @bitCast(stepX);
                            ly -%= 1;
                            lz +%= @bitCast(stepZ);
                        }
                    }
                    y.* -= @intCast(steps);
                }
                return null;
            }

            /// How each block of chunk (x, y, z) is drawn, from the cache or else read; null for a
            /// chunk with nothing to draw.
            fn chunkLooks(self: *Worker, x: i64, y: i64, z: i64) !?*const ChunkCache.Slot {
                const limit = std.math.maxInt(i32);
                if (@abs(x) > limit or @abs(y) > limit or @abs(z) > limit) return null;
                const position: ChunkCache.Position = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) };
                if (self.recent) |recent| {
                    if (std.meta.eql(recent.position, position)) return recent.slot;
                }
                const slot = try self.lookUpChunk(position);
                self.recent = .{ .position = position, .slot = slot };
                return slot;
            }

            fn lookUpChunk(self: *Worker, position: ChunkCache.Position) !?*const ChunkCache.Slot {
                switch (self.cache.get(position)) {
                    .empty => return null,
                    .slot => |slot| return slot,
                    .uncached => {},
                }
                if (!try self.reader.readChunk(position.x, position.y, position.z, self.chunk)) {
                    _ = self.cache.put(position, false);
                    return null;
                }
                const byId = self.view.blockLooks;
                var drawn: u16 = 0;
                self.slot.liquidCount = 0;
                for (&self.slot.looks, self.chunk.solid, self.chunk.liquid, 0..) |*look, solid, liquid, place| {
                    const solidLook = if (solid >= 0 and solid < byId.len) byId[@intCast(solid)] else 0;
                    const liquidLook = if (liquid >= 0 and liquid < byId.len) byId[@intCast(liquid)] else 0;
                    look.* = if (solidLook != 0) solidLook else liquidLook;
                    drawn |= look.*;
                    if (solidLook != 0 and liquidLook != 0 and !self.view.isFilled(solidLook)) self.slot.addLiquid(place, liquidLook);
                }
                // A chunk of only air, plants or invisible blocks, such as those in the sky, is kept
                // as having nothing to draw: lines pass it in one step, and it takes no slot.
                if (drawn == 0) {
                    _ = self.cache.put(position, false);
                    return null;
                }
                const slot = self.cache.put(position, true).?;
                slot.* = self.slot.*;
                return slot;
            }

            /// Draws a block whose square's top left is at (`left`, `top`) in the tile, at
            /// `depth`, x + y + z of the block in `depthSteps`ths, on each pixel where what it
            /// shows is nearer than what's there. Returns whether it drew any.
            fn drawBlock(self: *Worker, left: i64, top: i64, depth: i64, paint: Paint, pixels: *tiles.Pixels) bool {
                var any = false;
                switch (paint) {
                    .sprite => |from| {
                        const sprite = &from.sprite;
                        const layers = &from.layers;
                        for (0..sprite.height) |row| {
                            const py = top + sprite.top + @as(i64, @intCast(row));
                            if (py < 0 or py >= tiles.size) continue;
                            for (0..sprite.width) |column| {
                                const px = left + sprite.left + @as(i64, @intCast(column));
                                if (px < 0 or px >= tiles.size) continue;
                                const at = row * sprite.width + column;
                                // Where it shows nothing, what's behind it does.
                                if (!layers.shows(at)) continue;
                                const p: usize = @intCast(py * tiles.size + px);
                                const pointDepth = depth + layers.depths[at];
                                if (pointDepth <= self.depth[p]) continue;
                                self.depth[p] = pointDepth;
                                pixels[p] = if (layers.tinted) |tinted| blend(layers.plain[at], tinted[at], from.tint) else layers.plain[at];
                                any = true;
                            }
                        }
                    },
                    .faces => |colours| for (0..blockWidth) |row| {
                        const py = top + @as(i64, @intCast(row));
                        if (py < 0 or py >= tiles.size) continue;
                        for (0..blockWidth) |column| {
                            const px = left + @as(i64, @intCast(column));
                            if (px < 0 or px >= tiles.size) continue;
                            const face = faces[row][column];
                            if (face == .none) continue;
                            const p: usize = @intCast(py * tiles.size + px);
                            const pointDepth = depth + cubeDepths[row][column];
                            if (pointDepth <= self.depth[p]) continue;
                            self.depth[p] = pointDepth;
                            pixels[p] = colours[@backingInt(face) - 1];
                            any = true;
                        }
                    },
                }
                return any;
            }
        };
    };
}

/// A see-through block to paint over the tile: its sprite, where its square's top left is in the
/// tile, x + y + z of the block, the tint of its tinted layer, whether it's in a shape, whose
/// pixels say how opaque they are, and for a cube, the faces that show.
const SeeThroughBlock = struct {
    sprite: u32,
    left: i16,
    top: i16,
    depth: i32,
    tint: world.Rgb,
    inShape: bool = false,
    exposed: std.EnumSet(Face),

    fn isFarther(_: void, a: SeeThroughBlock, b: SeeThroughBlock) bool {
        return a.depth < b.depth;
    }
};

/// The test saves' fullest tile has 4,034. Past it, a tile shows without the rest.
const maxSeeThroughBlocks = 16384;

/// Mixes `block`'s `sprite` over `pixels`: a cube's exposed faces, each pixel by how far behind it
/// what it covers is, or a shape's pixels by how opaque they are. Where nothing is behind, it's
/// taken as it is, and a pixel behind what's there is left out. `depths` then holds its depth, for
/// what's painted over it next. Returns whether any pixel was painted.
fn paintBlock(block: *const SeeThroughBlock, sprite: Sprite, layers: SpriteLayers, pixels: *tiles.Pixels, depths: *[tiles.size * tiles.size]i64) bool {
    var any = false;
    for (0..sprite.height) |row| {
        const py = @as(i64, block.top) + sprite.top + @as(i64, @intCast(row));
        if (py < 0 or py >= tiles.size) continue;
        for (0..sprite.width) |column| {
            const px = @as(i64, block.left) + sprite.left + @as(i64, @intCast(column));
            if (px < 0 or px >= tiles.size) continue;
            const at = row * sprite.width + column;
            if (block.inShape) {
                if (!layers.shows(at)) continue;
            } else if (!block.exposed.contains(faces[row][column])) continue;
            const p: usize = @intCast(py * tiles.size + px);
            const pointDepth = @as(i64, block.depth) * depthSteps + layers.depths[at];
            if (pointDepth <= depths[p]) continue;
            const colour = if (layers.tinted) |tinted| blend(layers.plain[at], tinted[at], block.tint) else layers.plain[at];
            if (depths[p] == std.math.minInt(i64)) {
                pixels[p] = colour;
            } else {
                const opacity: u8 = if (block.inShape) @truncate(layers.plain[at] >> 24) else surfaceOpacity(pointDepth - depths[p]);
                pixels[p] = mix(pixels[p], colour, opacity);
            }
            depths[p] = pointDepth;
            any = true;
        }
    }
    return any;
}

test paintBlock {
    const gpa = std.testing.allocator;
    const pixels = try gpa.create(tiles.Pixels);
    defer gpa.destroy(pixels);
    const depths = try gpa.create([tiles.size * tiles.size]i64);
    defer gpa.destroy(depths);
    @memset(pixels, tiles.transparent);
    @memset(depths, std.math.minInt(i64));

    const opaqueDepths: *const [blockWidth * blockWidth]i16 = @ptrCast(&cubeDepths);
    const water: [blockWidth * blockWidth]u32 = @splat(tiles.rgba(0, 0, 200, 255));
    const ice: [blockWidth * blockWidth]u32 = @splat(tiles.rgba(200, 200, 200, 255));
    const waterLayers: SpriteLayers = .{ .plain = &water, .tinted = null, .depths = opaqueDepths };
    const iceLayers: SpriteLayers = .{ .plain = &ice, .tinted = null, .depths = opaqueDepths };
    const all: std.EnumSet(Face) = .initMany(&.{ .top, .left, .right });
    const square: Sprite = .{ .left = 0, .top = 0, .width = blockWidth, .height = blockWidth, .flags = .{} };
    const w = blockWidth;
    const top = (w / 4) * tiles.size + w / 2;
    const south = (w * 5 / 8) * tiles.size + w / 4;
    const topDepth = opaqueDepths[(w / 4) * w + w / 2];

    // Nothing behind it: as it is, and it says where it is.
    var cube: SeeThroughBlock = .{ .sprite = 0, .left = 0, .top = 0, .depth = 10, .tint = @splat(255), .exposed = .initMany(&.{.left}) };
    try std.testing.expect(paintBlock(&cube, square, waterLayers, pixels, depths));
    try std.testing.expectEqual(tiles.rgba(0, 0, 200, 255), pixels[south]);
    // Only the faces it shows.
    try std.testing.expectEqual(tiles.transparent, pixels[top]);

    // Three layers over a solid pixel: each mixes over the last, by the depth from it.
    const sand = tiles.rgba(200, 100, 0, 255);
    const sandDepth: i64 = 8 * depthSteps;
    pixels[top] = sand;
    depths[top] = sandDepth;
    cube.exposed = all;
    try std.testing.expect(paintBlock(&cube, square, waterLayers, pixels, depths));
    const waterDepth = 10 * depthSteps + @as(i64, topDepth);
    const overSand = mix(sand, water[0], surfaceOpacity(waterDepth - sandDepth));
    try std.testing.expectEqual(overSand, pixels[top]);
    try std.testing.expectEqual(waterDepth, depths[top]);
    cube.depth = 11;
    try std.testing.expect(paintBlock(&cube, square, iceLayers, pixels, depths));
    const iceDepth = 11 * depthSteps + @as(i64, topDepth);
    const overWater = mix(overSand, ice[0], surfaceOpacity(iceDepth - waterDepth));
    try std.testing.expectEqual(overWater, pixels[top]);
    cube.depth = 12;
    try std.testing.expect(paintBlock(&cube, square, waterLayers, pixels, depths));
    try std.testing.expectEqual(mix(overWater, water[0], surfaceOpacity(depthSteps)), pixels[top]);

    // Behind what's there: a solid block in front of it stays as it is.
    const before = pixels[top];
    depths[top] = std.math.maxInt(i64);
    cube.depth = 13;
    _ = paintBlock(&cube, square, iceLayers, pixels, depths);
    try std.testing.expectEqual(before, pixels[top]);

    // A shape's pixels say how opaque they are, however far behind it what they cover is, and
    // where it leaves one out, nothing is painted.
    const pane: [4]u32 = .{ tiles.rgba(90, 90, 90, 51), tiles.rgba(0, 0, 0, 255), tiles.transparent, tiles.rgba(90, 90, 90, 51) };
    const paneDepths: [4]i16 = .{ 0, 0, 0, 0 };
    const paneLayers: SpriteLayers = .{ .plain = &pane, .tinted = null, .depths = &paneDepths };
    const paneSprite: Sprite = .{ .left = 3, .top = 2, .width = 2, .height = 2, .flags = .{} };
    const glassy: SeeThroughBlock = .{ .sprite = 0, .left = 10, .top = 20, .depth = 40, .tint = @splat(255), .inShape = true, .exposed = .{} };
    const glassAt = 22 * tiles.size + 13;
    for ([_]usize{ glassAt, glassAt + 1, glassAt + tiles.size }) |p| {
        pixels[p] = sand;
        depths[p] = sandDepth;
    }
    try std.testing.expect(paintBlock(&glassy, paneSprite, paneLayers, pixels, depths));
    try std.testing.expectEqual(mix(sand, pane[0], 51), pixels[glassAt]);
    try std.testing.expectEqual(tiles.rgba(0, 0, 0, 255), pixels[glassAt + 1]);
    try std.testing.expectEqual(sand, pixels[glassAt + tiles.size]);
}

test SeeThroughBlock {
    var cubes = [_]SeeThroughBlock{
        .{ .sprite = 0, .left = 0, .top = 0, .depth = 9, .tint = @splat(255), .exposed = .{} },
        .{ .sprite = 1, .left = 0, .top = 0, .depth = 3, .tint = @splat(255), .exposed = .{} },
        .{ .sprite = 2, .left = 0, .top = 0, .depth = 6, .tint = @splat(255), .exposed = .{} },
    };
    std.mem.sortUnstable(SeeThroughBlock, &cubes, {}, SeeThroughBlock.isFarther);
    try std.testing.expectEqual(1, cubes[0].sprite);
    try std.testing.expectEqual(0, cubes[2].sprite);
    // Sized at startup, 20 bytes each.
    try std.testing.expectEqual(20, @sizeOf(SeeThroughBlock));
}

/// How opaque a see-through surface is, of 255, with what shows through it `depth` behind it, in
/// `depthSteps`ths of `x + y + z`: three of those for each block along a line of sight. It's
/// `surfaceClearest` with something right behind it, and the rest of the way to opaque comes on
/// over `surfaceThickening` blocks: there's no light to darken what's deep.
fn surfaceOpacity(depth: i64) u8 {
    return surfaceOpacities[@intCast(@min(@divFloor(depth, depthSteps), surfaceOpacities.len - 1))];
}

const surfaceClearest = 0.4;
const surfaceThickening = 4.0;

/// By a third of a block along a line of sight.
const surfaceOpacities: [64]u8 = opacities: {
    @setEvalBranchQuota(10_000);
    var out: [64]u8 = undefined;
    for (&out, 0..) |*opacity, i| {
        const blocks = @as(f64, @floatFromInt(i)) / 3;
        opacity.* = @intFromFloat(@round(255 * (1 - (1 - surfaceClearest) * @exp(-blocks / surfaceThickening))));
    }
    break :opacities out;
};

test surfaceOpacity {
    try std.testing.expectEqual(102, surfaceOpacity(0));
    try std.testing.expect(surfaceOpacity(3 * depthSteps) > surfaceOpacity(0));
    // Deep enough that little shows.
    try std.testing.expect(surfaceOpacity(3 * 12 * depthSteps) > 240);
    try std.testing.expectEqual(surfaceOpacity(1000 * depthSteps), surfaceOpacity(2000 * depthSteps));
}

/// `over` mixed over `under`, opaque, by `opacity` of 255.
fn mix(under: u32, over: u32, opacity: u8) u32 {
    const a: u32 = opacity;
    var out: [3]u8 = undefined;
    for (&out, std.mem.asBytes(&under)[0..3], std.mem.asBytes(&over)[0..3]) |*channel, u, o| {
        channel.* = @intCast((@as(u32, u) * (255 - a) + @as(u32, o) * a) / 255);
    }
    return tiles.rgba(out[0], out[1], out[2], 255);
}

test mix {
    try std.testing.expectEqual(tiles.rgba(100, 0, 50, 255), mix(tiles.rgba(100, 0, 50, 255), tiles.rgba(0, 200, 0, 255), 0));
    try std.testing.expectEqual(tiles.rgba(0, 200, 0, 255), mix(tiles.rgba(100, 0, 50, 255), tiles.rgba(0, 200, 0, 255), 255));
    try std.testing.expectEqual(tiles.rgba(49, 100, 24, 255), mix(tiles.rgba(100, 0, 50, 255), tiles.rgba(0, 200, 0, 255), 128));
}

/// `pixel`'s colour times `factor` 256ths.
fn lit(pixel: u32, factor: u16) u32 {
    const channels = std.mem.asBytes(&pixel);
    var out: [3]u8 = undefined;
    for (&out, channels[0..3]) |*channel, value| channel.* = @intCast(@min(255, @as(u32, value) * factor / 256));
    return tiles.rgba(out[0], out[1], out[2], channels[3]);
}
