//! `storymap bench`: renders a save several times and prints the median time of each stage,
//! for the numbers in docs/rendering.md#performance. Build with -Doptimize=ReleaseFast.
//!
//! The PNGs are encoded but not written, so the disk isn't timed. One untimed render first
//! warms the file cache.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const DB = @import("sqlite.zig");
const Chunk = @import("vs/Chunk.zig");
const topdown = @import("renderer/topdown.zig");

pub const usage =
    \\usage: storymap bench <save.vcdbs> [runs]
    \\
    \\Renders the save `runs` times (5 by default) and prints the median time of each stage.
    \\
;

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const allocator = init.gpa;
    const io = init.io;

    if (args.len < 1 or args.len > 2) fail(usage, .{});
    const dbPath = args[0];
    const runs = if (args.len == 2) std.fmt.parseInt(usize, args[1], 10) catch 0 else 5;
    if (runs == 0) fail("runs must be a whole number above 0\n\n" ++ usage, .{});

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
    try topdown.render(allocator, io, dbPath, .discard, .{ .stats = &stats });
    for (0..runs) |i| {
        try topdown.render(allocator, io, dbPath, .discard, .{ .stats = &stats });
        open[i] = stats.open;
        tiles[i] = stats.render;
        total[i] = .{ .nanoseconds = stats.open.nanoseconds + stats.render.nanoseconds };
        const draw: f64 = @floatFromInt(stats.draw.nanoseconds);
        const encode: f64 = @floatFromInt(stats.encode.nanoseconds);
        encodeShare[i] = encode / (draw + encode);

        // Decoding every chunk, without drawing anything, for comparison.
        const start: Io.Timestamp = .now(io, .awake);
        chunks = try decodeAll(allocator, dbPath);
        decode[i] = start.untilNow(io, .awake);
    }

    const threads = std.Thread.getCpuCount() catch 1;
    std.debug.print("{s}: {} chunks ({} read for the map), {} tiles, {} threads, {s} build, median of {} runs\n", .{
        std.fs.path.basename(dbPath), chunks, stats.chunksRead, stats.tiles, threads, @tagName(builtin.mode), runs,
    });
    printStage("open and block list", open, null);
    printStage("decode every chunk", decode, chunks);
    printStage("tiles", tiles, chunks);
    printStage("end to end", total, chunks);
    std.mem.sort(f64, encodeShare, {}, std.sort.asc(f64));
    std.debug.print("  of the workers' time, {d:.0}% went to encoding PNGs\n", .{encodeShare[runs / 2] * 100});
}

fn printStage(name: []const u8, times: []Io.Duration, chunks: ?usize) void {
    const seconds = @as(f64, @floatFromInt(median(times).nanoseconds)) / std.time.ns_per_s;
    std.debug.print("  {s:<22} {d:>7.3} s", .{ name, seconds });
    if (chunks) |n| std.debug.print("  {d:>9.0} chunks/s", .{@as(f64, @floatFromInt(n)) / seconds});
    std.debug.print("\n", .{});
}

/// Decodes every chunk in the save on every core, and returns how many there are. Each worker
/// takes the chunk columns whose position (without its y bits) leaves its number when divided
/// by the number of workers.
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

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(2);
}

test median {
    var times = [_]Io.Duration{ .fromMilliseconds(30), .fromMilliseconds(10), .fromMilliseconds(20) };
    try std.testing.expectEqual(Io.Duration.fromMilliseconds(20), median(&times));
}
