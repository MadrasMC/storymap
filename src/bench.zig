//! `storymap bench`: renders a save several times and prints the median time of each stage,
//! for the numbers in docs/rendering.md#performance. Build with -Doptimize=ReleaseFast.
//!
//! The PNG is encoded but not written, so the disk isn't timed. One untimed render first
//! warms the file cache.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
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
    const scan = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(scan);
    const png = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(png);
    const total = try allocator.alloc(Io.Duration, runs);
    defer allocator.free(total);

    var stats: topdown.Stats = .{};
    try topdown.render(allocator, io, dbPath, .discard, &stats);
    for (0..runs) |i| {
        try topdown.render(allocator, io, dbPath, .discard, &stats);
        open[i] = stats.open;
        scan[i] = stats.scan;
        png[i] = stats.png;
        total[i] = .{ .nanoseconds = stats.open.nanoseconds + stats.scan.nanoseconds + stats.png.nanoseconds };

        // Decoding alone, without finding top blocks, separates the two costs.
        const start: Io.Timestamp = .now(io, .awake);
        _ = try topdown.scanChunks(allocator, dbPath, null);
        decode[i] = start.untilNow(io, .awake);
    }

    const threads = std.Thread.getCpuCount() catch 1;
    std.debug.print("{s}: {} chunks, {}x{} image, {} threads, {s} build, median of {} runs\n", .{
        std.fs.path.basename(dbPath), stats.chunks, stats.width, stats.height, threads, @tagName(builtin.mode), runs,
    });
    printStage("open and block list", open, null);
    printStage("decode only", decode, stats.chunks);
    printStage("decode and top blocks", scan, stats.chunks);
    printStage("pixels and PNG", png, null);
    printStage("end to end", total, stats.chunks);
}

fn printStage(name: []const u8, times: []Io.Duration, chunks: ?usize) void {
    const seconds = @as(f64, @floatFromInt(median(times).nanoseconds)) / std.time.ns_per_s;
    std.debug.print("  {s:<22} {d:>7.3} s", .{ name, seconds });
    if (chunks) |n| std.debug.print("  {d:>9.0} chunks/s", .{@as(f64, @floatFromInt(n)) / seconds});
    std.debug.print("\n", .{});
}

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
