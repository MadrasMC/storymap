//! `storymap bench`: renders a save several times and prints the median time of each stage,
//! for the numbers in docs/rendering.md#performance. Build with -Doptimize=ReleaseFast.
//!
//! The PNGs are encoded but not written, so the disk isn't timed. One untimed render first
//! warms the file cache.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const DB = @import("sqlite");
const Chunk = @import("vs").Chunk;
const SaveFile = @import("vs").SaveFile;
const topdown = @import("renderer").topdown;
const Theme = @import("theme");
const build_options = @import("build_options");
const console = @import("console");
const render = @import("render.zig");
const args = @import("args");

pub const spec: args.Spec = .{
    .options = &.{
        .{ .name = "json", .description = "Print the results as one line of JSON, for scripts, instead of the summary." },
    },
    .positionals = &.{
        .{ .name = "save-file", .description = "The world's save file (.vcdbs)." },
        .{ .name = "runs", .optional = true, .description = "How many times to render it: 5 by default." },
    },
    .description = "Renders the save several times and prints the median time of each stage.",
};

pub fn run(init: std.process.Init, parsed: args.Parsed(spec)) !void {
    const allocator = init.gpa;
    const io = init.io;

    const json = parsed.flag("json");
    const dbPath = parsed.positional("save-file").?;
    const runs = if (parsed.positional("runs")) |text| std.fmt.parseInt(usize, text, 10) catch 0 else 5;
    if (runs == 0) fail("storymap: [runs] must be a whole number above 0\n", .{});

    const open = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(open);
    const decode = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(decode);
    const tiles = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(tiles);
    const total = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(total);
    const encodeShare = try allocator.alloc(f64, runs);
    defer allocator.free(encodeShare);

    var stats: topdown.Stats = .{};
    // Every chunk in the save, which a render doesn't count: it reads only those it needs.
    var chunks: usize = 0;
    _ = try openAndRender(allocator, io, dbPath, &stats);
    for (0..runs) |i| {
        open[i] = try openAndRender(allocator, io, dbPath, &stats);
        tiles[i] = stats.duration;
        total[i] = .{ .nanoseconds = open[i].nanoseconds + stats.duration.nanoseconds };
        const draw: f64 = @floatFromInt(stats.draw.nanoseconds);
        const encode: f64 = @floatFromInt(stats.encode.nanoseconds);
        encodeShare[i] = encode / (draw + encode);

        const start: Io.Timestamp = .now(io, .awake);
        chunks = try decodeAll(allocator, dbPath);
        decode[i] = start.untilNow(io, .awake);
    }

    const threads = std.Thread.getCpuCount() catch 1;
    const world = std.fs.path.basename(dbPath);
    const seconds: Result.Seconds = .{
        .open = medianSeconds(open),
        .decode = medianSeconds(decode),
        .tiles = medianSeconds(tiles),
        .total = medianSeconds(total),
    };
    std.mem.sort(f64, encodeShare, {}, std.sort.asc(f64));
    // A block is a metre across, so the area in blocks is in square metres.
    const area: f64 = @floatFromInt(stats.area);

    if (!json) {
        std.debug.print("storymap {s}, {s}: {} chunks ({} read for the map), {} tiles, {} threads, {s} build, median of {} runs\n", .{
            build_options.version, world, chunks, stats.chunksRead, stats.tiles, threads, @tagName(builtin.mode), runs,
        });
        printStage("open and block list", seconds.open, null);
        printStage("decode every chunk", seconds.decode, chunks);
        printStage("tiles", seconds.tiles, chunks);
        printStage("end to end", seconds.total, chunks);
        std.debug.print("  of the workers' time, {d:.0}% went to encoding PNGs\n", .{encodeShare[runs / 2] * 100});
        std.debug.print("  map area {d:.2} km², drawn at {d:.1} km²/s end to end\n", .{ area / 1e6, area / 1e6 / seconds.total });
        return;
    }

    const result: Result = .{
        .version = build_options.version,
        .world = world,
        .build = @tagName(builtin.mode),
        .threads = threads,
        .runs = runs,
        .chunks = chunks,
        .chunksRead = stats.chunksRead,
        .tiles = stats.tiles,
        .levels = stats.levels,
        .area = stats.area,
        .seconds = seconds,
        .areaPerSecond = area / seconds.total,
        .encodeShare = encodeShare[runs / 2],
    };
    var buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print("{f}\n", .{std.json.fmt(result, .{})});
    try stdout.interface.flush();
}

/// The results `--json` prints, for scripts comparing versions. Keys keep their names and
/// meaning from version to version; new ones may be added.
const Result = struct {
    /// The version of Storymap measured, from build.zig.zon.
    version: []const u8,
    /// The save's file name.
    world: []const u8,
    /// The build mode, as Zig names it, e.g. "fast" for -Doptimize=ReleaseFast.
    build: []const u8,
    /// The style drawn: the default theme's, as there are no prepared blocks here.
    style: []const u8 = switch (style) {
        .relief => "relief",
        .game => |name| if (name) |given| "game:" ++ given else "game",
    },
    threads: usize,
    /// Renders timed, after one untimed; every time is the median.
    runs: usize,
    /// Chunks in the save, and those read for the map.
    chunks: usize,
    chunksRead: usize,
    /// Tiles written at every level, and the levels.
    tiles: usize,
    levels: usize,
    /// The map's area, in square blocks (square metres): the block columns drawn.
    area: usize,
    seconds: Seconds,
    /// Square metres drawn per second, end to end.
    areaPerSecond: f64,
    /// The share of the workers' time spent encoding PNGs.
    encodeShare: f64,

    const Seconds = struct {
        /// Opening the save, its block list and which tiles it has.
        open: f64,
        /// Decoding every chunk, without drawing, for comparison.
        decode: f64,
        /// Drawing and encoding every tile.
        tiles: f64,
        /// Opening and the tiles: a whole render.
        total: f64,
    };
};

const style = Theme.printed.topdown;

/// Renders the save without writing anything. Returns how long opening it took; `stats` gets the
/// tiles' times.
fn openAndRender(allocator: std.mem.Allocator, io: Io, dbPath: []const u8, stats: *topdown.Stats) !Io.Duration {
    const start: Io.Timestamp = .now(io, .awake);
    const save = try render.openSaveFile(allocator, io, dbPath);
    defer save.close(allocator);
    const opened = start.untilNow(io, .awake);
    allocator.free(try topdown.render(SaveFile, allocator, io, &save, .discard, .{ .style = style, .stats = stats }));
    return opened;
}

fn medianSeconds(times: []Io.Duration) f64 {
    return @as(f64, @floatFromInt(median(times).nanoseconds)) / std.time.ns_per_s;
}

fn printStage(name: []const u8, seconds: f64, chunks: ?usize) void {
    std.debug.print("  {s:<22} {d:>7.3} s", .{ name, seconds });
    if (chunks) |n| std.debug.print("  {d:>9.0} chunks/s", .{@as(f64, @floatFromInt(n)) / seconds});
    std.debug.print("\n", .{});
}

/// Returns the number of chunks in the save.
fn decodeAll(allocator: std.mem.Allocator, dbPath: []const u8) !usize {
    const workers = std.Thread.getCpuCount() catch 1;
    const jobs = try allocator.alloc(DecodeJob, workers);
    defer allocator.free(jobs);
    const threads = try allocator.alloc(?std.Thread, workers);
    defer allocator.free(threads);
    for (jobs, threads, 0..) |*job, *thread, worker| {
        job.* = .{ .allocator = allocator, .dbPath = dbPath, .worker = worker, .workers = workers };
        thread.* = std.Thread.spawn(.{}, DecodeJob.run, .{job}) catch null;
        if (thread.* == null) job.run();
    }
    for (threads) |thread| if (thread) |t| t.join();
    var chunks: usize = 0;
    for (jobs) |job| {
        if (job.err) |err| return err;
        chunks += job.chunks;
    }
    return chunks;
}

const DecodeJob = struct {
    allocator: std.mem.Allocator,
    dbPath: []const u8,
    worker: usize,
    workers: usize,
    chunks: usize = 0,
    err: ?anyerror = null,

    fn run(job: *DecodeJob) void {
        job.runOrFail() catch |err| {
            job.err = err;
        };
    }

    fn runOrFail(job: *DecodeJob) !void {
        const allocator = job.allocator;
        const db = try DB.initImmutable(allocator, job.dbPath);
        defer db.deinit();
        var decoder: Chunk.Decoder = try .init(allocator, Chunk.Decoder.defaultBlockEntityBytes);
        defer decoder.deinit(allocator);
        const chunk = try allocator.create(Chunk);
        defer allocator.destroy(chunk);
        chunk.* = .{};
        // 2^54 - 1 keeps x and z and drops y, so all chunks of a column go to the same worker.
        const sql = try std.fmt.allocPrint(allocator, "SELECT position, data FROM chunk WHERE (position & 18014398509481983) % {d} = {d};", .{ job.workers, job.worker });
        defer allocator.free(sql);
        const stmt = try db.prepare(sql);
        defer stmt.finalize();
        while (stmt.step()) {
            job.chunks += 1;
            decoder.decode(chunk, stmt.column(u64, 0), stmt.column([]const u8, 1)) catch continue;
        }
    }
};

fn median(times: []Io.Duration) Io.Duration {
    std.mem.sort(Io.Duration, times, {}, struct {
        fn lessThan(_: void, a: Io.Duration, b: Io.Duration) bool {
            return a.nanoseconds < b.nanoseconds;
        }
    }.lessThan);
    return times[times.len / 2];
}

fn fail(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print(format, values);
    console.exit(2);
}

test median {
    var times = [_]Io.Duration{ .fromMilliseconds(30), .fromMilliseconds(10), .fromMilliseconds(20) };
    try std.testing.expectEqual(Io.Duration.fromMilliseconds(20), median(&times));
}
