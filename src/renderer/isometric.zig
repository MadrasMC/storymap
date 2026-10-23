//! The isometric view, looking north-west from above: every block drawn as a cube in its map
//! type's relief colour (`relief.zig`), its top, south and east faces lit differently. Plants
//! aren't drawn.
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
pub const blockWidth = 16;
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

    fn ofChunk(x: i64, y: i64, z: i64) Box {
        return .of(x * side, y * side, z * side, x * side + side - 1, y * side + side - 1, z * side + side - 1);
    }

    fn overlaps(self: Box, tile: tiles.Tile) bool {
        const x0 = @as(i64, tile.x) * tiles.size;
        const y0 = @as(i64, tile.y) * tiles.size;
        return self.left < x0 + tiles.size and self.right > x0 and self.top < y0 + tiles.size and self.bottom > y0;
    }
};

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
    // One chunk column 256 blocks high, drawn 512 pixels wide and 2,304 high.
    try std.testing.expectEqual(Box{ .left = -256, .top = -2048, .right = 256, .bottom = 256 }, Box.of(0, 0, 0, 31, 255, 31));
    const list = try tileList(std.testing.allocator, &.{.{ .x = 0, .z = 0 }}, 256);
    defer std.testing.allocator.free(list);
    // Tile columns -1 and 0, rows -4 to 0.
    try std.testing.expectEqual(10, list.len);
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
    // The top face's corners are at the middle of each edge of the top half.
    try std.testing.expectEqual(Face.top, faces[3][8]);
    try std.testing.expectEqual(Face.none, faces[0][0]);
    try std.testing.expectEqual(Face.south, faces[10][3]);
    try std.testing.expectEqual(Face.east, faces[10][12]);
    try std.testing.expectEqual(Face.none, faces[15][0]);
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

        /// One thread's reader and buffers, reused for every tile it draws.
        pub const Worker = struct {
            view: *const Self,
            reader: Source.Reader,
            chunk: *world.Chunk,
            /// How each block of `chunk` is drawn, as `kinds`.
            chunkKinds: *[world.Chunk.volume]u8,
            /// The depth of what each pixel shows: x + y + z of its block, larger nearer.
            depth: *[tiles.size * tiles.size]i32,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                var reader: Source.Reader = try .init(view.source, allocator, null);
                errdefer reader.deinit(allocator);
                const chunk = try allocator.create(world.Chunk);
                errdefer allocator.destroy(chunk);
                const chunkKinds = try allocator.create([world.Chunk.volume]u8);
                errdefer allocator.destroy(chunkKinds);
                const depth = try allocator.create([tiles.size * tiles.size]i32);
                return .{ .view = view, .reader = reader, .chunk = chunk, .chunkKinds = chunkKinds, .depth = depth };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                allocator.destroy(self.depth);
                allocator.destroy(self.chunkKinds);
                allocator.destroy(self.chunk);
                self.reader.deinit(allocator);
            }

            /// Draws every chunk whose blocks fall on the tile. Returns false if none do.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                @memset(pixels, tiles.transparent);
                @memset(self.depth, std.math.minInt(i32));
                const x0 = @as(i64, tile.x) * tiles.size;
                const y0 = @as(i64, tile.y) * tiles.size;
                const levels = std.math.divCeil(i64, self.view.height, side) catch unreachable;
                var any = false;
                // Chunks by u = x − z, across the screen, and s = x + z, down it.
                var cy: i64 = 0;
                while (cy < levels) : (cy += 1) {
                    var u = @divFloor(x0, side * across) - 1;
                    while (u <= @divFloor(x0 + tiles.size, side * across) + 1) : (u += 1) {
                        var s = @divFloor(y0 + cy * side * below, side * down) - 3;
                        while (s <= @divFloor(y0 + tiles.size + (cy + 1) * side * below, side * down) + 1) : (s += 1) {
                            if (@mod(s + u, 2) != 0) continue;
                            const cx = @divExact(s + u, 2);
                            const cz = @divExact(s - u, 2);
                            if (!Box.ofChunk(cx, cy, cz).overlaps(tile)) continue;
                            if (cx < std.math.minInt(i32) or cx > std.math.maxInt(i32) or cz < std.math.minInt(i32) or cz > std.math.maxInt(i32)) continue;
                            if (!try self.reader.readChunk(@intCast(cx), @intCast(cy), @intCast(cz), self.chunk)) continue;
                            if (self.drawChunk(cx, cy, cz, x0, y0, pixels)) any = true;
                        }
                    }
                }
                return any;
            }

            /// Draws the blocks of `chunk`, at (cx, cy, cz), that are seen: those with an east,
            /// south or upper neighbour in it that isn't drawn, and those on its east, south and
            /// upper sides. Returns whether it drew any pixel.
            fn drawChunk(self: *Worker, cx: i64, cy: i64, cz: i64, x0: i64, y0: i64, pixels: *tiles.Pixels) bool {
                const chunk = self.chunk;
                const kinds = self.view.kinds;
                for (self.chunkKinds, chunk.solid, chunk.liquid) |*kind, solid, liquid| {
                    const solidKind = if (solid >= 0 and solid < kinds.len) kinds[@intCast(solid)] else 0;
                    const liquidKind = if (liquid >= 0 and liquid < kinds.len) kinds[@intCast(liquid)] else 0;
                    kind.* = if (solidKind != 0) solidKind else liquidKind;
                }
                const height = self.view.height;
                var any = false;
                for (0..side) |y| for (0..side) |z| for (0..side) |x| {
                    const i = (y * side + z) * side + x;
                    const kind = self.chunkKinds[i];
                    if (kind == 0) continue;
                    if (x + 1 < side and y + 1 < side and z + 1 < side and
                        self.chunkKinds[i + 1] != 0 and self.chunkKinds[i + side] != 0 and self.chunkKinds[i + side * side] != 0) continue;
                    const bx = cx * side + @as(i64, @intCast(x));
                    const by = cy * side + @as(i64, @intCast(y));
                    const bz = cz * side + @as(i64, @intCast(z));
                    if (by >= height) continue;
                    const left = (bx - bz - 1) * across - x0;
                    const top = (bx + bz) * down - (by + 1) * below - y0;
                    if (left >= tiles.size or left + blockWidth <= 0 or top >= tiles.size or top + blockWidth <= 0) continue;
                    const at = ((@as(usize, kind) - 1) * height + @as(usize, @intCast(by))) * 3;
                    const colours = self.view.colours[at..][0..3];
                    if (self.drawBlock(left, top, @intCast(bx + by + bz), colours, pixels)) any = true;
                };
                return any;
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
