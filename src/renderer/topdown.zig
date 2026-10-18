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

            surface: []usize,
            lowest: u16 = std.math.maxInt(u16),
            highest: u16 = 0,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                var reader: Source.Reader = try .init(view.source, allocator);
                errdefer reader.deinit(allocator);
                var area: columns.Area = try .init(allocator);
                errdefer area.deinit(allocator);
                const surface = try allocator.alloc(usize, view.surface.len);
                @memset(surface, 0);
                return .{ .view = view, .reader = reader, .area = area, .surface = surface };
            }

            pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
                allocator.free(self.surface);
                self.area.deinit(allocator);
                self.reader.deinit(allocator);
            }

            /// Reads the tile's block columns and the ring around them, then colours its
            /// pixels. Returns false if it has nothing on it.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                try self.reader.read(tile, &self.area);
                return self.paint(pixels);
            }

            /// Colours the tile's pixels from the area, and counts what it shows. Returns false
            /// if nothing is drawn.
            fn paint(self: *Worker, pixels: *tiles.Pixels) bool {
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

                    if (area.top[i]) |solid| {
                        self.lowest = @min(self.lowest, solid);
                        self.highest = @max(self.highest, solid);
                    }
                    const block = if (here == .liquid) area.liquidBlock[i] else area.topBlock[i];
                    if (block >= 0 and block < self.surface.len) self.surface[@intCast(block)] += 1;

                    const style = &view.style;
                    const mapType = view.source.mapType(block);
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
        };
    };
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
