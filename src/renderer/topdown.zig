//! The top-down map: one pixel per block column, shaded by the height of its top block.
const std = @import("std");
const Io = std.Io;
const DB = @import("../sqlite.zig");
const Chunk = @import("../Chunk.zig");
const Compression = @import("../Compression.zig");
const GameData = @import("../GameData.zig");
const stb = @import("stb_image_write");

pub const Output = union(enum) {
    file: [:0]const u8,
    /// Encode the PNG and drop it, so a benchmark doesn't time the disk.
    discard,
};

/// What a render covered and how long each stage took.
pub const Stats = struct {
    chunks: usize = 0,
    width: usize = 0,
    height: usize = 0,
    /// Opening the save and reading its extent and block list.
    open: Io.Duration = .zero,
    /// Decoding every chunk and finding each column's top block.
    scan: Io.Duration = .zero,
    /// Shading the pixels and encoding the PNG.
    png: Io.Duration = .zero,
};

/// Renders a top-down heightmap of the save. With `stats`, records the stages' times
/// instead of printing a summary of the map.
pub fn render(allocator: std.mem.Allocator, io: Io, dbPath: []const u8, output: Output, stats: ?*Stats) !void {
    const start: Io.Timestamp = .now(io, .awake);

    // Never write next to the save: it may be in the game's own Saves folder.
    const db = DB.initImmutable(allocator, dbPath) catch |err| {
        std.debug.print("storymap: can't open {s} ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer db.deinit();

    // The image covers every chunk in the save. Chunk x is the low 27 bits of
    // `position` and z the next 27 (see Chunk.Position).
    const bounds = db.prepare(
        \\SELECT MIN(position & 134217727), MAX(position & 134217727),
        \\       MIN((position >> 27) & 134217727), MAX((position >> 27) & 134217727)
        \\FROM chunk;
    ) catch |err| {
        // SQLite opens any file lazily, so this first query is where a wrong file shows up.
        std.debug.print("storymap: {s} isn't a Vintage Story save ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer bounds.finalize();
    if (!bounds.step()) return error.NoChunks;

    // Which block code each numeric block ID stands for, in this save.
    const gameData = GameData.read(allocator, db) catch |err| {
        std.debug.print("storymap: can't read the block list in {s} ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer gameData.deinit();
    const min_x: usize = @intCast(bounds.column(u64, 0));
    const max_x: usize = @intCast(bounds.column(u64, 1));
    const min_z: usize = @intCast(bounds.column(u64, 2));
    const max_z: usize = @intCast(bounds.column(u64, 3));

    // One pixel per block column; x goes right (east), z goes down (south).
    const width = (max_x - min_x + 1) * 32;
    const height = (max_z - min_z + 1) * 32;
    const opened: Io.Timestamp = .now(io, .awake);

    // Height of the highest non-air block in each column, or null if there is none.
    const top = try allocator.alloc(?u16, width * height);
    defer allocator.free(top);
    @memset(top, null);
    // The block ID at that height.
    const topBlock = try allocator.alloc(i32, width * height);
    defer allocator.free(topBlock);
    @memset(topBlock, 0);
    // The same for liquids, which the save keeps in a layer of their own.
    const liquidTop = try allocator.alloc(?u16, width * height);
    defer allocator.free(liquidTop);
    @memset(liquidTop, null);
    const liquidBlock = try allocator.alloc(i32, width * height);
    defer allocator.free(liquidBlock);
    @memset(liquidBlock, 0);

    const chunks = try scanChunks(allocator, dbPath, .{
        .minX = min_x,
        .minZ = min_z,
        .width = width,
        .top = top,
        .topBlock = topBlock,
        .liquidTop = liquidTop,
        .liquidBlock = liquidBlock,
    });
    const scanned: Io.Timestamp = .now(io, .awake);

    var lowest: u16 = std.math.maxInt(u16);
    var highest: u16 = 0;
    for (top) |column| if (column) |y| {
        lowest = @min(lowest, y);
        highest = @max(highest, y);
    };

    if (stats == null) {
        std.debug.print("{}x{} blocks, surface y {}..{}\n", .{ width, height, lowest, highest });
        try printSurfaceBlocks(allocator, gameData, top, topBlock);
    }
    const summarised: Io.Timestamp = .now(io, .awake);

    const heights: Heights = .of(gameData);
    const kinds = try liquidKinds(allocator, gameData);
    defer allocator.free(kinds);

    const pixels = try allocator.alloc(u32, top.len);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, i| {
        const here = Surface.of(top[i], liquidTop[i]);
        const y = here.height() orelse {
            pixel.* = paper;
            continue;
        };
        const west: Surface = if (i % width > 0) .of(top[i - 1], liquidTop[i - 1]) else .none;
        const north: Surface = if (i >= width) .of(top[i - width], liquidTop[i - width]) else .none;
        const east: Surface = if (i % width < width - 1) .of(top[i + 1], liquidTop[i + 1]) else .none;
        const south: Surface = if (i + width < top.len) .of(top[i + width], liquidTop[i + width]) else .none;

        if (here == .liquid) {
            // A coastline in ink where water meets land, as on an old map.
            const shore = west == .land or north == .land or east == .land or south == .land;
            const kind = if (liquidBlock[i] >= 0 and liquidBlock[i] < kinds.len) kinds[@intCast(liquidBlock[i])] else .water;
            pixel.* = if (shore and kind != .lava) ink else liquidColour(kind, if (top[i]) |ground| y - ground else maxDepth);
            continue;
        }
        // Neighbours without blocks count as level ground.
        const slope = @as(i32, y) * 2 - (west.height() orelse y) - (north.height() orelse y);
        pixel.* = colour(y, heights, slope);
    }

    const stride: c_int = @intCast(width * @sizeOf(u32));
    const written = switch (output) {
        .file => |path| stb.stbi_write_png(path, @intCast(width), @intCast(height), 4, pixels.ptr, stride),
        .discard => stb.stbi_write_png_to_func(discardPng, null, @intCast(width), @intCast(height), 4, pixels.ptr, stride),
    };
    if (written == 0) return error.WritePngFailed;

    if (stats) |out| out.* = .{
        .chunks = chunks,
        .width = width,
        .height = height,
        .open = start.durationTo(opened),
        .scan = opened.durationTo(scanned),
        .png = summarised.untilNow(io, .awake),
    };
}

/// Columns without blocks, as blank paper.
const paper = rgb(0xEF, 0xE4, 0xC6);
/// Coastlines.
const ink = rgb(0x5C, 0x46, 0x2E);

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

/// The liquids the map tells apart. Seas are saltwater; lakes, rivers and hot springs are
/// the other kinds of water (docs/rendering.md#how-the-game-draws-its-own-world-map).
const Liquid = enum { water, saltwater, lava };

/// The kind of liquid each block ID stands for, by its block code. Anything that isn't
/// saltwater or lava, including liquids from mods, is drawn as water.
fn liquidKinds(allocator: std.mem.Allocator, gameData: GameData) ![]Liquid {
    const kinds = try allocator.alloc(Liquid, gameData.blockCodes.len);
    for (kinds, gameData.blockCodes) |*kind, code| {
        const name = code orelse "";
        kind.* = if (std.mem.startsWith(u8, name, "saltwater-"))
            .saltwater
        else if (std.mem.startsWith(u8, name, "lava-"))
            .lava
        else
            .water;
    }
    return kinds;
}

test liquidKinds {
    const codes = [_]?[]const u8{ "air", "water-still-7", "saltwater-n-3", "lava-still-7", "boilingwater-still-7", null };
    const gameData: GameData = .{ .arena = undefined, .blockCodes = &codes, .itemCodes = &.{}, .worldHeight = 256 };
    const kinds = try liquidKinds(std.testing.allocator, gameData);
    defer std.testing.allocator.free(kinds);
    try std.testing.expectEqualSlices(Liquid, &.{ .water, .water, .saltwater, .lava, .water, .water }, kinds);
}

/// Shallowest and deepest colour of each liquid: faded washes, as on an old map.
const liquidColours = std.EnumArray(Liquid, [2][3]u8).init(.{
    .water = .{ .{ 0xB8, 0xC8, 0xB8 }, .{ 0x6C, 0x8A, 0x8A } },
    .saltwater = .{ .{ 0xB0, 0xC2, 0xC6 }, .{ 0x5A, 0x76, 0x88 } },
    .lava = .{ .{ 0xB8, 0x5A, 0x30 }, .{ 0x80, 0x30, 0x18 } },
});
/// Water this deep or deeper takes the deepest colour.
const maxDepth = 16;

/// The colour of a liquid `depth` blocks above the ground below it.
fn liquidColour(kind: Liquid, depth: u16) u32 {
    const colours = liquidColours.get(kind);
    const fraction = @as(usize, @min(depth, maxDepth)) * 256 / maxDepth;
    const mixed = mix(colours[0], colours[1], fraction);
    return rgb(mixed[0], mixed[1], mixed[2]);
}

test liquidColour {
    try std.testing.expectEqual(rgb(0xB8, 0xC8, 0xB8), liquidColour(.water, 0));
    try std.testing.expectEqual(rgb(0x6C, 0x8A, 0x8A), liquidColour(.water, maxDepth));
    try std.testing.expectEqual(rgb(0x6C, 0x8A, 0x8A), liquidColour(.water, 200));
    try std.testing.expectEqual(rgb(0x5A, 0x76, 0x88), liquidColour(.saltwater, maxDepth));
}

/// `from` blended towards `to` by `fraction` 256ths.
fn mix(from: [3]u8, to: [3]u8, fraction: usize) [3]u8 {
    var mixed: [3]u8 = undefined;
    for (&mixed, from, to) |*channel, a, b| {
        channel.* = @intCast((@as(usize, a) * (256 - fraction) + @as(usize, b) * fraction) / 256);
    }
    return mixed;
}

/// Ink by height, lowest first: an old map's sepia, from dark brown to pale yellow.
const ramp = [_][3]u8{
    .{ 0x4A, 0x30, 0x1A },
    .{ 0x8A, 0x64, 0x38 },
    .{ 0xC4, 0xA4, 0x6C },
    .{ 0xE4, 0xD2, 0xA0 },
    .{ 0xF6, 0xEE, 0xD2 },
};
/// The ramp entry for ground level, so most of the map is pale and only low ground is dark.
const groundStep = 3;

/// The surface heights the ramp is spread over. They depend only on the world, so every
/// part of a map, and every world, is coloured the same way.
const Heights = struct {
    /// The ramp's darkest end, and everything below it.
    low: u16,
    /// Sea level: the ground-level colour.
    ground: u16,
    /// The ramp's palest end, and everything above it.
    high: u16,

    /// For a world: in a default 256-block world, 70, 110 (sea level) and 174. The test worlds'
    /// surfaces have a median of 112. The ends are fractions of the world height, on the guess
    /// that taller worlds have taller terrain too.
    fn of(gameData: GameData) Heights {
        const sea = gameData.seaLevel();
        return .{
            .low = @intCast(sea -| gameData.worldHeight * 40 / 256),
            .ground = @intCast(sea),
            .high = @intCast(sea + gameData.worldHeight * 64 / 256),
        };
    }
};

test "Heights.of" {
    const gameData: GameData = .{ .arena = undefined, .blockCodes = &.{}, .itemCodes = &.{}, .worldHeight = 256 };
    try std.testing.expectEqual(Heights{ .low = 70, .ground = 110, .high = 174 }, Heights.of(gameData));
}

/// The colour of a column at height `y`. `slope` is how much higher it is than its west and
/// north neighbours together: slopes facing the north-west light are brightened, the others
/// darkened, as on a hand-shaded relief map.
fn colour(y: u16, heights: Heights, slope: i32) u32 {
    // Where y falls on the ramp, in 1/256ths of a step: low..ground covers the steps up
    // to ground level, ground..high the rest.
    const steps = ramp.len - 1;
    const clamped = std.math.clamp(y, heights.low, heights.high);
    const position: usize = if (clamped <= heights.ground)
        stretch(clamped - heights.low, heights.ground - heights.low, groundStep)
    else
        groundStep * 256 + stretch(clamped - heights.ground, heights.high - heights.ground, steps - groundStep);
    const step: usize = @min(position / 256, steps - 1);
    const fraction = position - step * 256;
    // Light in 1/256ths: each block of slope changes the brightness by 1/16, up to ±3/8.
    const light: i32 = 256 + std.math.clamp(slope * 16, -96, 96);

    var channels = mix(ramp[step], ramp[step + 1], fraction);
    for (&channels) |*channel| {
        channel.* = @intCast(std.math.clamp(@divTrunc(@as(i32, channel.*) * light, 256), 0, 255));
    }
    return rgb(channels[0], channels[1], channels[2]);
}

/// `offset` out of `span` heights, as a distance along `steps` ramp steps in 1/256ths.
fn stretch(offset: u16, span: u16, steps: usize) usize {
    if (span == 0) return steps * 256;
    return @as(usize, offset) * steps * 256 / span;
}

/// An opaque pixel as stb expects it: red, green, blue and alpha bytes in memory order.
fn rgb(r: u8, g: u8, b: u8) u32 {
    return std.mem.nativeToLittle(u32, 0xFF000000 | @as(u32, b) << 16 | @as(u32, g) << 8 | r);
}

test colour {
    const heights: Heights = .{ .low = 10, .ground = 60, .high = 110 };
    // Level ground takes the ramp's colour for its height.
    try std.testing.expectEqual(rgb(0x4A, 0x30, 0x1A), colour(10, heights, 0));
    try std.testing.expectEqual(rgb(0xE4, 0xD2, 0xA0), colour(60, heights, 0));
    try std.testing.expectEqual(rgb(0xF6, 0xEE, 0xD2), colour(110, heights, 0));
    try std.testing.expectEqual(rgb(0xF6, 0xEE, 0xD2), colour(200, heights, 0));
    // A slope facing the light is brighter, one facing away darker.
    const level = colour(40, heights, 0);
    try std.testing.expect(colour(40, heights, 2) & 0xFF > level & 0xFF);
    try std.testing.expect(colour(40, heights, -2) & 0xFF < level & 0xFF);
}

fn discardPng(_: ?*anyopaque, _: ?*anyopaque, _: c_int) callconv(.c) void {}

/// The image the workers fill in, one pixel per block column.
pub const Map = struct {
    minX: usize,
    minZ: usize,
    width: usize,
    /// Height of the highest non-air block in each column, or null if there is none.
    top: []?u16,
    /// The block ID at that height.
    topBlock: []i32,
    /// Height of the highest liquid in each column, or null if there is none.
    liquidTop: []?u16,
    /// The liquid's block ID.
    liquidBlock: []i32,
};

/// Decodes every chunk on every core and, with a map, records each column's top block in it.
/// Returns how many chunks were read. Each worker opens its own connection and takes whole
/// chunk columns, so every pixel is written by exactly one thread and needs no locking.
pub fn scanChunks(allocator: std.mem.Allocator, dbPath: []const u8, map: ?Map) !usize {
    const workers = std.Thread.getCpuCount() catch 1;
    const jobs = try allocator.alloc(ScanJob, workers);
    defer allocator.free(jobs);
    const threads = try allocator.alloc(?std.Thread, workers);
    defer allocator.free(threads);
    for (jobs, threads, 0..) |*job, *thread, worker| {
        job.* = .{
            .allocator = allocator,
            .dbPath = dbPath,
            .worker = worker,
            .workers = workers,
            .map = map,
        };
        // If a thread can't be started, that share of the work runs here instead.
        thread.* = std.Thread.spawn(.{}, scanColumns, .{job}) catch null;
        if (thread.* == null) scanColumns(job);
    }
    for (threads) |thread| if (thread) |t| t.join();
    var chunks: usize = 0;
    for (jobs) |job| {
        if (job.err) |err| return err;
        chunks += job.chunks;
    }
    return chunks;
}

/// One worker's share of the chunks: the columns whose position (without its y bits)
/// leaves `worker` when divided by `workers`.
const ScanJob = struct {
    allocator: std.mem.Allocator,
    dbPath: []const u8,
    worker: usize,
    workers: usize,
    /// Shared with the other workers; this one only writes its own columns.
    map: ?Map,
    chunks: usize = 0,
    err: ?anyerror = null,
};

fn scanColumns(job: *ScanJob) void {
    scanColumnsOrFail(job) catch |err| {
        job.err = err;
    };
}

fn scanColumnsOrFail(job: *ScanJob) !void {
    const allocator = job.allocator;
    const db = try DB.initImmutable(allocator, job.dbPath);
    defer db.deinit();
    // 2^54 - 1 keeps x and z and drops y, so all chunks of a column go to the same worker.
    const sql = try std.fmt.allocPrint(allocator, "SELECT position, data FROM chunk WHERE (position & 18014398509481983) % {d} = {d};", .{ job.workers, job.worker });
    defer allocator.free(sql);
    const stmt = try db.prepare(sql);
    defer stmt.finalize();

    // Allocated once and reused for every chunk: decoding itself doesn't allocate.
    var decoder: Chunk.Decoder = try .init(allocator, Chunk.Decoder.defaultBlockEntityBytes);
    defer decoder.deinit(allocator);
    const chunk = try allocator.create(Chunk);
    defer allocator.destroy(chunk);
    chunk.* = .{};

    while (stmt.step()) {
        job.chunks += 1;
        // One undecodable chunk shouldn't stop the whole map.
        decoder.decode(chunk, stmt.column(u64, 0), stmt.column([]const u8, 1)) catch |err| {
            const pos = chunk.position;
            std.debug.print("storymap: skipping chunk ({}, {}, {}): {s}\n", .{ pos.x, pos.y, pos.z, @errorName(err) });
            continue;
        };

        const map = job.map orelse continue;
        const left = (chunk.position.x - map.minX) * 32;
        const up = (chunk.position.z - map.minZ) * 32;

        for (0..32) |z| for (0..32) |x| {
            const index = (up + z) * map.width + left + x;
            // Plants growing in water, such as seaweed and reeds, share their place with it:
            // from above, the water shows, and its depth goes down to the ground below them.
            recordTop(&chunk.blocks, &chunk.liquids, chunk.position.y, x, z, &map.top[index], &map.topBlock[index]);
            recordTop(&chunk.liquids, null, chunk.position.y, x, z, &map.liquidTop[index], &map.liquidBlock[index]);
        };
    }
}

/// Records the highest block of a chunk's layer in one column, unless a chunk above has
/// already recorded a higher one. Blocks where `hiddenBy` has a block are skipped.
fn recordTop(layer: *const Compression.Layer, hiddenBy: ?*const Compression.Layer, chunkY: usize, x: usize, z: usize, top: *?u16, block: *i32) void {
    if (layer.bits == 0) return; // all air
    const mask = if (hiddenBy) |other| if (other.bits == 0) null else other else null;
    // Walk down from the top of the chunk and stop at the first block.
    for (0..32) |i| {
        const y = 31 - i;
        const index = (y * 32 + z) * 32 + x;
        const id = layer.get(index);
        if (id == 0) continue;
        if (mask) |other| if (other.get(index) != 0) continue;
        const worldY: u16 = @intCast(chunkY * 32 + y);
        if (top.* == null or top.*.? < worldY) {
            top.* = worldY;
            block.* = id;
        }
        return;
    }
}

/// The five most common top blocks, by name.
fn printSurfaceBlocks(allocator: std.mem.Allocator, gameData: GameData, top: []const ?u16, topBlock: []const i32) !void {
    var counts: std.AutoArrayHashMapUnmanaged(i32, usize) = .empty;
    defer counts.deinit(allocator);
    var columns: usize = 0;
    for (top, topBlock) |column, block| if (column != null) {
        const entry = try counts.getOrPutValue(allocator, block, 0);
        entry.value_ptr.* += 1;
        columns += 1;
    };
    const Context = struct {
        values: []const usize,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.values[a] > ctx.values[b];
        }
    };
    counts.sort(Context{ .values = counts.values() });

    std.debug.print("most common surface blocks:", .{});
    for (counts.keys()[0..@min(5, counts.count())], counts.values()[0..@min(5, counts.count())], 0..) |block, count, i| {
        const percent = count * 100 / columns;
        if (gameData.blockCode(block)) |code| {
            std.debug.print("{s} {s} {}%", .{ if (i == 0) "" else ",", code, percent });
        } else {
            std.debug.print("{s} #{} {}%", .{ if (i == 0) "" else ",", block, percent });
        }
    }
    std.debug.print("\n", .{});
}
