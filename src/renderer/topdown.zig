//! The top-down map: one pixel per block column, coloured by what's on top, in tiles of
//! 512 × 512 blocks (see tiles.zig). It draws from what a game's reader tells it about each
//! column (see the `world` module), so it knows nothing of any game's save format. It draws
//! Storymap's relief map itself, and the game's own maps through the game's reader.
//!
//! A source is a game's save, opened for reading, with:
//! - `tileList: []const tiles.Tile`, the tiles that may have something to draw;
//! - `heights() world.Heights`;
//! - `blockCount() usize`, `blockName(id: i32) ?[]const u8` and `mapType(id: i32) world.MapType`,
//!   for the game's block IDs;
//! - `Map`, an enum of the game's own maps, by the names a theme's style gives them;
//! - `Reader`, one per thread, with `init(source: *const Source, allocator, map: ?Map) !Reader`,
//!   reading what `map` needs beyond the surface, `deinit(*Reader, allocator)`,
//!   `read(*Reader, tile: tiles.Tile, surface: *world.Surface) !void` and a `chunksRead: usize`
//!   count;
//! - `MapPainter`, one per thread drawing one of the game's maps, with
//!   `init(source: *const Source, allocator, map: Map) !MapPainter`, `deinit(MapPainter, allocator)`
//!   and `draw(*MapPainter, reader: *const Reader, tile, surface: *const world.Surface,
//!   palette: *const world.Palette, pixels: *tiles.Pixels) void`, from what the reader just read.
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const tiles = @import("tiles");
const Style = @import("theme").Style;
const Rgb = Style.Rgb;

/// What a render covered and how long it took.
pub const Stats = struct {
    /// Tiles written, at every level.
    tiles: usize = 0,
    levels: usize = 0,
    /// Chunks read: those holding a surface block, in each tile and the ring around it.
    chunksRead: usize = 0,
    /// The map's area, in blocks: the block columns drawn at full detail.
    area: usize = 0,
    /// Rendering the tiles, start to finish.
    render: Io.Duration = .zero,
    /// Time the workers spent drawing tiles, and encoding and writing them, added up.
    draw: Io.Duration = .zero,
    encode: Io.Duration = .zero,
};

/// The view's folder among the tiles, e.g. `topdown/0/1000_999.png`.
pub const folder = "topdown";
pub const title = "Top-down";
/// How a level-0 pixel maps to a block: one pixel per block, pixel x and y being block x and z.
pub const projection = "topdown";

pub const Options = struct {
    /// How the map is coloured: a theme's `topdown/style.txt`.
    style: Style,
    /// Records the stages' times here instead of printing a summary of the map.
    stats: ?*Stats = null,
};

/// Renders the top-down tiles of `source` into `output`, and returns the tiles written, at every
/// level, which the caller frees with `allocator`. A style naming a map the game doesn't draw
/// is error.UnknownMap.
pub fn render(comptime Source: type, allocator: std.mem.Allocator, io: Io, source: *const Source, output: tiles.Output, options: Options) ![]tiles.Written {
    const start: Io.Timestamp = .now(io, .awake);
    var view: View(Source) = try .init(allocator, source, options.style);
    defer view.deinit(allocator);

    var written: std.ArrayList(tiles.Written) = .empty;
    errdefer written.deinit(allocator);
    const rendered = try tiles.render(View(Source), allocator, io, &view, source.tileList, output, &written);
    const list = try written.toOwnedSlice(allocator);

    if (options.stats) |out| {
        out.* = .{
            .tiles = rendered.tiles,
            .levels = rendered.levels,
            .chunksRead = view.chunksRead,
            .area = view.drawn,
            .render = start.untilNow(io, .awake),
            .draw = rendered.draw,
            .encode = rendered.encode,
        };
        return list;
    }
    std.debug.print("{} tiles in {} levels, surface y {}..{}\n", .{ rendered.tiles, rendered.levels, view.lowest, view.highest });
    printSurfaceBlocks(Source, source, view.blockCounts);
    return list;
}

/// What every worker shares, read-only while they draw, and their totals once they're done.
fn View(comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const name = folder;

        source: *const Source,
        heights: Heights,
        style: Style,
        /// The map drawn: relief, or one of the game's own.
        map: union(enum) { relief, game: Source.Map },
        /// The style's colours, for the game's own maps.
        palette: world.Palette,

        chunksRead: usize = 0,
        /// Block columns drawn at full detail.
        drawn: usize = 0,
        /// How many columns show each block ID from above.
        blockCounts: []usize,
        /// The lowest and highest solid surface.
        lowest: u16 = std.math.maxInt(u16),
        highest: u16 = 0,

        fn init(allocator: std.mem.Allocator, source: *const Source, style: Style) !Self {
            const map: @FieldType(Self, "map") = switch (style.kind) {
                .relief => .relief,
                .game => |mapName| .{ .game = std.meta.stringToEnum(Source.Map, mapName) orelse return error.UnknownMap },
            };
            const blockCounts = try allocator.alloc(usize, source.blockCount());
            @memset(blockCounts, 0);
            return .{
                .source = source,
                .heights = .of(source.heights()),
                .style = style,
                .map = map,
                .palette = .{ .colours = style.colours, .ink = style.ink, .wateredge = style.wateredge },
                .blockCounts = blockCounts,
            };
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.blockCounts);
        }

        pub fn collect(self: *Self, worker: *const Worker) void {
            self.chunksRead += worker.reader.chunksRead;
            self.drawn += worker.drawn;
            for (self.blockCounts, worker.blockCounts) |*total, count| total.* += count;
            self.lowest = @min(self.lowest, worker.lowest);
            self.highest = @max(self.highest, worker.highest);
        }

        /// One thread's reader and buffers, reused for every tile it draws.
        pub const Worker = struct {
            view: *const Self,
            reader: Source.Reader,
            surface: world.Surface,
            /// For drawing one of the game's own maps.
            mapPainter: ?Source.MapPainter,

            blockCounts: []usize,
            drawn: usize = 0,
            lowest: u16 = std.math.maxInt(u16),
            highest: u16 = 0,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                const gameMap: ?Source.Map = switch (view.map) {
                    .relief => null,
                    .game => |map| map,
                };
                var reader: Source.Reader = try .init(view.source, allocator, gameMap);
                errdefer reader.deinit(allocator);
                var surface: world.Surface = try .init(allocator);
                errdefer surface.deinit(allocator);
                var mapPainter: ?Source.MapPainter = if (gameMap) |map| try .init(view.source, allocator, map) else null;
                errdefer if (mapPainter) |*painter| painter.deinit(allocator);
                const blockCounts = try allocator.alloc(usize, view.blockCounts.len);
                @memset(blockCounts, 0);
                return .{ .view = view, .reader = reader, .surface = surface, .mapPainter = mapPainter, .blockCounts = blockCounts };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                allocator.free(self.blockCounts);
                if (self.mapPainter) |*painter| painter.deinit(allocator);
                self.surface.deinit(allocator);
                self.reader.deinit(allocator);
            }

            /// Reads the tile's block columns and the ring around them, then colours its
            /// pixels. Returns false if it has nothing on it.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                try self.reader.read(tile, &self.surface);
                if (!self.count()) return false;
                switch (self.view.map) {
                    .relief => self.paintRelief(pixels),
                    .game => self.mapPainter.?.draw(&self.reader, tile, &self.surface, &self.view.palette, pixels),
                }
                return true;
            }

            /// Counts the tile's columns that have blocks, and what each shows from above, for
            /// the summary. Returns false if there are none.
            fn count(self: *Worker) bool {
                const surface = &self.surface;
                const side = world.Surface.side;
                var any = false;
                for (0..tiles.size) |py| for (0..tiles.size) |px| {
                    const i = (py + 1) * side + px + 1;
                    if (surface.columnTop(i) == .none) continue;
                    any = true;
                    self.drawn += 1;
                    if (surface.top[i]) |solid| {
                        self.lowest = @min(self.lowest, solid);
                        self.highest = @max(self.highest, solid);
                    }
                    const block = surface.shownBlock(i);
                    if (block >= 0 and block < self.blockCounts.len) self.blockCounts[@intCast(block)] += 1;
                };
                return any;
            }

            /// Colours the tile's pixels from the surface as a relief map.
            fn paintRelief(self: *Worker, pixels: *tiles.Pixels) void {
                const surface = &self.surface;
                const view = self.view;
                const side = world.Surface.side;
                for (0..tiles.size) |py| for (0..tiles.size) |px| {
                    const i = (py + 1) * side + px + 1;
                    const pixel = &pixels[py * tiles.size + px];
                    const here = surface.columnTop(i);
                    const y = here.height() orelse {
                        pixel.* = tiles.transparent;
                        continue;
                    };
                    const west = surface.columnTop(i - 1);
                    const north = surface.columnTop(i - side);
                    const east = surface.columnTop(i + 1);
                    const south = surface.columnTop(i + side);

                    const style = &view.style;
                    const mapType = view.source.mapType(surface.shownBlock(i));
                    if (here == .liquid) {
                        // Where water meets land, its edge, as an old map inks its coastlines.
                        const shore = west == .land or north == .land or east == .land or south == .land;
                        // A liquid the game's reader doesn't place is drawn as a lake.
                        const liquid = if (mapType.isLiquid()) mapType else .lake;
                        pixel.* = if (shore and liquid != .lava)
                            rgb(style.wateredge)
                        else
                            liquidColour(style.colours.get(liquid), if (surface.top[i]) |ground| y - ground else maxDepth);
                        continue;
                    }
                    // Neighbours without blocks count as level ground.
                    const slope = @as(i32, y) * 2 - (west.height() orelse y) - (north.height() orelse y);
                    pixel.* = groundColour(style, style.colours.get(mapType), y, view.heights, slope);
                };
            }
        };
    };
}

/// The five most common blocks seen from above, by name.
fn printSurfaceBlocks(comptime Source: type, source: *const Source, blockCounts: []const usize) void {
    var columnCount: usize = 0;
    for (blockCounts) |n| columnCount += n;
    if (columnCount == 0) return;
    var shown: [5]usize = undefined;
    var count: usize = 0;
    std.debug.print("most common surface blocks:", .{});
    while (count < shown.len) : (count += 1) {
        // The most common block not shown yet.
        var best: ?usize = null;
        for (blockCounts, 0..) |n, id| {
            if (n == 0 or std.mem.indexOfScalar(usize, shown[0..count], id) != null) continue;
            if (best == null or n > blockCounts[best.?]) best = id;
        }
        const id = best orelse break;
        shown[count] = id;
        const percent = blockCounts[id] * 100 / columnCount;
        const separator = if (count == 0) "" else ",";
        if (source.blockName(@intCast(id))) |code| {
            std.debug.print("{s} {s} {}%", .{ separator, code, percent });
        } else {
            std.debug.print("{s} #{} {}%", .{ separator, id, percent });
        }
    }
    std.debug.print("\n", .{});
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

/// A relief style for the tests: sepia ground and dark ink.
const testStyle: Style = .{ .kind = .relief, .colours = .initFill(.{ 0xE4, 0xD2, 0xA0 }), .ink = .{ 0x4A, 0x30, 0x1A }, .wateredge = .{ 0x5C, 0x46, 0x2E } };

test liquidColour {
    const lake = testStyle.colours.get(.lake);
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
    fn of(heights: world.Heights) Heights {
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
    const style = &testStyle;
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
