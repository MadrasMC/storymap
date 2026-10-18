//! The top-down map: one pixel per block column, coloured by what's on top, in tiles of
//! 512 × 512 blocks (see tiles.zig). It draws from what a game's reader tells it about each
//! column (see columns.zig), so it knows nothing of any game's save format.
//!
//! A source is a game's save, opened for reading, with:
//! - `tileList: []const tiles.Tile`, the tiles that may have something to draw;
//! - `game() viewer.Game`, `world() viewer.World` and `heights() columns.Heights`;
//! - `blockCount() usize`, `blockName(id: i32) ?[]const u8` and `mapType(id: i32) columns.MapType`,
//!   for the game's block IDs;
//! - `Reader`, one per thread, with `init(source: *const Source, allocator) !Reader`,
//!   `deinit(*Reader, allocator)`, `read(*Reader, tile: tiles.Tile, area: *columns.Area) !void`
//!   and a `chunksRead: usize` count.
const std = @import("std");
const Io = std.Io;
const columns = @import("../columns.zig");
const tiles = @import("../tiles.zig");
const viewer = @import("../viewer.zig");
const Style = @import("Style.zig");
const Rgb = Style.Rgb;

/// What a render covered and how long it took.
pub const Stats = struct {
    /// Tiles written, at every level.
    tiles: usize = 0,
    levels: usize = 0,
    /// Chunks read: those holding a surface block, in each tile and the ring around it.
    chunksRead: usize = 0,
    /// Rendering the tiles, start to finish.
    render: Io.Duration = .zero,
    /// Time the workers spent drawing tiles, and encoding and writing them, added up.
    draw: Io.Duration = .zero,
    encode: Io.Duration = .zero,
};

pub const Options = struct {
    /// Records the stages' times here instead of printing a summary of the map.
    stats: ?*Stats = null,
    /// What draws the viewer page around the map, when the tiles go into a folder.
    theme: viewer.Theme = viewer.printed,
    /// How the map is coloured: the theme's `topdown/style.txt`.
    style: Style = Style.printed,
};

/// Renders the top-down tiles of `source` into `output`, with the viewer page beside them.
pub fn render(comptime Source: type, allocator: std.mem.Allocator, io: Io, source: *const Source, output: tiles.Output, options: Options) !void {
    const start: Io.Timestamp = .now(io, .awake);
    var view: View(Source) = try .init(allocator, source, options.style);
    defer view.deinit(allocator);

    var written: std.ArrayList(tiles.Written) = .empty;
    defer written.deinit(allocator);
    const rendered = try tiles.render(View(Source), allocator, io, &view, source.tileList, output, &written);
    // The viewer page goes next to the tiles. With more views, it'll list them all.
    switch (output) {
        .folder => |folder| try viewer.write(allocator, io, folder, source.game(), source.world(), Io.Timestamp.now(io, .real).toSeconds(), &.{
            .{ .name = View(Source).name, .title = "Top-down", .projection = "topdown", .written = written.items },
        }, options.theme),
        .discard => {},
    }

    if (options.stats) |out| {
        out.* = .{
            .tiles = rendered.tiles,
            .levels = rendered.levels,
            .chunksRead = view.chunksRead,
            .render = start.untilNow(io, .awake),
            .draw = rendered.draw,
            .encode = rendered.encode,
        };
        return;
    }
    std.debug.print("{} tiles in {} levels, surface y {}..{}\n", .{ rendered.tiles, rendered.levels, view.lowest, view.highest });
    printSurfaceBlocks(Source, source, view.surface);
}

/// What every worker shares, read-only while they draw, and their totals once they're done.
fn View(comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const name = "topdown";

        source: *const Source,
        heights: Heights,
        style: Style,

        chunksRead: usize = 0,
        /// How many columns show each block ID from above.
        surface: []usize,
        /// The lowest and highest solid surface.
        lowest: u16 = std.math.maxInt(u16),
        highest: u16 = 0,

        fn init(allocator: std.mem.Allocator, source: *const Source, style: Style) !Self {
            const surface = try allocator.alloc(usize, source.blockCount());
            @memset(surface, 0);
            return .{ .source = source, .heights = .of(source.heights()), .style = style, .surface = surface };
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.surface);
        }

        pub fn collect(self: *Self, worker: *const Worker) void {
            self.chunksRead += worker.reader.chunksRead;
            for (self.surface, worker.surface) |*total, count| total.* += count;
            self.lowest = @min(self.lowest, worker.lowest);
            self.highest = @max(self.highest, worker.highest);
        }

        /// One thread's reader and buffers, reused for every tile it draws.
        pub const Worker = struct {
            view: *const Self,
            reader: Source.Reader,
            area: columns.Area,
            /// The shaded style's shading, a byte per pixel as the game keeps it, and a copy of
            /// it before blurring.
            shade: []u8,
            unblurred: []u8,

            surface: []usize,
            lowest: u16 = std.math.maxInt(u16),
            highest: u16 = 0,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                var reader: Source.Reader = try .init(view.source, allocator);
                errdefer reader.deinit(allocator);
                var area: columns.Area = try .init(allocator);
                errdefer area.deinit(allocator);
                const shade = try allocator.alloc(u8, tiles.size * tiles.size);
                errdefer allocator.free(shade);
                const unblurred = try allocator.alloc(u8, tiles.size * tiles.size);
                errdefer allocator.free(unblurred);
                const surface = try allocator.alloc(usize, view.surface.len);
                @memset(surface, 0);
                return .{ .view = view, .reader = reader, .area = area, .shade = shade, .unblurred = unblurred, .surface = surface };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                allocator.free(self.surface);
                allocator.free(self.unblurred);
                allocator.free(self.shade);
                self.area.deinit(allocator);
                self.reader.deinit(allocator);
            }

            /// Reads the tile's block columns and the ring around them, then colours its
            /// pixels. Returns false if it has nothing on it.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                try self.reader.read(tile, &self.area);
                return switch (self.view.style.kind) {
                    .relief => self.paintRelief(pixels),
                    .shaded => self.paintShaded(pixels),
                };
            }

            /// Counts what a column shows from above, for the summary.
            fn count(self: *Worker, i: usize, block: i32) void {
                if (self.area.top[i]) |solid| {
                    self.lowest = @min(self.lowest, solid);
                    self.highest = @max(self.highest, solid);
                }
                if (block >= 0 and block < self.surface.len) self.surface[@intCast(block)] += 1;
            }

            /// Colours the tile's pixels from the area as a relief map, and counts what it
            /// shows. Returns false if nothing is drawn.
            fn paintRelief(self: *Worker, pixels: *tiles.Pixels) bool {
                const area = &self.area;
                const view = self.view;
                const side = columns.Area.side;
                var any = false;
                for (0..tiles.size) |py| for (0..tiles.size) |px| {
                    const i = (py + 1) * side + px + 1;
                    const pixel = &pixels[py * tiles.size + px];
                    const here = Surface.of(area.top[i], area.liquidTop[i]);
                    const y = here.height() orelse {
                        pixel.* = tiles.transparent;
                        continue;
                    };
                    any = true;
                    const west: Surface = .of(area.top[i - 1], area.liquidTop[i - 1]);
                    const north: Surface = .of(area.top[i - side], area.liquidTop[i - side]);
                    const east: Surface = .of(area.top[i + 1], area.liquidTop[i + 1]);
                    const south: Surface = .of(area.top[i + side], area.liquidTop[i + side]);

                    const block = if (here == .liquid) area.liquidBlock[i] else area.topBlock[i];
                    self.count(i, block);

                    const style = &view.style;
                    const mapType = view.source.look(block).mapType;
                    if (here == .liquid) {
                        // Where water meets land, its edge, as an old map inks its coastlines.
                        const shore = west == .land or north == .land or east == .land or south == .land;
                        // A liquid the game's reader doesn't place is drawn as a lake.
                        const liquid = if (mapType.isLiquid()) mapType else .lake;
                        pixel.* = if (shore and liquid != .lava)
                            rgb(style.wateredge)
                        else
                            liquidColour(style.colours.get(liquid), if (area.top[i]) |ground| y - ground else maxDepth);
                        continue;
                    }
                    // Neighbours without blocks count as level ground.
                    const slope = @as(i32, y) * 2 - (west.height() orelse y) - (north.height() orelse y);
                    pixel.* = groundColour(style, style.colours.get(mapType), y, view.heights, slope);
                };
                return any;
            }

            /// Colours the tile's pixels from the area as the game draws its own map, and
            /// counts what it shows. Returns false if nothing is drawn. As in vsessentialsmod's
            /// `ChunkMapLayer.GenerateChunkImage`: each column takes its type's colour; a
            /// column higher than its north-west, west and north neighbours, as a whole, is
            /// lit, and one lower shaded, more for steeper slopes; the shading is blurred within
            /// each chunk and multiplied in. Lakes aren't shaded, and are edged in `wateredge`
            /// where they meet anything else.
            fn paintShaded(self: *Worker, pixels: *tiles.Pixels) bool {
                const area = &self.area;
                const view = self.view;
                const style = &view.style;
                const side = columns.Area.side;
                var any = false;
                for (0..tiles.size) |py| for (0..tiles.size) |px| {
                    const i = (py + 1) * side + px + 1;
                    const p = py * tiles.size + px;
                    self.shade[p] = 128;
                    const here = Surface.of(area.top[i], area.liquidTop[i]);
                    const y = here.height() orelse {
                        pixels[p] = tiles.transparent;
                        continue;
                    };
                    any = true;
                    const top = if (here == .liquid) area.liquidBlock[i] else area.topBlock[i];
                    self.count(i, top);
                    var look = view.source.look(top);
                    // Under a cover such as snow, what's beneath shows, one block lower.
                    var at = y;
                    if (here == .land and look.cover and area.underBlock[i] != 0) {
                        look = view.source.look(area.underBlock[i]);
                        at = y - 1;
                    }
                    if (look.lake or (here == .liquid and !look.mapType.isLiquid())) {
                        // An edge where any neighbour isn't lake at the same height. Next to a
                        // column that isn't drawn, the game draws water, as it can't tell.
                        const neighbours = [_]usize{ i - 1, i + 1, i - side, i + side };
                        var surrounded = true;
                        for (neighbours) |j| {
                            if (area.top[j] == null and area.liquidTop[j] == null) {
                                surrounded = true;
                                break;
                            }
                            if (!self.lakeAt(j, at)) surrounded = false;
                        }
                        const lakeType = if (look.mapType.isLiquid() or look.lake) look.mapType else .lake;
                        pixels[p] = rgb(if (surrounded) style.colours.get(lakeType) else style.wateredge);
                        continue;
                    }
                    pixels[p] = rgb(style.colours.get(look.mapType));
                    const nw = rise(y, area, i - side - 1);
                    const w = rise(y, area, i - 1);
                    const n = rise(y, area, i - side);
                    const direction = signOf(nw) + signOf(w) + signOf(n);
                    const steepness: f32 = @floatFromInt(@max(@abs(nw), @abs(w), @abs(n)));
                    const light: f32 = if (direction > 0)
                        1.08 + @min(0.5, steepness / 10) / 1.25
                    else if (direction < 0)
                        0.92 - @min(0.5, steepness / 10) / 1.25
                    else
                        1;
                    self.shade[p] = @intFromFloat(128 * light);
                };
                if (!any) return false;

                @memcpy(self.unblurred, self.shade);
                var y: usize = 0;
                while (y < tiles.size) : (y += 32) {
                    var x: usize = 0;
                    while (x < tiles.size) : (x += 32) blurChunk(self.shade, x, y);
                }
                for (pixels, self.shade, self.unblurred) |*pixel, blurred, original| {
                    if (pixel.* == tiles.transparent) continue;
                    // The blurred shading in fifths, and the unblurred one's remainder.
                    const coarse = @trunc((@as(f32, @floatFromInt(blurred)) / 128 - 1) * 5) / 5;
                    const fine = @rem((@as(f32, @floatFromInt(original)) / 128 - 1) * 5, 1) / 5;
                    pixel.* = multiply(pixel.*, coarse + fine + 1);
                }
                return true;
            }

            /// Whether the block at height `y` in column `i`, which is drawn, is drawn as a lake.
            fn lakeAt(self: *const Worker, i: usize, y: u16) bool {
                const area = &self.area;
                const source = self.view.source;
                if (area.liquidTop[i]) |liquid| {
                    // Liquid reaches down to `y` unless the solid block is in the way: below
                    // it is the ground it stands on, above it something over it, like leaves.
                    const solid = area.top[i];
                    if (liquid >= y and (solid == null or solid.? < y or solid.? > liquid)) return source.look(area.liquidBlock[i]).lake;
                }
                if (area.top[i]) |solid| if (solid == y) return source.look(area.topBlock[i]).lake;
                return false;
            }
        };
    };
}

/// -1, 0 or 1.
fn signOf(value: i32) i32 {
    return @as(i32, @intFromBool(value > 0)) - @intFromBool(value < 0);
}

/// How much higher a column at height `y` is than column `i`, or 0 if `i` isn't drawn.
fn rise(y: u16, area: *const columns.Area, i: usize) i32 {
    const other = Surface.of(area.top[i], area.liquidTop[i]).height() orelse return 0;
    return @as(i32, y) - other;
}

/// Each channel of `pixel` times `factor`, kept within 0 to 255 and rounded down, as the
/// game's `ColorUtil.ColorMultiply3Clamped` does.
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
/// `BlurTool.Blur(map, 32, 32, 2)` does: across, then down, each value the average of
/// itself and its neighbours on either side within the chunk, rounded down.
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

/// The five most common blocks seen from above, by name.
fn printSurfaceBlocks(comptime Source: type, source: *const Source, surface: []const usize) void {
    var columnCount: usize = 0;
    for (surface) |n| columnCount += n;
    if (columnCount == 0) return;
    var shown: [5]usize = undefined;
    var count: usize = 0;
    std.debug.print("most common surface blocks:", .{});
    while (count < shown.len) : (count += 1) {
        // The most common block not shown yet.
        var best: ?usize = null;
        for (surface, 0..) |n, id| {
            if (n == 0 or std.mem.indexOfScalar(usize, shown[0..count], id) != null) continue;
            if (best == null or n > surface[best.?]) best = id;
        }
        const id = best orelse break;
        shown[count] = id;
        const percent = surface[id] * 100 / columnCount;
        const separator = if (count == 0) "" else ",";
        if (source.blockName(@intCast(id))) |code| {
            std.debug.print("{s} {s} {}%", .{ separator, code, percent });
        } else {
            std.debug.print("{s} #{} {}%", .{ separator, id, percent });
        }
    }
    std.debug.print("\n", .{});
}

/// What a column shows from above, and at what height.
const Surface = union(enum) {
    /// No blocks at all, as far as the save goes.
    none,
    land: u16,
    /// Liquid at or above the highest solid block. Plants growing in water share their
    /// block with it, so the water still shows.
    liquid: u16,

    fn of(top: ?u16, liquidTop: ?u16) Surface {
        const liquid = liquidTop orelse return if (top) |y| .{ .land = y } else .none;
        const land = top orelse return .{ .liquid = liquid };
        return if (liquid >= land) .{ .liquid = liquid } else .{ .land = land };
    }

    fn height(self: Surface) ?u16 {
        return switch (self) {
            .none => null,
            .land, .liquid => |y| y,
        };
    }
};

test Surface {
    try std.testing.expectEqual(Surface.none, Surface.of(null, null));
    try std.testing.expectEqual(Surface{ .land = 90 }, Surface.of(90, null));
    try std.testing.expectEqual(Surface{ .liquid = 109 }, Surface.of(90, 109));
    try std.testing.expectEqual(Surface{ .liquid = 109 }, Surface.of(109, 109)); // seaweed
    try std.testing.expectEqual(Surface{ .land = 120 }, Surface.of(120, 12)); // water in a cave
    try std.testing.expectEqual(Surface{ .liquid = 109 }, Surface.of(null, 109));
}

/// Water this deep or deeper takes the darkest colour.
const maxDepth = 16;
/// How much the deepest liquid darkens towards black, in 256ths: a faded wash when shallow,
/// as on an old map.
const deepening = 102;

/// The colour of a liquid of colour `base` standing `depth` blocks above the ground below it.
fn liquidColour(base: Rgb, depth: u16) u32 {
    const fraction = @as(usize, @min(depth, maxDepth)) * deepening / maxDepth;
    return rgb(mix(base, .{ 0, 0, 0 }, fraction));
}

test liquidColour {
    const lake = Style.printed.colours.get(.lake);
    try std.testing.expectEqual(rgb(lake), liquidColour(lake, 0));
    try std.testing.expectEqual(liquidColour(lake, maxDepth), liquidColour(lake, 200));
    try std.testing.expect(liquidColour(lake, maxDepth) & 0xFF < rgb(lake) & 0xFF);
}

/// `from` blended towards `to` by `fraction` 256ths.
fn mix(from: [3]u8, to: [3]u8, fraction: usize) [3]u8 {
    var mixed: [3]u8 = undefined;
    for (&mixed, from, to) |*channel, a, b| {
        channel.* = @intCast((@as(usize, a) * (256 - fraction) + @as(usize, b) * fraction) / 256);
    }
    return mixed;
}

/// How much the highest ground pales towards white, in 256ths.
const paling = 154;

/// The surface heights ground colours are spread over. They depend only on the world, so every
/// part of a map, and every world, is coloured the same way.
const Heights = struct {
    /// The darkest ground, all ink, and everything below it.
    low: u16,
    /// Sea level: each type's own colour.
    ground: u16,
    /// The palest ground, and everything above it.
    high: u16,

    /// For a world: in a default 256-block world, 70, 110 (sea level) and 174. The test worlds'
    /// surfaces have a median of 112. The ends are fractions of the world height, on the guess
    /// that taller worlds have taller terrain too.
    fn of(world: columns.Heights) Heights {
        const height: u32 = world.world;
        const sea: u32 = world.sea;
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

/// The colour of ground of colour `base` at height `y`: `base` at sea level, darkening
/// towards the style's ink below it and paling towards white above it. `slope` is how much
/// higher the column is than its west and north neighbours together: slopes facing the
/// north-west light are brightened, the others darkened, as on a hand-shaded relief map.
fn groundColour(style: *const Style, base: Rgb, y: u16, heights: Heights, slope: i32) u32 {
    const clamped = std.math.clamp(y, heights.low, heights.high);
    var channels = if (clamped <= heights.ground)
        mix(base, style.ink, share(heights.ground - clamped, heights.ground - heights.low))
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

/// An opaque pixel.
fn rgb(colour: Rgb) u32 {
    return tiles.rgba(colour[0], colour[1], colour[2], 0xFF);
}

test groundColour {
    const style = &Style.printed;
    const land = style.colours.get(.land);
    const heights: Heights = .{ .low = 10, .ground = 60, .high = 110 };
    // Level ground: ink at the low end, its own colour at sea level, pale at the high end.
    try std.testing.expectEqual(rgb(style.ink), groundColour(style, land, 10, heights, 0));
    try std.testing.expectEqual(rgb(land), groundColour(style, land, 60, heights, 0));
    try std.testing.expectEqual(groundColour(style, land, 110, heights, 0), groundColour(style, land, 200, heights, 0));
    try std.testing.expect(groundColour(style, land, 110, heights, 0) & 0xFF > rgb(land) & 0xFF);
    // A slope facing the light is brighter, one facing away darker.
    const level = groundColour(style, land, 40, heights, 0);
    try std.testing.expect(groundColour(style, land, 40, heights, 2) & 0xFF > level & 0xFF);
    try std.testing.expect(groundColour(style, land, 40, heights, -2) & 0xFF < level & 0xFF);
}
