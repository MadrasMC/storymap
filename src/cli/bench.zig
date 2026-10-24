//! `storymap bench`: renders a save several times and prints the median time of each stage,
//! for the numbers in docs/rendering.md#performance. Build with -Doptimize=ReleaseFast.
//!
//! The PNGs are encoded but not written, so the disk isn't timed, unless `--folder` names a
//! folder to write them to. One untimed render first warms the file cache.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const DB = @import("sqlite");
const Chunk = @import("vs").Chunk;
const SaveFile = @import("vs").SaveFile;
const topdown = @import("renderer").topdown;
const isometric = @import("renderer").isometric;
const Theme = @import("theme");
const build_options = @import("build_options");
const console = @import("console");
const render = @import("render.zig");
const args = @import("args");

pub const spec: args.Spec = .{
    .options = &.{
        .{ .name = "json", .description = "Print the results as one line of JSON, for scripts, instead of the summary." },
        .{ .name = "isometric", .description = "Also render the isometric view." },
        .{ .name = "folder", .value = "folder", .description = "Write the tiles into this folder, so writing them is timed too." },
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
    const withIsometric = parsed.flag("isometric");
    const dbPath = parsed.positional("save-file").?;
    const runs = if (parsed.positional("runs")) |text| std.fmt.parseInt(usize, text, 10) catch 0 else 5;
    if (runs == 0) console.fail("`[runs]`: invalid count {s}. expected: a whole number above 0", .{parsed.positional("runs").?});
    var folder: ?Io.Dir = null;
    if (parsed.value("folder")) |path| folder = Io.Dir.cwd().createDirPathOpen(io, path, .{}) catch |err|
        console.fail("{s}: could not create ({s})", .{ path, @errorName(err) });
    defer if (folder) |dir| dir.close(io);

    const samples = try allocator.alloc(Sample, runs);
    defer allocator.free(samples);
    // Every chunk in the save, which a render doesn't count: it reads only those it needs.
    var chunks: usize = 0;
    _ = try openAndRender(allocator, io, dbPath, folder, withIsometric);
    for (samples) |*sample| {
        sample.* = try openAndRender(allocator, io, dbPath, folder, withIsometric);
        const start: Io.Timestamp = .now(io, .awake);
        chunks = try decodeAll(allocator, dbPath);
        sample.decode = start.untilNow(io, .awake);
    }

    // The counts are the same every run.
    const counts = samples[0];
    const threads = std.Thread.getCpuCount() catch 1;
    const world = std.fs.path.basename(dbPath);
    const seconds: Result.Seconds = .{
        .open = try medianSeconds(allocator, samples, Sample.opening),
        .decode = try medianSeconds(allocator, samples, Sample.decoding),
        .tiles = try medianSeconds(allocator, samples, Sample.topdownTiles),
        .total = try medianSeconds(allocator, samples, Sample.whole),
    };
    const work = try workerSeconds(allocator, samples, .topdown);
    const isometricResult: ?Result.Isometric = if (counts.isometric) |stats| .{
        .tiles = stats.tiles,
        .levels = stats.levels,
        .chunksRead = stats.chunksRead,
        .seconds = try medianSeconds(allocator, samples, Sample.isometricTiles),
        .workerSeconds = try workerSeconds(allocator, samples, .isometric),
    } else null;
    // A block is a metre across, so the area in blocks is in square metres.
    const area: f64 = @floatFromInt(counts.topdown.area);

    if (!json) {
        try console.print(io, "storymap {s}, {s}: {} chunks ({} read for the map), {} tiles, {} threads, {s} build, median of {} runs{s}\n", .{
            build_options.version, world, chunks, counts.topdown.chunksRead, counts.topdown.tiles, threads, @tagName(builtin.mode), runs, if (folder != null) ", tiles written" else "",
        });
        try printStage(io, "open and block list", seconds.open, null);
        try printStage(io, "decode every chunk", seconds.decode, chunks);
        try printStage(io, "tiles", seconds.tiles, chunks);
        if (isometricResult) |result| try printStage(io, "isometric tiles", result.seconds, null);
        try printStage(io, "end to end", seconds.total, chunks);
        try printWork(io, "top-down", work);
        if (isometricResult) |result| {
            try printWork(io, "isometric", result.workerSeconds);
            try console.print(io, "  isometric: {} tiles in {} levels, {} chunks read\n", .{ result.tiles, result.levels, result.chunksRead });
        }
        try console.print(io, "  map area {d:.2} km², drawn at {d:.1} km²/s end to end\n", .{ area / 1e6, area / 1e6 / seconds.total });
        return;
    }

    const result: Result = .{
        .version = build_options.version,
        .world = world,
        .build = @tagName(builtin.mode),
        .threads = threads,
        .runs = runs,
        .written = folder != null,
        .chunks = chunks,
        .chunksRead = counts.topdown.chunksRead,
        .tiles = counts.topdown.tiles,
        .levels = counts.topdown.levels,
        .area = counts.topdown.area,
        .seconds = seconds,
        .areaPerSecond = area / seconds.total,
        .chunksPerSecond = @as(f64, @floatFromInt(chunks)) / seconds.total,
        .encodeShare = (work.filter + work.compress) / (work.draw + work.filter + work.compress + work.write + work.shrink),
        .workerSeconds = work,
        .isometric = isometricResult,
    };
    try console.print(io, "{f}\n", .{std.json.fmt(result, .{ .emit_null_optional_fields = false })});
}

/// One render's times and counts.
const Sample = struct {
    open: Io.Duration = .zero,
    topdown: topdown.Stats = .{},
    isometric: ?isometric.Stats = null,
    decode: Io.Duration = .zero,

    fn opening(self: Sample) Io.Duration {
        return self.open;
    }
    fn decoding(self: Sample) Io.Duration {
        return self.decode;
    }
    fn topdownTiles(self: Sample) Io.Duration {
        return self.topdown.duration;
    }
    fn isometricTiles(self: Sample) Io.Duration {
        return if (self.isometric) |stats| stats.duration else .zero;
    }
    fn whole(self: Sample) Io.Duration {
        return .{ .nanoseconds = self.open.nanoseconds + self.topdown.duration.nanoseconds + self.isometricTiles().nanoseconds };
    }
};

/// The median of each part of the tile pipeline's time in one view, summed over all workers.
fn workerSeconds(allocator: std.mem.Allocator, samples: []const Sample, comptime view: enum { topdown, isometric }) !Result.WorkerSeconds {
    var out: Result.WorkerSeconds = undefined;
    const times = try allocator.alloc(Io.Duration, samples.len);
    defer allocator.free(times);
    inline for (.{ "draw", "filter", "compress", "write", "shrink" }) |name| {
        for (times, samples) |*time, sample| time.* = switch (view) {
            .topdown => @field(sample.topdown.pipeline, name),
            .isometric => @field(sample.isometric.?.pipeline, name),
        };
        @field(out, name) = toSeconds(median(times));
    }
    return out;
}

fn printWork(io: Io, view: []const u8, work: Result.WorkerSeconds) !void {
    try console.print(io, "  workers' time, {s}: draw {d:.2} s, filter {d:.2} s, compress {d:.2} s, write {d:.2} s, shrink {d:.2} s\n", .{ view, work.draw, work.filter, work.compress, work.write, work.shrink });
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
    /// Whether the tiles were written (`--folder`), so writing them is in the times.
    written: bool,
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
    /// The save's chunks per second, end to end; only those holding the surface are read.
    chunksPerSecond: f64,
    /// The share of the top-down workers' time spent encoding PNGs.
    encodeShare: f64,
    /// Each part of the top-down tiles' time, summed over all workers.
    workerSeconds: WorkerSeconds,
    /// The isometric view, with `--isometric`.
    isometric: ?Isometric = null,

    const Seconds = struct {
        /// Opening the save, its block list and which tiles it has.
        open: f64,
        /// Decoding every chunk, without drawing, for comparison.
        decode: f64,
        /// Drawing and encoding every top-down tile.
        tiles: f64,
        /// Opening and the tiles of every view rendered: a whole render.
        total: f64,
    };

    /// Summed over all workers, so more than the wall time.
    const WorkerSeconds = struct {
        /// Drawing full-detail tiles.
        draw: f64,
        /// Encoding PNGs: filtering their rows, then compressing them.
        filter: f64,
        compress: f64,
        /// Creating the tiles' folders and writing their files; 0 without `--folder`.
        write: f64,
        /// Shrinking tiles for the level above.
        shrink: f64,
    };

    const Isometric = struct {
        tiles: usize,
        levels: usize,
        chunksRead: usize,
        /// Drawing and encoding every isometric tile.
        seconds: f64,
        workerSeconds: WorkerSeconds,
    };
};

const style = Theme.printed.topdown;

/// Opens the save and renders it, writing the tiles into `folder` if there is one.
fn openAndRender(allocator: std.mem.Allocator, io: Io, dbPath: []const u8, folder: ?Io.Dir, withIsometric: bool) !Sample {
    var sample: Sample = .{};
    const start: Io.Timestamp = .now(io, .awake);
    const save = try render.openSaveFile(allocator, io, dbPath);
    defer save.close(allocator);
    sample.open = start.untilNow(io, .awake);
    const options: topdown.Options = .{ .style = style, .stats = &sample.topdown };
    allocator.free(try if (folder) |dir|
        topdown.render(SaveFile, allocator, io, &save, .{ .folder = dir }, options)
    else
        topdown.render(SaveFile, allocator, io, &save, .discard, options));
    if (withIsometric) {
        var stats: isometric.Stats = .{};
        const isometricOptions: isometric.Options = .{ .style = Theme.printed.isometric, .stats = &stats };
        allocator.free(try if (folder) |dir|
            isometric.render(SaveFile, allocator, io, &save, .{ .folder = dir }, isometricOptions)
        else
            isometric.render(SaveFile, allocator, io, &save, .discard, isometricOptions));
        sample.isometric = stats;
    }
    return sample;
}

fn medianSeconds(allocator: std.mem.Allocator, samples: []const Sample, comptime get: fn (Sample) Io.Duration) !f64 {
    const times = try allocator.alloc(Io.Duration, samples.len);
    defer allocator.free(times);
    for (times, samples) |*time, sample| time.* = get(sample);
    return toSeconds(median(times));
}

fn toSeconds(duration: Io.Duration) f64 {
    return @as(f64, @floatFromInt(duration.nanoseconds)) / std.time.ns_per_s;
}

fn printStage(io: Io, name: []const u8, seconds: f64, chunks: ?usize) !void {
    try console.print(io, "  {s:<22} {d:>7.3} s", .{ name, seconds });
    if (chunks) |n| try console.print(io, "  {d:>9.0} chunks/s", .{@as(f64, @floatFromInt(n)) / seconds});
    try console.print(io, "\n", .{});
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

test median {
    var times = [_]Io.Duration{ .fromMilliseconds(30), .fromMilliseconds(10), .fromMilliseconds(20) };
    try std.testing.expectEqual(Io.Duration.fromMilliseconds(20), median(&times));
}
