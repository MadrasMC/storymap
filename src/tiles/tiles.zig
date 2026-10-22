//! The tile pipeline every view shares: draws full-detail tiles on every core, builds the
//! zoomed-out levels above them, and writes each tile to `<output>/<view>/<level>/<x>/<y>.png`
//! (docs/rendering.md#output-tiles-and-levels-of-detail).
//!
//! A view is a type with:
//! - `name`, its folder in the output, e.g. "topdown";
//! - `Worker`, one per thread, with `init(view: *const View, allocator) !Worker`,
//!   `deinit(*Worker, allocator)` and `draw(*Worker, tile: Tile, pixels: *Pixels) !bool`, false
//!   for a tile with nothing on it;
//! - `collect(view: *View, worker: *const Worker)`, adding a finished worker's counts to the
//!   view's.
//!
//! A tile at level n covers 2 × 2 tiles at level n − 1, up to a single tile at the top. Each is
//! built from its four children shrunk to half size, so nothing is read back from disk.
const std = @import("std");
const Io = std.Io;
const stb = @import("stb_image_write");

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

pub const Output = union(enum) {
    folder: Io.Dir,
    /// Encode the PNGs and drop them, so a benchmark doesn't time the disk.
    discard,
};

/// Times are summed over all workers, so they can exceed the render's wall time.
pub const Stats = struct {
    /// Tiles written, at every level; empty tiles aren't.
    tiles: usize = 0,
    levels: usize = 0,
    /// Drawing full-detail tiles (`Worker.draw`).
    draw: Io.Duration = .zero,
    /// Encoding and writing the PNGs, and shrinking tiles for the level above.
    encode: Io.Duration = .zero,
};

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

/// Draws the tiles in `list` and builds every level above them. Appends the tiles written to a
/// folder to `written`, sorted by level, then x, then y.
pub fn render(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *View, list: []const Tile, output: Output, written: *std.ArrayList(Written)) !Stats {
    var pyramid: Pyramid = try .init(allocator, list);
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

    const count = @max(1, @min(cores, items.len));
    const jobs = try allocator.alloc(Job(View), count);
    defer allocator.free(jobs);
    var next: std.atomic.Value(usize) = .init(0);
    var ready: usize = 0;
    defer for (jobs[0..ready]) |*job| job.deinit(allocator);
    for (jobs) |*job| {
        job.* = try .init(view, allocator, io, &pyramid, split, items, halves, drawn, &next, output);
        ready += 1;
    }

    const threads = try allocator.alloc(?std.Thread, count);
    defer allocator.free(threads);
    try runAll(View, jobs, threads, Job(View).run);

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
        try runAll(View, jobs, threads, Job(View).runAbove);
        below = built;
    }

    var stats: Stats = .{ .levels = pyramid.levels.len };
    const start = written.items.len;
    for (jobs) |*job| {
        view.collect(&job.worker);
        try written.appendSlice(allocator, job.written.items);
        stats.tiles += job.stats.tiles;
        stats.draw = .{ .nanoseconds = stats.draw.nanoseconds + job.stats.draw.nanoseconds };
        stats.encode = .{ .nanoseconds = stats.encode.nanoseconds + job.stats.encode.nanoseconds };
    }
    std.mem.sort(Written, written.items[start..], {}, Written.lessThan);
    return stats;
}

fn runAll(comptime View: type, jobs: []Job(View), threads: []?std.Thread, comptime phase: fn (*Job(View)) void) !void {
    for (jobs, threads) |*job, *thread| {
        // If a thread can't be started, that share of the work runs here instead.
        thread.* = std.Thread.spawn(.{}, phase, .{job}) catch null;
        if (thread.* == null) phase(job);
    }
    for (threads) |thread| if (thread) |t| t.join();
    for (jobs) |*job| if (job.err) |err| return err;
}

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

/// The tiles of every level, level 0 first, up to the first level with a single tile.
const Pyramid = struct {
    levels: []std.AutoArrayHashMapUnmanaged(Tile, void),

    fn init(allocator: std.mem.Allocator, list: []const Tile) !Pyramid {
        var levels: std.ArrayList(std.AutoArrayHashMapUnmanaged(Tile, void)) = .empty;
        errdefer {
            for (levels.items) |*level| level.deinit(allocator);
            levels.deinit(allocator);
        }
        try levels.append(allocator, .empty);
        for (list) |tile| try levels.items[0].put(allocator, tile, {});
        while (levels.items[levels.items.len - 1].count() > 1) {
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
};

/// Shrinks `pixels` to half size into `into`, whose rows are `stride` pixels apart. Each pixel
/// averages four, colours weighted by alpha, so transparent pixels make edges partly
/// transparent rather than darker.
fn shrink(pixels: *const Pixels, into: []u32, stride: usize) void {
    for (0..half) |y| for (0..half) |x| {
        var sum: [4]u32 = .{ 0, 0, 0, 0 };
        for ([_]usize{ 0, 1, size, size + 1 }) |offset| {
            const p: [4]u8 = @bitCast(pixels[(y * 2) * size + x * 2 + offset]);
            for (sum[0..3], p[0..3]) |*total, channel| total.* += @as(u32, channel) * p[3];
            sum[3] += p[3];
        }
        const alpha = sum[3];
        into[y * stride + x] = if (alpha == 0) transparent else rgba(
            @intCast((sum[0] + alpha / 2) / alpha),
            @intCast((sum[1] + alpha / 2) / alpha),
            @intCast((sum[2] + alpha / 2) / alpha),
            @intCast((alpha + 2) / 4),
        );
    };
}

/// One thread's view worker and buffers, reused for every subtree it takes.
fn Job(comptime View: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
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
        worker: View.Worker,
        /// One tile's pixels per level of a subtree: level 0's are drawn, the others built.
        pixels: []Pixels,
        png: std.ArrayList(u8) = .empty,
        written: std.ArrayList(Written) = .empty,
        pngFailed: bool = false,
        stats: Stats = .{},
        err: ?anyerror = null,
        above: ?*const Above = null,

        fn init(view: *const View, allocator: std.mem.Allocator, io: Io, pyramid: *const Pyramid, split: usize, items: []const Tile, halves: []u32, drawn: []bool, next: *std.atomic.Value(usize), output: Output) !Self {
            const pixels = try allocator.alloc(Pixels, split + 1);
            errdefer allocator.free(pixels);
            return .{
                .allocator = allocator,
                .io = io,
                .pyramid = pyramid,
                .split = split,
                .items = items,
                .halves = halves,
                .drawn = drawn,
                .next = next,
                .output = output,
                .worker = try .init(view, allocator),
                .pixels = pixels,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.worker.deinit(allocator);
            allocator.free(self.pixels);
            self.png.deinit(allocator);
            self.written.deinit(allocator);
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
                self.stats.draw = .{ .nanoseconds = self.stats.draw.nanoseconds + start.untilNow(self.io, .awake).nanoseconds };
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
            const start: Io.Timestamp = .now(self.io, .awake);
            try self.write(level, tile, pixels);
            shrink(pixels, into, stride);
            self.stats.encode = .{ .nanoseconds = self.stats.encode.nanoseconds + start.untilNow(self.io, .awake).nanoseconds };
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
                const start: Io.Timestamp = .now(self.io, .awake);
                try self.write(task.level, tile, pixels);
                shrink(pixels, task.built.halves[i * half * half ..], half);
                self.stats.encode = .{ .nanoseconds = self.stats.encode.nanoseconds + start.untilNow(self.io, .awake).nanoseconds };
            }
        }

        /// Encodes a tile as PNG and writes it to `<view>/<level>/<x>/<y>.png`.
        fn write(self: *Self, level: usize, tile: Tile, pixels: *const Pixels) !void {
            self.png.clearRetainingCapacity();
            self.pngFailed = false;
            if (stb.stbi_write_png_to_func(appendPng, self, size, size, 4, pixels, size * @sizeOf(u32)) == 0) return error.EncodePngFailed;
            if (self.pngFailed) return error.OutOfMemory;
            self.stats.tiles += 1;

            const folder = switch (self.output) {
                .folder => |folder| folder,
                .discard => return,
            };
            var buffer: [64]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buffer, "{s}/{d}/{d}", .{ View.name, level, tile.x });
            try folder.createDirPath(self.io, dir);
            var pathBuffer: [80]u8 = undefined;
            const path = try std.fmt.bufPrint(&pathBuffer, "{s}/{d}.png", .{ dir, tile.y });
            try folder.writeFile(self.io, .{ .sub_path = path, .data = self.png.items });
            try self.written.append(self.allocator, .{ .level = @intCast(level), .tile = tile });
        }

        fn appendPng(context: ?*anyopaque, data: ?*anyopaque, length: c_int) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const bytes: [*]const u8 = @ptrCast(data.?);
            self.png.appendSlice(self.allocator, bytes[0..@intCast(length)]) catch {
                self.pngFailed = true;
            };
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
    var pyramid: Pyramid = try .init(std.testing.allocator, &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 5 } });
    defer pyramid.deinit(std.testing.allocator);
    try std.testing.expectEqual(4, pyramid.levels.len);
    try std.testing.expectEqual(3, pyramid.levels[0].count());
    try std.testing.expectEqual(2, pyramid.levels[1].count());
    try std.testing.expectEqual(2, pyramid.levels[2].count());
    try std.testing.expectEqual(1, pyramid.levels[3].count());
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
    shrink(pixels, &into, half);
    // Still pure red, half transparent: not darkened towards black.
    try std.testing.expectEqual(rgba(255, 0, 0, 128), into[0]);
    try std.testing.expectEqual(rgba(25, 25, 25, 255), into[1]);
    try std.testing.expectEqual(transparent, into[2]);
}
