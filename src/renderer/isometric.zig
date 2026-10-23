//! The isometric view, looking north-west from above: every block drawn as a cube in its map
//! type's relief colour (`relief.zig`), its top, south and east faces lit differently. Plants
//! aren't drawn.
//!
//! Each tile follows its lines of sight (`Line`) from the top of the world, and draws the first
//! block each meets, as Mapcrafter does. A chunk is read only when a line enters it, and each
//! worker keeps the chunks it has read (`ChunkCache`), so chunks hidden underground are never
//! read.
//!
//! A `Source` is a game's save, opened for reading, with:
//! - `chunkColumns: []const world.ChunkColumn`, those that may have blocks;
//! - `heights() world.Heights`;
//! - `blockCount() usize`, `mapType(id: i32) world.MapType` and `isVisible(id: i32) bool`;
//! - `Reader`, one per thread: `init(source: *const Source, allocator, null) !Reader`,
//!   `deinit(*Reader, allocator)`, `readChunk(*Reader, x: i32, y: i32, z: i32, chunk:
//!   *world.Chunk) !bool`, false where there's no chunk to draw, and `chunksRead: usize`.
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const tiles = @import("tiles");
const relief = @import("relief.zig");

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
    /// Summed over all workers, as in `tiles.Stats`.
    draw: Io.Duration = .zero,
    encode: Io.Duration = .zero,
};

pub const Options = struct {
    /// The colours of the map types.
    palette: world.Palette,
    /// Where to record stats instead of printing a summary.
    stats: ?*Stats = null,
};

/// Renders `source` into `output` and returns the tiles written, at every level, owned by the
/// caller.
pub fn render(comptime Source: type, allocator: std.mem.Allocator, io: Io, source: *const Source, output: tiles.Output, options: Options) ![]tiles.Written {
    const start: Io.Timestamp = .now(io, .awake);
    var view: View(Source) = try .init(allocator, source, &options.palette);
    defer view.deinit(allocator);
    const list = try tileList(allocator, source.chunkColumns, source.heights().world);
    defer allocator.free(list);

    var written: std.ArrayList(tiles.Written) = .empty;
    errdefer written.deinit(allocator);
    const rendered = try tiles.render(View(Source), allocator, io, &view, list, output, &written);
    const result = try written.toOwnedSlice(allocator);

    if (options.stats) |out| {
        out.* = .{
            .tiles = rendered.tiles,
            .levels = rendered.levels,
            .chunksRead = view.chunksRead,
            .duration = start.untilNow(io, .awake),
            .draw = rendered.draw,
            .encode = rendered.encode,
        };
        return result;
    }
    std.debug.print("isometric: {} tiles in {} levels, {} chunks read\n", .{ rendered.tiles, rendered.levels, view.chunksRead });
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

/// The chunks a worker has read: how each of their blocks is drawn (`View.kinds`), or that a
/// chunk has nothing to draw, which takes no room. It holds a fixed number of each, set up once,
/// and makes room by forgetting the one used longest ago.
const ChunkCache = struct {
    pub const Position = struct { x: i32, y: i32, z: i32 };
    pub const Kinds = [world.Chunk.volume]u8;
    pub const Lookup = union(enum) { uncached, empty, kinds: *const Kinds };

    /// Chunks remembered, and how many of them can have blocks to draw: 32 KB each.
    pub const defaultChunks = 4096;
    pub const defaultChunksWithBlocks = 128;

    const Entry = struct {
        position: Position,
        /// Where its kinds are in `kinds`, or null for a chunk with nothing to draw.
        slot: ?u32,
        /// When it was last used, by `clock`.
        used: u64,
    };

    entries: []Entry,
    count: usize = 0,
    /// Each position's index in `entries`.
    byPosition: std.AutoHashMapUnmanaged(Position, u32),
    kinds: []Kinds,
    /// Slots in `kinds` no entry holds, the first `freeCount` of them.
    free: []u32,
    freeCount: usize,
    clock: u64 = 0,

    fn init(allocator: std.mem.Allocator, chunks: u32, chunksWithBlocks: u32) !ChunkCache {
        const entries = try allocator.alloc(Entry, chunks);
        errdefer allocator.free(entries);
        var byPosition: std.AutoHashMapUnmanaged(Position, u32) = .empty;
        try byPosition.ensureTotalCapacity(allocator, chunks);
        errdefer byPosition.deinit(allocator);
        const kinds = try allocator.alloc(Kinds, chunksWithBlocks);
        errdefer allocator.free(kinds);
        const free = try allocator.alloc(u32, chunksWithBlocks);
        for (free, 0..) |*slot, i| slot.* = @intCast(i);
        return .{ .entries = entries, .byPosition = byPosition, .kinds = kinds, .free = free, .freeCount = free.len };
    }

    fn deinit(self: *ChunkCache, allocator: std.mem.Allocator) void {
        allocator.free(self.free);
        allocator.free(self.kinds);
        self.byPosition.deinit(allocator);
        allocator.free(self.entries);
    }

    fn get(self: *ChunkCache, position: Position) Lookup {
        const index = self.byPosition.get(position) orelse return .uncached;
        const entry = &self.entries[index];
        self.clock += 1;
        entry.used = self.clock;
        return if (entry.slot) |slot| .{ .kinds = &self.kinds[slot] } else .empty;
    }

    /// Remembers `position`, which must not be cached yet, and returns where to write its kinds
    /// if it has `blocks`, or null.
    fn put(self: *ChunkCache, position: Position, blocks: bool) ?*Kinds {
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
        return if (slot) |s| &self.kinds[s] else null;
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
    try std.testing.expectEqual(7, cache.get(a).kinds[0]);
    try std.testing.expect(cache.get(c) == .empty);
    // No slot is free for d's blocks: b, used longest ago of the chunks with blocks, makes room.
    cache.put(d, true).?[0] = 9;
    try std.testing.expect(cache.get(b) == .uncached);
    try std.testing.expectEqual(9, cache.get(d).kinds[0]);
    try std.testing.expectEqual(7, cache.get(a).kinds[0]);
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

/// What every worker shares, read-only while they draw, and their totals once they're done.
fn View(comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const name = folder;

        source: *const Source,
        /// How each block ID is drawn: 0 not at all, otherwise its map type + 1.
        kinds: []u8,
        /// Each map type's three face colours at each height: `(mapType * height + y) * 3`, top,
        /// south, east.
        colours: []u32,
        height: u16,
        chunksRead: usize = 0,

        fn init(allocator: std.mem.Allocator, source: *const Source, palette: *const world.Palette) !Self {
            const kinds = try allocator.alloc(u8, source.blockCount());
            errdefer allocator.free(kinds);
            for (kinds, 0..) |*kind, id| {
                const mapType = source.mapType(@intCast(id));
                kind.* = if (!source.isVisible(@intCast(id)) or mapType == .plant) 0 else @backingInt(mapType) + 1;
            }
            const heights = source.heights();
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
            return .{ .source = source, .kinds = kinds, .colours = colours, .height = heights.world };
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.colours);
            allocator.free(self.kinds);
        }

        pub fn collect(self: *Self, worker: *const Worker) void {
            self.chunksRead += worker.reader.chunksRead;
        }

        /// One thread's reader, chunk cache and buffers, reused for every tile it draws.
        pub const Worker = struct {
            view: *const Self,
            reader: Source.Reader,
            /// Where a chunk is read into before its blocks' kinds go into the cache.
            chunk: *world.Chunk,
            cache: ChunkCache,
            /// The depth of what each pixel shows: x + y + z of its block, larger nearer.
            depth: *[tiles.size * tiles.size]i32,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                var reader: Source.Reader = try .init(view.source, allocator, null);
                errdefer reader.deinit(allocator);
                const chunk = try allocator.create(world.Chunk);
                errdefer allocator.destroy(chunk);
                var cache: ChunkCache = try .init(allocator, ChunkCache.defaultChunks, ChunkCache.defaultChunksWithBlocks);
                errdefer cache.deinit(allocator);
                const depth = try allocator.create([tiles.size * tiles.size]i32);
                return .{ .view = view, .reader = reader, .chunk = chunk, .cache = cache, .depth = depth };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                allocator.destroy(self.depth);
                self.cache.deinit(allocator);
                allocator.destroy(self.chunk);
                self.reader.deinit(allocator);
            }

            /// Draws the nearest block on each line of sight through the tile. Returns false if
            /// none has one.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                @memset(pixels, tiles.transparent);
                @memset(self.depth, std.math.minInt(i32));
                const x0 = @as(i64, tile.x) * tiles.size;
                const y0 = @as(i64, tile.y) * tiles.size;
                var any = false;
                // The lines whose squares fall on the tile (`Line.square`).
                var u = @divFloor(x0 - blockWidth, across) + 2;
                while (u <= @divFloor(x0 + tiles.size - 1, across) + 1) : (u += 1) {
                    var v = @divFloor(y0 - blockWidth, down) + 3;
                    while (v <= @divFloor(y0 + tiles.size - 1, down) + 2) : (v += 1) {
                        if (@mod(u + v, 2) != 0) continue;
                        const line: Line = .{ .u = u, .v = v };
                        const block = try self.nearestBlock(line) orelse continue;
                        const at = ((@as(usize, block.kind) - 1) * self.view.height + @as(usize, @intCast(block.y))) * 3;
                        const square = line.square();
                        if (self.drawBlock(square.left - x0, square.top - y0, @intCast(block.x + block.y + block.z), self.view.colours[at..][0..3], pixels)) any = true;
                    }
                }
                return any;
            }

            const Block = struct { x: i64, y: i64, z: i64, kind: u8 };

            /// The nearest drawn block on a line of sight: following it from the top of the world
            /// down, the first one, or null if none is. A chunk without one is passed in one step.
            fn nearestBlock(self: *Worker, line: Line) !?Block {
                var y: i64 = @as(i64, self.view.height) - 1;
                while (y >= 0) {
                    const x, const z = line.at(y);
                    const cx = @divFloor(x, side);
                    const cy = @divFloor(y, side);
                    const cz = @divFloor(z, side);
                    var lx: usize = @intCast(x - cx * side);
                    var ly: usize = @intCast(y - cy * side);
                    var lz: usize = @intCast(z - cz * side);
                    // The line's blocks in this chunk, from here until it leaves it.
                    const steps = @min(lx, ly, lz) + 1;
                    if (try self.chunkKinds(cx, cy, cz)) |kinds| {
                        for (0..steps) |step| {
                            const kind = kinds[(ly * side + lz) * side + lx];
                            if (kind != 0) {
                                const back: i64 = @intCast(step);
                                return .{ .x = x - back, .y = y - back, .z = z - back, .kind = kind };
                            }
                            lx -%= 1;
                            ly -%= 1;
                            lz -%= 1;
                        }
                    }
                    y -= @intCast(steps);
                }
                return null;
            }

            /// How each block of chunk (x, y, z) is drawn, from the cache or else read; null for a
            /// chunk with nothing to draw.
            fn chunkKinds(self: *Worker, x: i64, y: i64, z: i64) !?*const ChunkCache.Kinds {
                const limit = std.math.maxInt(i32);
                if (@abs(x) > limit or @abs(y) > limit or @abs(z) > limit) return null;
                const position: ChunkCache.Position = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) };
                switch (self.cache.get(position)) {
                    .empty => return null,
                    .kinds => |kinds| return kinds,
                    .uncached => {},
                }
                if (!try self.reader.readChunk(position.x, position.y, position.z, self.chunk)) {
                    _ = self.cache.put(position, false);
                    return null;
                }
                const kinds = self.cache.put(position, true).?;
                const byId = self.view.kinds;
                for (kinds, self.chunk.solid, self.chunk.liquid) |*kind, solid, liquid| {
                    const solidKind = if (solid >= 0 and solid < byId.len) byId[@intCast(solid)] else 0;
                    const liquidKind = if (liquid >= 0 and liquid < byId.len) byId[@intCast(liquid)] else 0;
                    kind.* = if (solidKind != 0) solidKind else liquidKind;
                }
                return kinds;
            }

            fn drawBlock(self: *Worker, left: i64, top: i64, depth: i32, colours: *const [3]u32, pixels: *tiles.Pixels) bool {
                var any = false;
                for (0..blockWidth) |row| {
                    const py = top + @as(i64, @intCast(row));
                    if (py < 0 or py >= tiles.size) continue;
                    for (0..blockWidth) |column| {
                        const px = left + @as(i64, @intCast(column));
                        if (px < 0 or px >= tiles.size) continue;
                        const face = faces[row][column];
                        if (face == .none) continue;
                        const p: usize = @intCast(py * tiles.size + px);
                        if (depth <= self.depth[p]) continue;
                        self.depth[p] = depth;
                        pixels[p] = colours[@backingInt(face) - 1];
                        any = true;
                    }
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
