//! The tile pipeline every view shares: draws full-detail tiles on every core, builds the
//! zoomed-out levels above them, and writes each tile to `<output>/<view>/<level>/<x>/<y>.png`,
//! or `.jxl` in JPEG XL, or `.webp` in WebP (docs/rendering.md#output-tiles-and-levels-of-detail).
//!
//! A view is a type with:
//! - `name: []const u8`, a field, its folder in the output, e.g. "topdown";
//! - `Worker`, one per thread, with `init(view: *const View, allocator) !Worker`,
//!   `deinit(*Worker, allocator)` and `draw(*Worker, tile: Tile, pixels: *Pixels) !bool`, false
//!   for a tile with nothing on it;
//! - `collect(view: *View, worker: *const Worker)`, adding a finished worker's counts to the
//!   view's.
//!
//! A tile at level n covers 2 × 2 tiles at level n − 1, up to a single tile at the top, or up to
//! 2 × 2 where tiles either side of 0 never meet (`Pyramid`). Each is built from its four
//! children shrunk to half size, so nothing is read back from disk.
//!
//! Besides or instead of the tiles, it writes images of a view (`Image`), each drawn on its own.
const std = @import("std");
const Io = std.Io;
const png = @import("png");
const jxl = @import("jxl");
const webp = @import("webp");

/// A tile's side in pixels, in every view and level.
pub const size = 512;
/// A tile's pixels, row by row, as `rgba` makes them.
pub const Pixels = [size * size]u32;
const half = size / 2;

/// A tile's place in its level's grid.
pub const Tile = struct {
    x: i32,
    y: i32,

    /// The tile covering this one at the level above. Rounds down, also below 0.
    fn parent(self: Tile) Tile {
        return .{ .x = self.x >> 1, .y = self.y >> 1 };
    }

    /// One of the four tiles this one covers at the level below: 0 north-west, 1 north-east,
    /// 2 south-west, 3 south-east.
    fn child(self: Tile, quarter: usize) Tile {
        return .{ .x = self.x * 2 + @as(i32, @intCast(quarter % 2)), .y = self.y * 2 + @as(i32, @intCast(quarter / 2)) };
    }
};

/// Where tiles go, and what they're encoded as.
pub const Output = struct {
    /// Null to encode the tiles and drop them (`--no-write`), so a benchmark doesn't time the
    /// disk.
    folder: ?Io.Dir,
    format: Format = .png,
    /// For WebP, the level from which tiles are lossy, at quality 90, where blocks are drawn
    /// small enough that blurred edges don't show; null for none.
    lossyFrom: ?u8 = null,
    /// Whether to write the map's tiles.
    map: bool = true,
    /// Images to write besides, or instead of, the tiles.
    images: []const Image = &.{},
};

/// An image of a view's map at one of its levels, written to one PNG file, however large,
/// without ever holding all of it (`writeImage`).
pub const Image = struct {
    /// Its path in `Output.folder`.
    path: []const u8,
    /// Its size in pixels; null for all of the map, which needs a `Scale.level`.
    frame: ?Frame = null,
    /// The level-0 pixel at its centre; null for the map's centre. Only with a `frame`.
    centre: ?[2]i64 = null,
    scale: Scale,

    pub const Frame = struct { width: u32, height: u32 };

    pub const Scale = union(enum) {
        /// One image pixel to one pixel of this level.
        level: u6,
        /// All of the map in the frame, touching it on its tighter side.
        fit,
        /// The frame inside the map's bounding box, touching it on its looser side.
        fill,
    };

    fn needsBounds(self: Image) bool {
        return self.frame == null or self.centre == null or self.scale != .level;
    }
};

pub const Format = enum {
    png,
    /// Lossless JPEG XL (`lib/jxl`).
    jpegxl,
    /// Lossless WebP (`lib/webp`).
    webp,

    /// The tiles' file extension.
    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .png => "png",
            .jpegxl => "jxl",
            .webp => "webp",
        };
    }
};

/// A worker's encoder, for its output's format.
const Encoder = union(Format) {
    png: png.Encoder,
    jpegxl: jxl.Encoder,
    webp: webp.Encoder,

    fn deinit(self: Encoder, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |encoder| encoder.deinit(allocator),
        }
    }
};

/// Times are summed over all workers, so they can exceed the render's wall time.
pub const Stats = struct {
    /// Tiles written, at every level; empty tiles aren't.
    tiles: usize = 0,
    levels: usize = 0,
    /// Drawing full-detail tiles (`Worker.draw`).
    draw: Io.Duration = .zero,
    /// Encoding the tiles: for PNG, filtering their rows, then compressing them; JPEG XL's and
    /// WebP's is all compressing.
    filter: Io.Duration = .zero,
    compress: Io.Duration = .zero,
    /// Creating the tiles' folders and writing their files; nothing without a folder.
    write: Io.Duration = .zero,
    /// Shrinking tiles to half size for the level above.
    shrink: Io.Duration = .zero,

    fn add(self: *Stats, other: Stats) void {
        self.tiles += other.tiles;
        inline for (.{ "draw", "filter", "compress", "write", "shrink" }) |name| {
            @field(self, name).nanoseconds += @field(other, name).nanoseconds;
        }
    }
};

/// Adds the time since `start` to `total`.
fn timeSince(io: Io, total: *Io.Duration, start: Io.Timestamp) void {
    total.nanoseconds += start.untilNow(io, .awake).nanoseconds;
}

pub const Written = struct {
    level: u8,
    tile: Tile,

    fn lessThan(_: void, a: Written, b: Written) bool {
        if (a.level != b.level) return a.level < b.level;
        if (a.tile.x != b.tile.x) return a.tile.x < b.tile.x;
        return a.tile.y < b.tile.y;
    }
};

/// A pixel as the PNG encoder expects it: red, green, blue and alpha bytes in memory order.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return std.mem.nativeToLittle(u32, @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, g) << 8 | r);
}

pub const transparent = rgba(0, 0, 0, 0);

/// Draws the map in `list` as `output` asks: its tiles, then its images, each drawn on its own.
/// Appends the tiles written to a folder to `written`, sorted by level, then x, then y.
pub fn render(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *View, list: []const Tile, output: Output, written: *std.ArrayList(Written)) !Stats {
    var stats: Stats = if (output.map) try renderMap(View, allocator, io, view, list, output, written) else .{};
    if (output.images.len == 0 or list.len == 0) return stats;

    var needsBounds = false;
    for (output.images) |image| needsBounds = needsBounds or image.needsBounds();
    const bounds: Bounds = if (needsBounds) try findBounds(View, allocator, io, view, list, &stats) else .{};
    const placements = try allocator.alloc(Placement, output.images.len);
    defer allocator.free(placements);
    var levels: usize = 1;
    for (placements, output.images) |*placement, image| {
        placement.* = try .of(image, bounds);
        levels = @max(levels, @as(usize, placement.level) + 1);
    }
    var pyramid: Pyramid = try .init(allocator, list, levels);
    defer pyramid.deinit(allocator);
    for (placements, output.images) |placement, image| try writeImage(View, allocator, io, view, &pyramid, image.path, placement, output, &stats);
    return stats;
}

/// Draws the tiles in `list`, builds every level above them and writes them all.
fn renderMap(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *View, list: []const Tile, output: Output, written: *std.ArrayList(Written)) !Stats {
    var pyramid: Pyramid = try .init(allocator, list, 1);
    defer pyramid.deinit(allocator);

    // Workers take whole subtrees: a tile at level `split` and everything under it. `split` is
    // the highest level with enough tiles to keep every core busy; the levels above are built
    // from the subtrees' halves afterwards.
    const cores = std.Thread.getCpuCount() catch 1;
    var split: usize = 0;
    for (pyramid.levels, 0..) |level, n| {
        if (level.count() >= 4 * cores) split = n;
    }
    const items = pyramid.levels[split].keys();
    // Each subtree's tile at the cut level, at half size, and whether it has anything on it.
    const halves = try allocator.alloc(u32, items.len * half * half);
    defer allocator.free(halves);
    const drawn = try allocator.alloc(bool, items.len);
    defer allocator.free(drawn);
    // The levels above are built one at a time from the halves of the level below, so two blocks
    // of halves take turns: the cut level's, and one sized for the level above it. No level has
    // more tiles than the one below, so each block fits every level that uses it.
    const cutBlock: Built = .{ .halves = halves, .drawn = drawn };
    const otherBlock: Built = try .init(allocator, if (split + 1 < pyramid.levels.len) pyramid.levels[split + 1].count() else 0);
    defer otherBlock.deinit(allocator);

    // Every tile the pyramid has, at most, is written; workers take the slots in turn.
    var tileCount: usize = 0;
    for (pyramid.levels) |level| tileCount += level.count();
    try written.ensureUnusedCapacity(allocator, tileCount);
    var slots: Slots = .{ .written = written.unusedCapacitySlice()[0..tileCount] };

    const count = @max(1, @min(cores, items.len));
    const jobs = try allocator.alloc(Job(View), count);
    defer allocator.free(jobs);
    var next: std.atomic.Value(usize) = .init(0);
    var ready: usize = 0;
    defer for (jobs[0..ready]) |*job| job.deinit(allocator);
    for (jobs) |*job| {
        job.* = try .init(view, allocator, io, &pyramid, split, items, halves, drawn, &next, output, &slots);
        ready += 1;
    }

    const threads = try allocator.alloc(?std.Thread, count);
    defer allocator.free(threads);
    try runAll(Job(View), jobs, threads, Job(View).run);

    // Each level overwrites the halves of the level two below, which the level in between has
    // already used.
    var below = cutBlock;
    for (split + 1..pyramid.levels.len, 0..) |level, turn| {
        const tiles = pyramid.levels[level].keys();
        const block = if (turn % 2 == 0) otherBlock else cutBlock;
        const built: Built = .{ .halves = block.halves[0 .. tiles.len * half * half], .drawn = block.drawn[0..tiles.len] };
        var nextAbove: std.atomic.Value(usize) = .init(0);
        const task: Above = .{ .level = level, .tiles = tiles, .belowTiles = &pyramid.levels[level - 1], .below = below, .built = built, .next = &nextAbove };
        for (jobs) |*job| job.above = &task;
        try runAll(Job(View), jobs, threads, Job(View).runAbove);
        below = built;
    }

    var stats: Stats = .{ .levels = pyramid.levels.len };
    const start = written.items.len;
    written.items.len += slots.taken.raw;
    for (jobs) |*job| {
        view.collect(&job.worker);
        stats.add(job.stats);
    }
    std.mem.sort(Written, written.items[start..], {}, Written.lessThan);
    return stats;
}

fn runAll(comptime Worker: type, jobs: []Worker, threads: []?std.Thread, comptime phase: fn (*Worker) void) !void {
    for (jobs, threads) |*job, *thread| {
        // If a thread can't be started, that share of the work runs here instead.
        thread.* = std.Thread.spawn(.{}, phase, .{job}) catch null;
        if (thread.* == null) phase(job);
    }
    for (threads) |thread| if (thread) |t| t.join();
    for (jobs) |*job| if (job.err) |err| return err;
}

/// Writes an image to `path`, or encodes it and drops it without a folder.
fn writeImage(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *View, pyramid: *const Pyramid, path: []const u8, placement: Placement, output: Output, stats: *Stats) !void {
    var encoder: png.RowEncoder = try .init(allocator, placement.width, .level_4);
    defer encoder.deinit(allocator);

    var buffer: [1 << 16]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&buffer);
    const file = if (output.folder) |folder| try folder.createFile(io, path, .{}) else null;
    defer if (file) |opened| opened.close(io);
    var fileWriter = if (file) |opened| opened.writer(io, &buffer) else undefined;
    const out = if (file != null) &fileWriter.interface else &discarding.writer;

    try encoder.begin(out, placement.width, placement.height);
    try drawRows(View, allocator, io, view, pyramid, placement, &encoder, !output.map, stats);
    try encoder.finish();
    try out.flush();
}

/// The level-0 pixels a map covers: from `left` and `top` up to but not including `right` and
/// `bottom`.
const Bounds = struct {
    left: i64 = 0,
    top: i64 = 0,
    right: i64 = 0,
    bottom: i64 = 0,

    fn add(self: Bounds, other: Bounds) Bounds {
        return .{
            .left = @min(self.left, other.left),
            .top = @min(self.top, other.top),
            .right = @max(self.right, other.right),
            .bottom = @max(self.bottom, other.bottom),
        };
    }

    fn ofTile(tile: Tile) Bounds {
        const left = @as(i64, tile.x) * size;
        const top = @as(i64, tile.y) * size;
        return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
    }

    /// The pixels of `tile` that aren't fully transparent; null if there are none.
    fn ofPixels(tile: Tile, pixels: *const Pixels) ?Bounds {
        const tileBounds: Bounds = .ofTile(tile);
        var bounds: ?Bounds = null;
        for (0..size) |y| for (0..size) |x| {
            const channels: [4]u8 = @bitCast(pixels[y * size + x]);
            if (channels[3] == 0) continue;
            const left = tileBounds.left + @as(i64, @intCast(x));
            const top = tileBounds.top + @as(i64, @intCast(y));
            const pixel: Bounds = .{ .left = left, .top = top, .right = left + 1, .bottom = top + 1 };
            bounds = if (bounds) |found| found.add(pixel) else pixel;
        };
        return bounds;
    }
};

test "Bounds.ofPixels" {
    const pixels = try std.testing.allocator.create(Pixels);
    defer std.testing.allocator.destroy(pixels);
    @memset(pixels, rgba(9, 9, 9, 0));
    try std.testing.expectEqual(null, Bounds.ofPixels(.{ .x = 0, .y = 0 }, pixels));
    pixels[3 * size + 5] = rgba(0, 0, 0, 1);
    pixels[7 * size + 2] = rgba(0, 0, 0, 255);
    const expected: Bounds = .{ .left = -510, .top = 515, .right = -506, .bottom = 520 };
    try std.testing.expectEqual(expected, Bounds.ofPixels(.{ .x = -1, .y = 1 }, pixels).?);
}

/// A way in from one side of the map.
const Side = enum {
    top,
    bottom,
    left,
    right,

    /// Tiles with the same key are in one row or column, and lower keys are nearer this side.
    fn key(self: Side, tile: Tile) i32 {
        return switch (self) {
            .top => tile.y,
            .bottom => -tile.y,
            .left => tile.x,
            .right => -tile.x,
        };
    }

    fn isNearer(self: Side, a: Tile, b: Tile) bool {
        return self.key(a) < self.key(b);
    }
};

/// Finds what the map really covers, which only drawing can tell: a view's tile list has tiles
/// that may have something on them. From each side it draws one row or column of tiles after
/// another, until one has something on it, so it draws few of the map's tiles. A map with nothing
/// on it covers all of its tiles.
fn findBounds(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *const View, list: []const Tile, stats: *Stats) !Bounds {
    const order = try allocator.dupe(Tile, list);
    defer allocator.free(order);

    var next: std.atomic.Value(usize) = .init(0);
    var found: std.atomic.Value(bool) = .init(false);
    const cores = std.Thread.getCpuCount() catch 1;
    const jobs = try allocator.alloc(BoundsJob(View), @max(1, @min(cores, list.len)));
    defer allocator.free(jobs);
    var ready: usize = 0;
    defer for (jobs[0..ready]) |*job| job.deinit(allocator);
    for (jobs) |*job| {
        job.* = try .init(view, allocator, io, &next, &found);
        ready += 1;
    }
    const threads = try allocator.alloc(?std.Thread, jobs.len);
    defer allocator.free(threads);

    for (std.enums.values(Side)) |side| {
        std.mem.sort(Tile, order, side, Side.isNearer);
        found.store(false, .monotonic);
        var start: usize = 0;
        while (start < order.len and !found.load(.monotonic)) {
            var end = start + 1;
            while (end < order.len and side.key(order[end]) == side.key(order[start])) end += 1;
            for (jobs) |*job| job.tiles = order[start..end];
            next.store(0, .monotonic);
            try runAll(BoundsJob(View), jobs, threads, BoundsJob(View).run);
            start = end;
        }
    }

    var bounds: ?Bounds = null;
    for (jobs) |*job| {
        stats.add(job.stats);
        const drawn = job.bounds orelse continue;
        bounds = if (bounds) |sofar| sofar.add(drawn) else drawn;
    }
    if (bounds) |covered| return covered;
    var all: Bounds = .ofTile(list[0]);
    for (list) |tile| all = all.add(.ofTile(tile));
    return all;
}

/// One thread's view worker and buffer, finding what tiles have on them.
fn BoundsJob(comptime View: type) type {
    return struct {
        const Self = @This();

        io: Io,
        worker: View.Worker,
        pixels: *Pixels,
        /// The tiles to draw, shared by all workers, and the next to take.
        tiles: []const Tile = &.{},
        next: *std.atomic.Value(usize),
        /// Whether any worker found something in `tiles`.
        found: *std.atomic.Value(bool),
        bounds: ?Bounds = null,
        stats: Stats = .{},
        err: ?anyerror = null,

        fn init(view: *const View, allocator: std.mem.Allocator, io: Io, next: *std.atomic.Value(usize), found: *std.atomic.Value(bool)) !Self {
            const pixels = try allocator.create(Pixels);
            errdefer allocator.destroy(pixels);
            return .{ .io = io, .worker = try .init(view, allocator), .pixels = pixels, .next = next, .found = found };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.worker.deinit(allocator);
            allocator.destroy(self.pixels);
        }

        fn run(self: *Self) void {
            self.runOrFail() catch |err| {
                self.err = err;
            };
        }

        fn runOrFail(self: *Self) !void {
            while (true) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= self.tiles.len) return;
                const start: Io.Timestamp = .now(self.io, .awake);
                const drawn = try self.worker.draw(self.tiles[i], self.pixels);
                timeSince(self.io, &self.stats.draw, start);
                if (!drawn) continue;
                const covered = Bounds.ofPixels(self.tiles[i], self.pixels) orelse continue;
                self.bounds = if (self.bounds) |sofar| sofar.add(covered) else covered;
                self.found.store(true, .monotonic);
            }
        }
    };
}

/// Where an image's pixels fall on the level it's taken from: each is the pixel of that level
/// nearest its middle, so a level with more or fewer pixels than the image is resampled with
/// nearest neighbour.
const Placement = struct {
    level: u6,
    width: u32,
    height: u32,
    /// Where the image's top left corner falls, in the level's pixels.
    left: f64,
    top: f64,
    /// How many of the level's pixels one of the image's is across.
    step: f64,

    /// The level whose pixels are closest to the image's without being fewer, for a scale in
    /// image pixels per level-0 pixel, or level 0 for a scale above 1.
    fn levelOf(scale: f64) u6 {
        if (scale >= 1) return 0;
        return @intFromFloat(@min(63, @floor(-@log2(scale))));
    }

    fn of(image: Image, bounds: Bounds) error{ImageTooLarge}!Placement {
        const frame = image.frame orelse {
            const level = image.scale.level;
            const left = bounds.left >> level;
            const top = bounds.top >> level;
            const right = -(-bounds.right >> level);
            const bottom = -(-bounds.bottom >> level);
            return .{
                .level = level,
                .width = std.math.cast(u32, right - left) orelse return error.ImageTooLarge,
                .height = std.math.cast(u32, bottom - top) orelse return error.ImageTooLarge,
                .left = @floatFromInt(left),
                .top = @floatFromInt(top),
                .step = 1,
            };
        };
        const width: f64 = @floatFromInt(frame.width);
        const height: f64 = @floatFromInt(frame.height);
        const left: f64 = @floatFromInt(bounds.left);
        const top: f64 = @floatFromInt(bounds.top);
        const right: f64 = @floatFromInt(bounds.right);
        const bottom: f64 = @floatFromInt(bounds.bottom);
        const across = width / (right - left);
        const down = height / (bottom - top);
        const scale: f64 = switch (image.scale) {
            .level => |level| std.math.ldexp(@as(f64, 1), -@as(i32, level)),
            .fit => @min(across, down),
            .fill => @max(across, down),
        };
        const level = switch (image.scale) {
            .level => |level| level,
            .fit, .fill => levelOf(scale),
        };
        const pixelsPerLevel = std.math.ldexp(@as(f64, 1), level);
        const centreX: f64 = if (image.centre) |centre| @floatFromInt(centre[0]) else (left + right) / 2;
        const centreY: f64 = if (image.centre) |centre| @floatFromInt(centre[1]) else (top + bottom) / 2;
        const step = 1 / (scale * pixelsPerLevel);
        return .{
            .level = level,
            .width = frame.width,
            .height = frame.height,
            .left = centreX / pixelsPerLevel - width / 2 * step,
            .top = centreY / pixelsPerLevel - height / 2 * step,
            .step = step,
        };
    }

    fn sourceX(self: Placement, x: usize) i64 {
        return @intFromFloat(@floor(self.left + (@as(f64, @floatFromInt(x)) + 0.5) * self.step));
    }

    fn sourceY(self: Placement, y: usize) i64 {
        return @intFromFloat(@floor(self.top + (@as(f64, @floatFromInt(y)) + 0.5) * self.step));
    }
};

test Placement {
    const bounds: Bounds = .{ .left = -512, .top = 1024, .right = 1024, .bottom = 2048 };
    // All of the map, by whole pixels of level 2, past the map's edges where they fall between.
    const whole: Placement = try .of(.{ .path = "", .scale = .{ .level = 2 } }, .{ .left = -5, .top = 8, .right = 5, .bottom = 9 });
    try std.testing.expectEqual(Placement{ .level = 2, .width = 4, .height = 1, .left = -2, .top = 2, .step = 1 }, whole);

    const frame: Image.Frame = .{ .width = 100, .height = 50 };
    // In the middle of the map.
    try std.testing.expectEqual(
        Placement{ .level = 0, .width = 100, .height = 50, .left = 206, .top = 1511, .step = 1 },
        try Placement.of(.{ .path = "", .frame = frame, .scale = .{ .level = 0 } }, bounds),
    );
    // A centre is in level-0 pixels, and level 2's are 4 of them.
    try std.testing.expectEqual(
        Placement{ .level = 2, .width = 100, .height = 50, .left = 200, .top = -25, .step = 1 },
        try Placement.of(.{ .path = "", .frame = frame, .centre = .{ 1000, 0 }, .scale = .{ .level = 2 } }, bounds),
    );
}

test "fit touches the frame on its tighter side and fill on its looser one" {
    const bounds: Bounds = .{ .left = 0, .top = 0, .right = 1000, .bottom = 500 };
    const frame: Image.Frame = .{ .width = 300, .height = 300 };
    // 0.3 image pixels per map pixel, between levels 1 and 2: taken from level 1, every
    // 1000 / 2 / 300 of its pixels.
    const fit: Placement = try .of(.{ .path = "", .frame = frame, .scale = .fit }, bounds);
    try std.testing.expectEqual(1, fit.level);
    try std.testing.expectApproxEqAbs(@as(f64, 500) / 300, fit.step, 1e-9);
    try std.testing.expectEqual(0, fit.sourceX(0));
    try std.testing.expectEqual(499, fit.sourceX(299));
    // 500 map pixels high fills 300 image pixels, and the map runs off left and right.
    const fill: Placement = try .of(.{ .path = "", .frame = frame, .scale = .fill }, bounds);
    try std.testing.expectEqual(0, fill.level);
    try std.testing.expectApproxEqAbs(@as(f64, 500) / 300, fill.step, 1e-9);
    try std.testing.expectEqual(0, fill.sourceY(0));
    try std.testing.expectEqual(499, fill.sourceY(299));
    try std.testing.expectEqual(250, fill.sourceX(0));
    try std.testing.expectEqual(749, fill.sourceX(299));
    // A frame larger than the map draws level 0's pixels larger.
    const large: Placement = try .of(.{ .path = "", .frame = .{ .width = 2000, .height = 1000 }, .scale = .fit }, bounds);
    try std.testing.expectEqual(0, large.level);
    try std.testing.expectEqual(0.5, large.step);
    try std.testing.expectEqual(999, large.sourceX(1999));
}

test "Placement.levelOf" {
    try std.testing.expectEqual(0, Placement.levelOf(3));
    try std.testing.expectEqual(0, Placement.levelOf(1));
    try std.testing.expectEqual(0, Placement.levelOf(0.75));
    try std.testing.expectEqual(1, Placement.levelOf(0.5));
    try std.testing.expectEqual(1, Placement.levelOf(0.3));
    try std.testing.expectEqual(2, Placement.levelOf(0.25));
}

/// Draws the tiles under `placement`, one row of them at a time, top to bottom, and gives each
/// row of pixels to `sink.writeRow`. Workers draw a row of tiles together into one buffer, so
/// memory follows the image's width, not its height. Tiles have no order of their own to be drawn
/// in, as each is drawn from the world alone.
fn drawRows(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *View, pyramid: *const Pyramid, placement: Placement, sink: anytype, collect: bool, stats: *Stats) !void {
    const firstColumn = @divFloor(placement.sourceX(0), size);
    const columns: usize = @intCast(@divFloor(placement.sourceX(placement.width - 1), size) - firstColumn + 1);
    var band: Band = .{
        .tiles = try allocator.alloc(Pixels, columns),
        .firstColumn = @intCast(firstColumn),
        .level = placement.level,
        .steps = Band.stepsFor(columns, placement.level),
    };
    defer allocator.free(band.tiles);
    const row = try allocator.alloc(u32, placement.width);
    defer allocator.free(row);
    // Where each of the image's columns is in the top row of the tiles' pixels.
    const offsets = try allocator.alloc(usize, placement.width);
    defer allocator.free(offsets);
    for (offsets, 0..) |*offset, x| {
        const source = placement.sourceX(x);
        const column: usize = @intCast(@divFloor(source, size) - firstColumn);
        offset.* = column * size * size + @as(usize, @intCast(@mod(source, size)));
    }

    const cores = std.Thread.getCpuCount() catch 1;
    const count = @max(1, @min(cores, band.itemCount()));
    const jobs = try allocator.alloc(ImageJob(View), count);
    defer allocator.free(jobs);
    var ready: usize = 0;
    defer for (jobs[0..ready]) |*job| job.deinit(allocator);
    for (jobs) |*job| {
        job.* = try .init(view, allocator, io, pyramid, &band);
        ready += 1;
    }
    const threads = try allocator.alloc(?std.Thread, count);
    defer allocator.free(threads);

    const drawn: []const u32 = @ptrCast(band.tiles);
    var drawnRow: ?i64 = null;
    for (0..placement.height) |y| {
        const source = placement.sourceY(y);
        const tileRow = @divFloor(source, size);
        if (tileRow != drawnRow) {
            for (band.tiles) |*tile| @memset(tile, transparent);
            for (jobs) |*job| job.row = @intCast(tileRow);
            band.next.store(0, .monotonic);
            try runAll(ImageJob(View), jobs, threads, ImageJob(View).run);
            drawnRow = tileRow;
        }
        const encoding: Io.Timestamp = .now(io, .awake);
        const down: usize = @intCast(@mod(source, size) * size);
        for (row, offsets) |*pixel, offset| pixel.* = drawn[offset + down];
        try sink.writeRow(std.mem.sliceAsBytes(row));
        timeSince(io, &stats.compress, encoding);
    }
    for (jobs) |*job| {
        if (collect) view.collect(&job.worker);
        stats.add(job.stats);
    }
}

/// One row of an image's tiles, as workers draw it. It's shared out in items, tiles `steps`
/// levels below the image's, so an image of few tiles still keeps every core busy.
const Band = struct {
    /// The row's tiles, left to right.
    tiles: []Pixels,
    firstColumn: i32,
    level: usize,
    steps: u4,
    /// The next item to take, shared by all workers.
    next: std.atomic.Value(usize) = .init(0),

    /// `shrink`'s sums fit up to here.
    const maxSteps = 8;

    /// The fewest steps with enough items to keep every core busy.
    fn stepsFor(columns: usize, level: usize) u4 {
        const cores = std.Thread.getCpuCount() catch 1;
        var steps: u4 = 0;
        while (steps < @min(level, maxSteps) and columns << (2 * @as(u6, steps)) < 4 * cores) steps += 1;
        return steps;
    }

    fn itemCount(self: *const Band) usize {
        return self.tiles.len << (2 * @as(u6, self.steps));
    }
};

/// One thread's view worker and buffers, reused for every row of an image's tiles.
fn ImageJob(comptime View: type) type {
    return struct {
        const Self = @This();

        io: Io,
        pyramid: *const Pyramid,
        band: *Band,
        /// The row of tiles being drawn.
        row: i32 = 0,
        worker: View.Worker,
        /// One tile's pixels for each level up to an item's.
        pixels: []Pixels,
        stats: Stats = .{},
        err: ?anyerror = null,

        fn init(view: *const View, allocator: std.mem.Allocator, io: Io, pyramid: *const Pyramid, band: *Band) !Self {
            const pixels = try allocator.alloc(Pixels, band.level - band.steps + 1);
            errdefer allocator.free(pixels);
            return .{ .io = io, .pyramid = pyramid, .band = band, .worker = try .init(view, allocator), .pixels = pixels };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.worker.deinit(allocator);
            allocator.free(self.pixels);
        }

        fn run(self: *Self) void {
            self.runOrFail() catch |err| {
                self.err = err;
            };
        }

        fn runOrFail(self: *Self) !void {
            const band = self.band;
            const span = @as(usize, 1) << band.steps;
            const perRow = band.tiles.len * span;
            const itemLevel = band.level - band.steps;
            while (true) {
                const i = band.next.fetchAdd(1, .monotonic);
                if (i >= band.itemCount()) return;
                const across = i % perRow;
                const down = i / perRow;
                const tile: Tile = .{
                    .x = band.firstColumn * @as(i32, @intCast(span)) + @as(i32, @intCast(across)),
                    .y = self.row * @as(i32, @intCast(span)) + @as(i32, @intCast(down)),
                };
                const into = &band.tiles[across / span];
                if (band.steps == 0) {
                    _ = try self.build(itemLevel, tile, into);
                } else if (try self.build(itemLevel, tile, &self.pixels[itemLevel])) {
                    const side = size / span;
                    const start: Io.Timestamp = .now(self.io, .awake);
                    shrink(&self.pixels[itemLevel], band.steps, into[(down * size + across % span) * side..], size);
                    timeSince(self.io, &self.stats.shrink, start);
                }
            }
        }

        /// Draws or builds a tile into `pixels`. Returns false, leaving them as they were or
        /// transparent, if it has nothing on it.
        fn build(self: *Self, level: usize, tile: Tile, pixels: *Pixels) !bool {
            if (!self.pyramid.levels[level].contains(tile)) return false;
            if (level == 0) {
                const start: Io.Timestamp = .now(self.io, .awake);
                defer timeSince(self.io, &self.stats.draw, start);
                return self.worker.draw(tile, pixels);
            }
            @memset(pixels, transparent);
            const child = &self.pixels[level - 1];
            var any = false;
            for (0..4) |quarter| {
                if (!try self.build(level - 1, tile.child(quarter), child)) continue;
                any = true;
                const corner = (quarter / 2) * half * size + (quarter % 2) * half;
                const start: Io.Timestamp = .now(self.io, .awake);
                shrink(child, 1, pixels[corner..], size);
                timeSince(self.io, &self.stats.shrink, start);
            }
            return any;
        }
    };
}

/// Room for every tile written, shared by all workers.
const Slots = struct {
    written: []Written,
    taken: std.atomic.Value(usize) = .init(0),
};

/// A level's tiles at half size, and whether each has anything on it.
const Built = struct {
    halves: []u32,
    drawn: []bool,

    fn init(allocator: std.mem.Allocator, tiles: usize) !Built {
        const halves = try allocator.alloc(u32, tiles * half * half);
        errdefer allocator.free(halves);
        return .{ .halves = halves, .drawn = try allocator.alloc(bool, tiles) };
    }

    fn deinit(self: Built, allocator: std.mem.Allocator) void {
        allocator.free(self.halves);
        allocator.free(self.drawn);
    }
};

/// One level above the subtrees, built by all workers together.
const Above = struct {
    level: usize,
    tiles: []const Tile,
    /// The level below's tiles, in the order of `below`.
    belowTiles: *const std.AutoArrayHashMapUnmanaged(Tile, void),
    below: Built,
    built: Built,
    next: *std.atomic.Value(usize),
};

/// The tiles of every level, level 0 first, up to the top level (`isTopLevel`).
const Pyramid = struct {
    levels: []std.AutoArrayHashMapUnmanaged(Tile, void),

    /// `minimumLevels` goes on past the top level, for an image more zoomed out than the map.
    fn init(allocator: std.mem.Allocator, list: []const Tile, minimumLevels: usize) !Pyramid {
        var levels: std.ArrayList(std.AutoArrayHashMapUnmanaged(Tile, void)) = .empty;
        errdefer {
            for (levels.items) |*level| level.deinit(allocator);
            levels.deinit(allocator);
        }
        try levels.append(allocator, .empty);
        for (list) |tile| try levels.items[0].put(allocator, tile, {});
        while (levels.items.len < minimumLevels or !isTopLevel(levels.items[levels.items.len - 1].keys())) {
            try levels.append(allocator, .empty);
            const below = &levels.items[levels.items.len - 2];
            const above = &levels.items[levels.items.len - 1];
            for (below.keys()) |tile| try above.put(allocator, tile.parent(), {});
        }
        return .{ .levels = try levels.toOwnedSlice(allocator) };
    }

    fn deinit(self: *Pyramid, allocator: std.mem.Allocator) void {
        for (self.levels) |*level| level.deinit(allocator);
        allocator.free(self.levels);
    }

    /// Whether a level is the top: across and down, its tiles are at one position, or at exactly
    /// -1 and 0, which halving brings no closer. A level with 2 × 2 tiles either side of 0 can
    /// be the top, as tiles -1 and 0 never meet.
    fn isTopLevel(level: []const Tile) bool {
        if (level.len <= 1) return true;
        var low = level[0];
        var high = level[0];
        for (level) |tile| {
            low = .{ .x = @min(low.x, tile.x), .y = @min(low.y, tile.y) };
            high = .{ .x = @max(high.x, tile.x), .y = @max(high.y, tile.y) };
        }
        return isSettled(low.x, high.x) and isSettled(low.y, high.y);
    }

    fn isSettled(low: i32, high: i32) bool {
        return low == high or (low == -1 and high == 0);
    }
};

/// Halves `pixels` `steps` times over into `into`, whose rows are `stride` pixels apart. Each
/// pixel averages those it covers, colours weighted by alpha, so transparent pixels make edges
/// partly transparent rather than darker.
fn shrink(pixels: *const Pixels, steps: u4, into: []u32, stride: usize) void {
    const span = @as(usize, 1) << steps;
    const covered: u32 = @intCast(span * span);
    for (0..size / span) |y| for (0..size / span) |x| {
        var sum: [4]u32 = .{ 0, 0, 0, 0 };
        for (0..span) |below| for (0..span) |beside| {
            const p: [4]u8 = @bitCast(pixels[(y * span + below) * size + x * span + beside]);
            for (sum[0..3], p[0..3]) |*total, channel| total.* += @as(u32, channel) * p[3];
            sum[3] += p[3];
        };
        const alpha = sum[3];
        into[y * stride + x] = if (alpha == 0) transparent else rgba(
            @intCast((sum[0] + alpha / 2) / alpha),
            @intCast((sum[1] + alpha / 2) / alpha),
            @intCast((sum[2] + alpha / 2) / alpha),
            @intCast((alpha + covered / 2) / covered),
        );
    };
}

/// One thread's view worker and buffers, reused for every subtree it takes.
fn Job(comptime View: type) type {
    return struct {
        const Self = @This();

        io: Io,
        pyramid: *const Pyramid,
        split: usize,
        /// The cut level's tiles, one per subtree, and their halves; shared by all workers.
        items: []const Tile,
        halves: []u32,
        drawn: []bool,
        /// The next tile in `items` to take, shared by all workers.
        next: *std.atomic.Value(usize),
        output: Output,
        /// The view's folder in the output.
        name: []const u8,
        worker: View.Worker,
        /// One tile's pixels per level of a subtree: level 0's are drawn, the others built.
        pixels: []Pixels,
        encoder: Encoder,
        slots: *Slots,
        stats: Stats = .{},
        err: ?anyerror = null,
        above: ?*const Above = null,

        fn init(view: *const View, allocator: std.mem.Allocator, io: Io, pyramid: *const Pyramid, split: usize, items: []const Tile, halves: []u32, drawn: []bool, next: *std.atomic.Value(usize), output: Output, slots: *Slots) !Self {
            const pixels = try allocator.alloc(Pixels, split + 1);
            errdefer allocator.free(pixels);
            const encoder: Encoder = switch (output.format) {
                .png => .{ .png = try .init(allocator, size, size, .{}) },
                .jpegxl => .{ .jpegxl = try .init(allocator, size, size, .{}) },
                .webp => .{ .webp = try .init(allocator, size, size, .{}) },
            };
            errdefer encoder.deinit(allocator);
            return .{
                .encoder = encoder,
                .slots = slots,
                .io = io,
                .pyramid = pyramid,
                .split = split,
                .items = items,
                .halves = halves,
                .drawn = drawn,
                .next = next,
                .output = output,
                .name = view.name,
                .worker = try .init(view, allocator),
                .pixels = pixels,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.worker.deinit(allocator);
            allocator.free(self.pixels);
            self.encoder.deinit(allocator);
        }

        fn run(self: *Self) void {
            self.runOrFail() catch |err| {
                self.err = err;
            };
        }

        fn runOrFail(self: *Self) !void {
            while (true) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= self.items.len) return;
                const into = self.halves[i * half * half ..][0 .. half * half];
                self.drawn[i] = try self.build(self.split, self.items[i], into, half);
            }
        }

        /// Draws or builds a tile and every tile under it, writes them, and shrinks this one
        /// into `into`. Returns false, writing nothing, if it has nothing on it.
        fn build(self: *Self, level: usize, tile: Tile, into: []u32, stride: usize) !bool {
            const pixels = &self.pixels[level];
            if (level == 0) {
                const start: Io.Timestamp = .now(self.io, .awake);
                const drawn = try self.worker.draw(tile, pixels);
                timeSince(self.io, &self.stats.draw, start);
                if (!drawn) return false;
            } else {
                @memset(pixels, transparent);
                var any = false;
                for (0..4) |quarter| {
                    const child = tile.child(quarter);
                    if (!self.pyramid.levels[level - 1].contains(child)) continue;
                    const corner = (quarter / 2) * half * size + (quarter % 2) * half;
                    if (try self.build(level - 1, child, pixels[corner..], size)) any = true;
                }
                if (!any) return false;
            }
            try self.write(level, tile, pixels);
            const start: Io.Timestamp = .now(self.io, .awake);
            shrink(pixels, 1, into, stride);
            timeSince(self.io, &self.stats.shrink, start);
            return true;
        }

        fn runAbove(self: *Self) void {
            self.runAboveOrFail() catch |err| {
                self.err = err;
            };
        }

        /// Builds tiles of `above`'s level until none are left, each from the halves of the
        /// four below.
        fn runAboveOrFail(self: *Self) !void {
            const task = self.above.?;
            const pixels = &self.pixels[0];
            while (true) {
                const i = task.next.fetchAdd(1, .monotonic);
                if (i >= task.tiles.len) return;
                const tile = task.tiles[i];
                @memset(pixels, transparent);
                var any = false;
                for (0..4) |quarter| {
                    const below = task.belowTiles.getIndex(tile.child(quarter)) orelse continue;
                    if (!task.below.drawn[below]) continue;
                    any = true;
                    const corner = (quarter / 2) * half * size + (quarter % 2) * half;
                    for (0..half) |row| {
                        @memcpy(pixels[corner + row * size ..][0..half], task.below.halves[(below * half + row) * half ..][0..half]);
                    }
                }
                task.built.drawn[i] = any;
                if (!any) continue;
                try self.write(task.level, tile, pixels);
                const start: Io.Timestamp = .now(self.io, .awake);
                shrink(pixels, 1, task.built.halves[i * half * half ..], half);
                timeSince(self.io, &self.stats.shrink, start);
            }
        }

        /// Encodes a tile and writes it to `<view>/<level>/<x>/<y>.png`, or the format's
        /// extension.
        fn write(self: *Self, level: usize, tile: Tile, pixels: *const Pixels) !void {
            const bytes = std.mem.sliceAsBytes(pixels);
            const data = switch (self.encoder) {
                .png => |*encoder| png: {
                    const filtering: Io.Timestamp = .now(self.io, .awake);
                    encoder.filter(bytes, size, size);
                    timeSince(self.io, &self.stats.filter, filtering);
                    const compressing: Io.Timestamp = .now(self.io, .awake);
                    defer timeSince(self.io, &self.stats.compress, compressing);
                    break :png try encoder.compress();
                },
                .jpegxl => |*encoder| jpegxl: {
                    const compressing: Io.Timestamp = .now(self.io, .awake);
                    defer timeSince(self.io, &self.stats.compress, compressing);
                    break :jpegxl try encoder.encode(bytes, size, size);
                },
                .webp => |*encoder| webp: {
                    const compressing: Io.Timestamp = .now(self.io, .awake);
                    defer timeSince(self.io, &self.stats.compress, compressing);
                    const lossy = if (self.output.lossyFrom) |from| level >= from else false;
                    break :webp try if (lossy) encoder.encodeLossy(bytes, size, size, 90) else encoder.encode(bytes, size, size);
                },
            };
            self.stats.tiles += 1;

            const folder = self.output.folder orelse return;
            const writing: Io.Timestamp = .now(self.io, .awake);
            defer timeSince(self.io, &self.stats.write, writing);
            var buffer: [64]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buffer, "{s}/{d}/{d}", .{ self.name, level, tile.x });
            try folder.createDirPath(self.io, dir);
            var pathBuffer: [80]u8 = undefined;
            const path = try std.fmt.bufPrint(&pathBuffer, "{s}/{d}.{s}", .{ dir, tile.y, self.output.format.extension() });
            try folder.writeFile(self.io, .{ .sub_path = path, .data = data });
            self.slots.written[self.slots.taken.fetchAdd(1, .monotonic)] = .{ .level = @intCast(level), .tile = tile };
        }
    };
}

test rgba {
    const pixel = rgba(0x11, 0x22, 0x33, 0x44);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, std.mem.asBytes(&pixel));
}

test "Tile.parent rounds down, also below 0" {
    try std.testing.expectEqual(Tile{ .x = 2, .y = 0 }, (Tile{ .x = 5, .y = 1 }).parent());
    try std.testing.expectEqual(Tile{ .x = -1, .y = -2 }, (Tile{ .x = -1, .y = -3 }).parent());
    for (0..4) |quarter| {
        const tile: Tile = .{ .x = -3, .y = 7 };
        try std.testing.expectEqual(tile, tile.child(quarter).parent());
    }
}

test Pyramid {
    // Two tiles side by side and one far away: they meet in one tile three levels up.
    var pyramid: Pyramid = try .init(std.testing.allocator, &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 5 } }, 1);
    defer pyramid.deinit(std.testing.allocator);
    try std.testing.expectEqual(4, pyramid.levels.len);
    try std.testing.expectEqual(3, pyramid.levels[0].count());
    try std.testing.expectEqual(2, pyramid.levels[1].count());
    try std.testing.expectEqual(2, pyramid.levels[2].count());
    try std.testing.expectEqual(1, pyramid.levels[3].count());
}

test "a pyramid goes on past its top for the levels asked for" {
    var pyramid: Pyramid = try .init(std.testing.allocator, &.{.{ .x = 3, .y = 0 }}, 4);
    defer pyramid.deinit(std.testing.allocator);
    try std.testing.expectEqual(4, pyramid.levels.len);
    try std.testing.expect(pyramid.levels[3].contains(.{ .x = 0, .y = 0 }));
}

test "a pyramid over tiles either side of 0 ends where they come no closer" {
    // Across, -3 to 2 merge to -1 and 0 two levels up, and go no further.
    var row: Pyramid = try .init(std.testing.allocator, &.{ .{ .x = -3, .y = 5 }, .{ .x = -2, .y = 5 }, .{ .x = 1, .y = 5 }, .{ .x = 2, .y = 5 } }, 1);
    defer row.deinit(std.testing.allocator);
    try std.testing.expectEqual(3, row.levels.len);
    try std.testing.expectEqual(2, row.levels[2].count());
    // Down, 4 and 7 still come together two levels up, so the levels go on until they have.
    var apart: Pyramid = try .init(std.testing.allocator, &.{ .{ .x = -1, .y = 4 }, .{ .x = 0, .y = 7 } }, 1);
    defer apart.deinit(std.testing.allocator);
    try std.testing.expectEqual(3, apart.levels.len);
    try std.testing.expectEqual(2, apart.levels[2].count());
}

test "Pyramid.isTopLevel" {
    try std.testing.expect(Pyramid.isTopLevel(&.{}));
    try std.testing.expect(Pyramid.isTopLevel(&.{.{ .x = 3, .y = 3 }}));
    try std.testing.expect(!Pyramid.isTopLevel(&.{ .{ .x = 1, .y = 3 }, .{ .x = 2, .y = 3 } }));
    try std.testing.expect(Pyramid.isTopLevel(&.{ .{ .x = -1, .y = -1 }, .{ .x = 0, .y = -1 }, .{ .x = -1, .y = 0 }, .{ .x = 0, .y = 0 } }));
    try std.testing.expect(!Pyramid.isTopLevel(&.{ .{ .x = -2, .y = 0 }, .{ .x = 0, .y = 0 } }));
    // Tiles that never meet, but still come closer down the screen.
    try std.testing.expect(!Pyramid.isTopLevel(&.{ .{ .x = -1, .y = 4 }, .{ .x = 0, .y = 7 } }));
}

test shrink {
    const pixels = try std.testing.allocator.create(Pixels);
    defer std.testing.allocator.destroy(pixels);
    @memset(pixels, transparent);
    // Top-left 2 × 2: two opaque reds and two transparent pixels.
    pixels[0] = rgba(255, 0, 0, 255);
    pixels[1] = rgba(255, 0, 0, 255);
    // The next 2 × 2: four opaque greys.
    pixels[2] = rgba(10, 10, 10, 255);
    pixels[3] = rgba(20, 20, 20, 255);
    pixels[size + 2] = rgba(30, 30, 30, 255);
    pixels[size + 3] = rgba(40, 40, 40, 255);
    var into: [half * half]u32 = undefined;
    shrink(pixels, 1, &into, half);
    // Still pure red, half transparent: not darkened towards black.
    try std.testing.expectEqual(rgba(255, 0, 0, 128), into[0]);
    try std.testing.expectEqual(rgba(25, 25, 25, 255), into[1]);
    try std.testing.expectEqual(transparent, into[2]);

    // Two steps: the first 4 × 4 is those two reds, those greys, and transparent otherwise.
    var quarter: [128 * 128]u32 = undefined;
    shrink(pixels, 2, &quarter, 128);
    try std.testing.expectEqual(rgba(102, 17, 17, 96), quarter[0]);
    try std.testing.expectEqual(transparent, quarter[1]);
}

/// A view whose level-0 tiles are each one colour, from where they are.
const SolidView = struct {
    name: []const u8 = "solid",
    drawnTiles: usize = 0,

    fn colour(tile: Tile) u32 {
        return rgba(@intCast(tile.x + 10), @intCast(tile.y + 10), 0, 255);
    }

    pub fn collect(self: *SolidView, worker: *const Worker) void {
        self.drawnTiles += worker.drawnTiles;
    }

    pub const Worker = struct {
        drawnTiles: usize = 0,

        pub fn init(_: *const SolidView, _: std.mem.Allocator) !Worker {
            return .{};
        }

        pub fn deinit(_: *Worker, _: std.mem.Allocator) void {}

        pub fn draw(self: *Worker, tile: Tile, pixels: *Pixels) !bool {
            self.drawnTiles += 1;
            @memset(pixels, colour(tile));
            return true;
        }
    };
};

/// Keeps the rows it's given, in order.
const RowSink = struct {
    pixels: []u32,
    width: usize,
    rows: usize = 0,

    fn writeRow(self: *RowSink, row: []const u8) !void {
        @memcpy(std.mem.sliceAsBytes(self.pixels[self.rows * self.width..][0..self.width]), row);
        self.rows += 1;
    }
};

fn expectRows(list: []const Tile, placement: Placement, expected: fn (x: usize, y: usize) u32, drawnTiles: usize) !void {
    const allocator = std.testing.allocator;
    var pyramid: Pyramid = try .init(allocator, list, @as(usize, placement.level) + 1);
    defer pyramid.deinit(allocator);
    const pixels = try allocator.alloc(u32, @as(usize, placement.width) * placement.height);
    defer allocator.free(pixels);
    var view: SolidView = .{};
    var sink: RowSink = .{ .pixels = pixels, .width = placement.width };
    var stats: Stats = .{};
    try drawRows(SolidView, allocator, std.testing.io, &view, &pyramid, placement, &sink, true, &stats);
    try std.testing.expectEqual(placement.height, sink.rows);
    try std.testing.expectEqual(drawnTiles, view.drawnTiles);
    for (0..placement.height) |y| for (0..placement.width) |x| {
        try std.testing.expectEqual(expected(x, y), pixels[y * placement.width + x]);
    };
}

test "an image crosses tiles, and is transparent where the map has none" {
    const expected = struct {
        // The frame starts 10 pixels into tile -1, 0 across, and 20 pixels above tile 0, 0.
        fn at(x: usize, y: usize) u32 {
            if (y < 20) return transparent;
            if (x < 10) return SolidView.colour(.{ .x = -1, .y = 0 });
            if (x < 10 + size) return SolidView.colour(.{ .x = 0, .y = 0 });
            return transparent;
        }
    }.at;
    try expectRows(
        &.{ .{ .x = -1, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 } },
        .{ .level = 0, .left = -10, .top = -20, .width = size + 30, .height = size + 21 - 1, .step = 1 },
        expected,
        2,
    );
}

test "an image is resampled from its level with nearest neighbour" {
    const expected = struct {
        // Each of the level's pixels is 2 of the image's, so tile 1 starts at x 2 × 2 = 4.
        fn at(x: usize, _: usize) u32 {
            return SolidView.colour(.{ .x = if (x < 4) 0 else 1, .y = 0 });
        }
    }.at;
    const left: f64 = size - 2;
    try expectRows(
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
        .{ .level = 0, .left = left, .top = 0, .width = 8, .height = 6, .step = 0.5 },
        expected,
        2,
    );
}

/// A view with a little in tile 0, 0 and in tile 1, 2, and nothing on its other tiles.
const SparseView = struct {
    name: []const u8 = "sparse",

    pub fn collect(_: *SparseView, _: *const Worker) void {}

    pub const Worker = struct {
        pub fn init(_: *const SparseView, _: std.mem.Allocator) !Worker {
            return .{};
        }

        pub fn deinit(_: *Worker, _: std.mem.Allocator) void {}

        pub fn draw(_: *Worker, tile: Tile, pixels: *Pixels) !bool {
            @memset(pixels, transparent);
            if (tile.x == 0 and tile.y == 0) {
                pixels[300 * size + 200] = rgba(1, 1, 1, 255);
                return true;
            }
            if (tile.x == 1 and tile.y == 2) {
                pixels[40 * size + 60] = rgba(1, 1, 1, 255);
                return true;
            }
            return false;
        }
    };
};

test "findBounds finds what a map's tiles really have on them" {
    var list: [12]Tile = undefined;
    for (&list, 0..) |*tile, i| tile.* = .{ .x = @intCast(i % 3), .y = @as(i32, @intCast(i / 3)) - 1 };
    var view: SparseView = .{};
    var stats: Stats = .{};
    const bounds = try findBounds(SparseView, std.testing.allocator, std.testing.io, &view, &list, &stats);
    try std.testing.expectEqual(Bounds{ .left = 200, .top = 300, .right = size + 61, .bottom = 2 * size + 41 }, bounds);
}

test "a map with nothing on it covers all of its tiles" {
    const list: []const Tile = &.{ .{ .x = 4, .y = 4 }, .{ .x = 5, .y = 6 } };
    var view: SparseView = .{};
    var stats: Stats = .{};
    const bounds = try findBounds(SparseView, std.testing.allocator, std.testing.io, &view, list, &stats);
    try std.testing.expectEqual(Bounds{ .left = 4 * size, .top = 4 * size, .right = 6 * size, .bottom = 7 * size }, bounds);
}

test "an image at level 2 averages the tiles under it" {
    const expected = struct {
        // Each level-0 tile is 128 pixels wide at level 2.
        fn at(x: usize, y: usize) u32 {
            return SolidView.colour(.{ .x = @intCast(x / 128), .y = @intCast(y / 128) });
        }
    }.at;
    var list: [16]Tile = undefined;
    for (&list, 0..) |*tile, i| tile.* = .{ .x = @intCast(i % 4), .y = @intCast(i / 4) };
    try expectRows(&list, .{ .level = 2, .left = 0, .top = 0, .width = size, .height = size, .step = 1 }, expected, 16);
}
