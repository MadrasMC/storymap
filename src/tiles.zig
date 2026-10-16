//! The tile pipeline every view shares: workers on every core draw tiles one at a time, and
//! each tile becomes a PNG at `<output>/<view>/<level>/<x>/<y>.png`. A view only draws tiles;
//! docs/rendering.md#output-tiles-and-levels-of-detail has the plan.
//!
//! A view is a type with:
//! - `name`, its folder in the output, e.g. "topdown";
//! - `Worker`, one per thread, with `init(view: *const View, allocator) !Worker`,
//!   `deinit(*Worker, allocator)` and `draw(*Worker, tile: Tile, pixels: *Pixels) !bool`, which
//!   returns false for a tile with nothing on it;
//! - `collect(view: *View, worker: *const Worker)`, which adds a finished worker's counts to the
//!   view's.
const std = @import("std");
const Io = std.Io;
const stb = @import("stb_image_write");

/// Every tile is this many pixels square, in every view and level.
pub const size = 512;
/// A tile's pixels, row by row, as `rgba` makes them.
pub const Pixels = [size * size]u32;

/// A tile's place in its level's grid of tiles.
pub const Tile = struct { x: i32, y: i32 };

pub const Output = union(enum) {
    folder: Io.Dir,
    /// Encode the PNGs and drop them, so a benchmark doesn't time the disk.
    discard,
};

/// What rendering the tiles took. Times are added up over all workers, so they can exceed
/// the time the render took.
pub const Stats = struct {
    /// Tiles written; tiles with nothing on them aren't.
    tiles: usize = 0,
    /// Drawing tiles: reading the save and colouring the pixels.
    draw: Io.Duration = .zero,
    /// Encoding and writing the PNGs.
    encode: Io.Duration = .zero,
};

/// A pixel as the PNG encoder expects it: red, green, blue and alpha bytes in memory order.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return std.mem.nativeToLittle(u32, @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, g) << 8 | r);
}

/// Where nothing is drawn.
pub const transparent = rgba(0, 0, 0, 0);

/// Draws and writes the full-detail tiles (level 0) in `list` on every core.
pub fn render(comptime View: type, allocator: std.mem.Allocator, io: Io, view: *View, list: []const Tile, output: Output) !Stats {
    const count = @max(1, @min(std.Thread.getCpuCount() catch 1, list.len));
    const jobs = try allocator.alloc(Job(View), count);
    defer allocator.free(jobs);
    var next: std.atomic.Value(usize) = .init(0);

    var ready: usize = 0;
    defer for (jobs[0..ready]) |*job| job.deinit(allocator);
    for (jobs) |*job| {
        job.* = try .init(view, allocator, io, list, &next, output);
        ready += 1;
    }

    const threads = try allocator.alloc(?std.Thread, count);
    defer allocator.free(threads);
    for (jobs, threads) |*job, *thread| {
        // If a thread can't be started, that share of the work runs here instead.
        thread.* = std.Thread.spawn(.{}, Job(View).run, .{job}) catch null;
        if (thread.* == null) job.run();
    }
    for (threads) |thread| if (thread) |t| t.join();

    var stats: Stats = .{};
    for (jobs) |*job| {
        if (job.err) |err| return err;
        view.collect(&job.worker);
        stats.tiles += job.stats.tiles;
        stats.draw = .{ .nanoseconds = stats.draw.nanoseconds + job.stats.draw.nanoseconds };
        stats.encode = .{ .nanoseconds = stats.encode.nanoseconds + job.stats.encode.nanoseconds };
    }
    return stats;
}

/// One worker: its view's worker state, a tile's pixels and its encoded PNG, all reused for
/// every tile it takes.
fn Job(comptime View: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: Io,
        list: []const Tile,
        /// The next tile in `list` to take, shared by all workers.
        next: *std.atomic.Value(usize),
        output: Output,
        worker: View.Worker,
        pixels: *Pixels,
        png: std.ArrayList(u8) = .empty,
        pngFailed: bool = false,
        stats: Stats = .{},
        err: ?anyerror = null,

        fn init(view: *const View, allocator: std.mem.Allocator, io: Io, list: []const Tile, next: *std.atomic.Value(usize), output: Output) !Self {
            const pixels = try allocator.create(Pixels);
            errdefer allocator.destroy(pixels);
            return .{
                .allocator = allocator,
                .io = io,
                .list = list,
                .next = next,
                .output = output,
                .worker = try .init(view, allocator),
                .pixels = pixels,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.worker.deinit(allocator);
            allocator.destroy(self.pixels);
            self.png.deinit(allocator);
        }

        fn run(self: *Self) void {
            self.runOrFail() catch |err| {
                self.err = err;
            };
        }

        fn runOrFail(self: *Self) !void {
            while (true) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= self.list.len) return;
                const tile = self.list[i];

                const start: Io.Timestamp = .now(self.io, .awake);
                const drawn = try self.worker.draw(tile, self.pixels);
                const drew: Io.Timestamp = .now(self.io, .awake);
                self.stats.draw = .{ .nanoseconds = self.stats.draw.nanoseconds + start.durationTo(drew).nanoseconds };
                if (!drawn) continue;

                try self.encode();
                try self.write(tile);
                self.stats.encode = .{ .nanoseconds = self.stats.encode.nanoseconds + drew.untilNow(self.io, .awake).nanoseconds };
                self.stats.tiles += 1;
            }
        }

        fn encode(self: *Self) !void {
            self.png.clearRetainingCapacity();
            self.pngFailed = false;
            const written = stb.stbi_write_png_to_func(appendPng, self, size, size, 4, self.pixels, size * @sizeOf(u32));
            if (written == 0) return error.EncodePngFailed;
            if (self.pngFailed) return error.OutOfMemory;
        }

        fn appendPng(context: ?*anyopaque, data: ?*anyopaque, length: c_int) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const bytes: [*]const u8 = @ptrCast(data.?);
            self.png.appendSlice(self.allocator, bytes[0..@intCast(length)]) catch {
                self.pngFailed = true;
            };
        }

        fn write(self: *Self, tile: Tile) !void {
            const folder = switch (self.output) {
                .folder => |folder| folder,
                .discard => return,
            };
            // Only level 0 so far.
            var buffer: [64]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buffer, "{s}/0/{d}", .{ View.name, tile.x });
            try folder.createDirPath(self.io, dir);
            var pathBuffer: [80]u8 = undefined;
            const path = try std.fmt.bufPrint(&pathBuffer, "{s}/{d}.png", .{ dir, tile.y });
            try folder.writeFile(self.io, .{ .sub_path = path, .data = self.png.items });
        }
    };
}

test rgba {
    const pixel = rgba(0x11, 0x22, 0x33, 0x44);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, std.mem.asBytes(&pixel));
}
