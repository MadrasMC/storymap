//! The top-down map: one pixel per block column, coloured by what's on top. It draws Storymap's
//! relief style itself, and the game's own styles through the game's `MapPainter`.
//!
//! A `Source` is a game's save, opened for reading, with:
//! - `tileList: []const tiles.Tile`, the tiles that may have something on them;
//! - `heights() world.Heights`;
//! - `blockCount() usize`, `blockName(id: i32) ?[]const u8` and `mapType(id: i32) world.MapType`;
//! - `MapStyle`, an enum of the game's styles as a theme names them after `game:`, with a
//!   `default` for `game` alone;
//! - `Reader`, one per thread: `init(source: *const Source, allocator, style: ?MapStyle) !Reader`,
//!   which also reads what `style` needs beyond the surface, `deinit(*Reader, allocator)`,
//!   `read(*Reader, tile: tiles.Tile, surface: *world.Surface) !void` and `chunksRead: usize`;
//! - `MapPainter`, one per thread drawing a game style: `init(source: *const Source, allocator,
//!   style: MapStyle) !MapPainter`, `deinit(MapPainter, allocator)` and `paint(*MapPainter,
//!   reader: *const Reader, tile, surface: *const world.Surface, pixels: *tiles.Pixels) void`,
//!   from what the reader just read.
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const tiles = @import("tiles");
const Style = @import("theme").Style;
const console = @import("console");
const Rgb = Style.Rgb;
const relief = @import("relief.zig");

pub const Stats = struct {
    /// Tiles written, at every level.
    tiles: usize = 0,
    levels: usize = 0,
    /// Chunks holding a surface block, in each tile and the ring around it.
    chunksRead: usize = 0,
    /// Block columns drawn at full detail.
    area: usize = 0,
    /// Wall time of drawing and writing every tile; opening the source isn't in it.
    duration: Io.Duration = .zero,
    /// The time each part of the tile pipeline took, summed over all workers.
    pipeline: tiles.Stats = .{},
};

pub const folder = "topdown";
pub const title = "Top-down";
/// One level-0 pixel per block, pixel x and y being block x and z.
pub const projection = "topdown";

pub const Options = struct {
    /// How the map is drawn: a theme's `topdown/style.txt`.
    style: Style,
    /// Where to record stats instead of printing a summary.
    stats: ?*Stats = null,
};

/// Renders `source` into `output` and returns the tiles written, at every level, owned by the
/// caller. A game style the game doesn't have is error.UnknownStyle.
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
            .duration = start.untilNow(io, .awake),
            .pipeline = rendered,
        };
        return list;
    }
    console.log("{} tiles in {} levels, surface y {}..{}", .{ rendered.tiles, rendered.levels, view.lowest, view.highest });
    printSurfaceBlocks(Source, source, view.blockCounts);
    return list;
}

/// What every worker shares, read-only while they draw, and their totals once they're done.
fn View(comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const name = folder;

        source: *const Source,
        heights: relief.Heights,
        style: union(enum) { relief: world.Palette, game: Source.MapStyle },

        chunksRead: usize = 0,
        /// Block columns drawn at full detail.
        drawn: usize = 0,
        /// How many columns show each block ID from above.
        blockCounts: []usize,
        /// The lowest and highest solid surface.
        lowest: u16 = std.math.maxInt(u16),
        highest: u16 = 0,

        fn init(allocator: std.mem.Allocator, source: *const Source, style: Style) !Self {
            const drawn: @FieldType(Self, "style") = switch (style) {
                .relief => |palette| .{ .relief = palette },
                .game => |gameStyle| .{ .game = if (gameStyle) |styleName|
                    std.meta.stringToEnum(Source.MapStyle, styleName) orelse return error.UnknownStyle
                else
                    Source.MapStyle.default },
            };
            const blockCounts = try allocator.alloc(usize, source.blockCount());
            @memset(blockCounts, 0);
            return .{ .source = source, .heights = .of(source.heights()), .style = drawn, .blockCounts = blockCounts };
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
            /// Only for the game's styles.
            mapPainter: ?Source.MapPainter,

            blockCounts: []usize,
            drawn: usize = 0,
            lowest: u16 = std.math.maxInt(u16),
            highest: u16 = 0,

            pub fn init(view: *const Self, allocator: std.mem.Allocator) !Worker {
                const gameStyle: ?Source.MapStyle = switch (view.style) {
                    .relief => null,
                    .game => |style| style,
                };
                var reader: Source.Reader = try .init(view.source, allocator, gameStyle);
                errdefer reader.deinit(allocator);
                var surface: world.Surface = try .init(allocator);
                errdefer surface.deinit(allocator);
                var mapPainter: ?Source.MapPainter = if (gameStyle) |style| try .init(view.source, allocator, style) else null;
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

            /// Returns false if the tile has nothing on it.
            pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
                try self.reader.read(tile, &self.surface);
                if (!self.count()) return false;
                switch (self.view.style) {
                    .relief => |*palette| self.paintRelief(palette, pixels),
                    .game => self.mapPainter.?.paint(&self.reader, tile, &self.surface, pixels),
                }
                return true;
            }

            /// Counts the tile's columns with blocks, and the block each shows from above.
            /// Returns false if there are none.
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

            fn paintRelief(self: *Worker, palette: *const world.Palette, pixels: *tiles.Pixels) void {
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

                    const mapType = view.source.mapType(surface.shownBlock(i));
                    if (here == .liquid) {
                        // An inked coastline where water meets land, as on an old map.
                        const shore = west == .land or north == .land or east == .land or south == .land;
                        // A liquid the game's reader doesn't place is drawn as a lake.
                        const liquid = if (mapType.isLiquid()) mapType else .lake;
                        pixel.* = if (shore and liquid != .lava)
                            relief.rgb(palette.wateredge)
                        else
                            relief.liquidColour(palette.colours.get(liquid), if (surface.top[i]) |ground| y - ground else relief.maxDepth);
                        continue;
                    }
                    // Neighbours without blocks count as level ground.
                    const slope = @as(i32, y) * 2 - (west.height() orelse y) - (north.height() orelse y);
                    pixel.* = relief.groundColour(palette, palette.colours.get(mapType), y, view.heights, slope);
                };
            }
        };
    };
}

/// Prints the five most common blocks seen from above.
fn printSurfaceBlocks(comptime Source: type, source: *const Source, blockCounts: []const usize) void {
    var columnCount: usize = 0;
    for (blockCounts) |n| columnCount += n;
    if (columnCount == 0) return;
    var shown: [5]usize = undefined;
    var count: usize = 0;
    var buffer: [512]u8 = undefined;
    // A line too long for the buffer is cut short.
    var line: std.Io.Writer = .fixed(&buffer);
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
            line.print("{s} {s} {}%", .{ separator, code, percent }) catch break;
        } else {
            line.print("{s} #{} {}%", .{ separator, id, percent }) catch break;
        }
    }
    console.log("most common surface blocks:{s}", .{line.buffered()});
}
