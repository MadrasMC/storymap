//! Benchmarks tagged versions of Storymap on one save file, for docs/performance.md. Each `v*` tag
//! is checked out into its own worktree in `.benchmark/`, built with -Doptimize=ReleaseFast by the
//! Zig release its build.zig.zon names, and run `--runs` times after one untimed run, taking the
//! median of each time. From the project's folder:
//!
//!     zig run scripts/benchmark.zig -- <save-file> [--runs 7] [--tag v0.1.0 ...] [--current]
//!         [--isometric] [--write] [--jpegxl] [--zigs <folder>]
//!
//! Each run is `storymap <save-file> --no-write --json` in the slowest styles, the Plain theme's
//! with `game:coloured` top-down (`styles`). `--isometric` adds the isometric view, `--write`
//! writes the tiles into `.benchmark/out`, so writing them is timed too, and `--jpegxl` encodes
//! them as JPEG XL. Versions up to 0.2.0 have their own `storymap bench`, which draws the Printed
//! theme's relief in PNG and takes the medians itself; they're run with that, without the
//! isometric view.
//!
//! Zig releases are looked for in `--zigs` (`.benchmark/zig` by default) as their archives unpack,
//! e.g. `zig-x86_64-windows-0.17.0/`, and downloaded there from ziglang.org if missing.
//!
//! Prints a Markdown table, a row per version as it's measured, then the save, the world, the
//! machine and each version's time per part of the tile pipeline.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const exe = if (builtin.os.tag == .windows) ".exe" else "";

const usage = "usage: zig run scripts/benchmark.zig -- <save-file> [--runs 7] [--tag v0.1.0 ...] [--current] [--isometric] [--write] [--jpegxl] [--zigs <folder>]\n";

const styles = [_][]const u8{ "--theme", "plain", "--style", "game:coloured" };
const outFolder = ".benchmark/out";

/// One version's medians.
const Result = struct {
    version: []const u8,
    build: []const u8,
    threads: usize,
    runs: usize,
    chunks: usize,
    tiles: usize,
    levels: usize,
    area: usize,
    seconds: struct { open: f64, tiles: f64, total: f64 },
    /// The isometric view's tiles; null without it.
    isometric: ?f64 = null,
    /// The peak memory of a run, in bytes, from the operating system.
    peak: usize = 0,
    /// Each view's time per part of the tile pipeline, summed over all workers; null from
    /// `storymap bench`.
    work: ?struct { topdown: WorkerSeconds, isometric: ?WorkerSeconds } = null,
};

/// The keys of `storymap <save-file> --json` this reads.
const Report = struct {
    version: []const u8,
    build: []const u8,
    threads: usize,
    chunks: usize,
    seconds: struct { open: f64, total: f64 },
    topdown: View,
    isometric: ?View = null,

    const View = struct {
        tiles: usize,
        levels: usize,
        area: usize = 0,
        seconds: f64,
        workerSeconds: WorkerSeconds,
    };
};

const WorkerSeconds = struct { draw: f64, filter: f64, compress: f64, write: f64, shrink: f64 };

/// The keys of `storymap bench --json`, in versions up to 0.2.0, this reads.
const BenchReport = struct {
    version: []const u8,
    build: []const u8,
    threads: usize,
    runs: usize,
    chunks: usize,
    tiles: usize,
    levels: usize,
    area: usize,
    seconds: struct { open: f64, tiles: f64, total: f64 },
};

/// How each run is made.
const Runs = struct {
    count: usize,
    isometric: bool,
    write: bool,
    jpegxl: bool,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const given = try init.minimal.args.toSlice(arena);

    var savePath: ?[]const u8 = null;
    var runs: Runs = .{ .count = 7, .isometric = false, .write = false, .jpegxl = false };
    var tags: std.ArrayList([]const u8) = .empty;
    var current = false;
    var zigsPath: []const u8 = ".benchmark/zig";
    var i: usize = 1;
    while (i < given.len) : (i += 1) {
        const arg = given[i];
        if (std.mem.eql(u8, arg, "--current")) {
            current = true;
        } else if (std.mem.eql(u8, arg, "--isometric")) {
            runs.isometric = true;
        } else if (std.mem.eql(u8, arg, "--write")) {
            runs.write = true;
        } else if (std.mem.eql(u8, arg, "--jpegxl")) {
            runs.jpegxl = true;
        } else if (std.mem.eql(u8, arg, "--runs") or std.mem.eql(u8, arg, "--tag") or std.mem.eql(u8, arg, "--zigs")) {
            i += 1;
            if (i == given.len) fail("{s} needs a value\n" ++ usage, .{arg});
            if (std.mem.eql(u8, arg, "--runs")) {
                runs.count = std.fmt.parseInt(usize, given[i], 10) catch 0;
                if (runs.count == 0) fail("--runs: expected a whole number above 0, not {s}\n", .{given[i]});
            }
            if (std.mem.eql(u8, arg, "--tag")) try tags.append(arena, given[i]);
            if (std.mem.eql(u8, arg, "--zigs")) zigsPath = given[i];
        } else if (savePath == null and !std.mem.startsWith(u8, arg, "--")) {
            savePath = arg;
        } else fail("unexpected argument {s}\n" ++ usage, .{arg});
    }
    const save = try Io.Dir.cwd().realPathFileAlloc(io, savePath orelse fail(usage, .{}), arena);
    Io.Dir.cwd().access(io, "build.zig.zon", .{}) catch fail("run this from Storymap's folder\n", .{});
    // Absolute, as each build runs in its own folder.
    const zigs = try std.fs.path.resolve(arena, &.{ try Io.Dir.cwd().realPathFileAlloc(io, ".", arena), zigsPath });
    if (tags.items.len == 0) {
        var list = std.mem.tokenizeAny(u8, try git(arena, io, &.{ "tag", "--list", "v*", "--sort=-v:refname" }), "\r\n");
        while (list.next()) |tag| try tags.append(arena, tag);
    }
    if (tags.items.len == 0 and !current) fail("no tags to measure\n", .{});

    var buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    const saveHash = try hashFile(arena, io, save);
    if (runs.isometric) {
        try out.writeAll("| version | save | end to end | km²/s | chunks/s | tiles | isometric | open | peak memory |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    } else {
        try out.writeAll("| version | save | end to end | km²/s | chunks/s | tiles | open | peak memory |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    }
    try out.flush();

    // Newest first, as the table lists them.
    var results: std.ArrayList(Result) = .empty;
    if (current) {
        std.debug.print("measuring the working tree\n", .{});
        var result = try measureBuild(arena, io, try build(arena, io, ".", zigs), save, runs);
        result.version = try std.fmt.allocPrint(arena, "{s} (working tree)", .{result.version});
        try results.append(arena, result);
        try writeRow(out, result, runs, saveHash);
    }
    for (tags.items) |tag| {
        std.debug.print("measuring {s}\n", .{tag});
        const result = try measure(arena, io, tag, save, runs, zigs);
        try results.append(arena, result);
        try writeRow(out, result, runs, saveHash);
    }

    const last = results.items[results.items.len - 1];
    var date: [10]u8 = undefined;
    try out.print("\nsave: {s} ({s})\nworld: {} chunks, {d:.2} km², {} tiles in {} levels\n", .{
        std.fs.path.basename(save), saveHash, last.chunks, @as(f64, @floatFromInt(last.area)) / 1e6, last.tiles, last.levels,
    });
    try out.print("machine: {s}, {} threads, {s}; {s} build, median of {} runs{s}{s}, measured {s} UTC\n", .{
        processorName(arena, io), last.threads, @tagName(builtin.os.tag), last.build, runs.count, if (runs.jpegxl) ", JPEG XL tiles" else "", if (runs.write) ", tiles written" else "", today(io, &date),
    });
    for (results.items) |result| {
        const work = result.work orelse continue;
        try writeWork(out, result.version, "top-down", work.topdown);
        if (work.isometric) |isometric| try writeWork(out, result.version, "isometric", isometric);
    }
    try out.flush();
}

fn writeRow(out: *Io.Writer, result: Result, runs: Runs, saveHash: []const u8) !void {
    const area = @as(f64, @floatFromInt(result.area)) / 1e6;
    const chunksPerSecond = @as(f64, @floatFromInt(result.chunks)) / result.seconds.total;
    try out.print("| {s} | {s} | {d:.3} s | {d:.1} | {d:.0} | {d:.3} s |", .{
        result.version, saveHash, result.seconds.total, area / result.seconds.total, chunksPerSecond, result.seconds.tiles,
    });
    if (runs.isometric) {
        if (result.isometric) |seconds| try out.print(" {d:.3} s |", .{seconds}) else try out.writeAll(" – |");
    }
    try out.print(" {d:.3} s | {d:.0} MB |\n", .{ result.seconds.open, @as(f64, @floatFromInt(result.peak)) / 1e6 });
    try out.flush();
}

fn writeWork(out: *Io.Writer, version: []const u8, view: []const u8, work: WorkerSeconds) !void {
    try out.print("{s}, {s}, workers' time: draw {d:.2} s, filter {d:.2} s, compress {d:.2} s, write {d:.2} s, shrink {d:.2} s\n", .{
        version, view, work.draw, work.filter, work.compress, work.write, work.shrink,
    });
}

/// Checks `tag` out into `.benchmark/<tag>`, builds and benchmarks it, and removes the worktree.
fn measure(arena: std.mem.Allocator, io: Io, tag: []const u8, save: []const u8, runs: Runs, zigs: []const u8) !Result {
    const folder = try std.fs.path.join(arena, &.{ ".benchmark", tag });
    // Left over from a run that stopped.
    if (Io.Dir.cwd().access(io, folder, .{})) |_| {
        _ = try git(arena, io, &.{ "worktree", "remove", "--force", folder });
    } else |_| {}
    _ = try git(arena, io, &.{ "worktree", "add", "--detach", folder, tag });
    defer _ = git(arena, io, &.{ "worktree", "remove", "--force", folder }) catch {};
    return measureBuild(arena, io, try build(arena, io, folder, zigs), save, runs);
}

/// Runs `storymap`, its own `bench` if it has one.
fn measureBuild(arena: std.mem.Allocator, io: Io, storymap: []const u8, save: []const u8, runs: Runs) !Result {
    const help = try run(arena, io, &.{ storymap, "--help" }, ".");
    if (std.mem.indexOf(u8, help, "storymap bench ") != null) return bench(arena, io, storymap, save, runs);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ storymap, save });
    try argv.appendSlice(arena, &styles);
    if (runs.write) try argv.append(arena, outFolder) else try argv.append(arena, "--no-write");
    if (runs.isometric) try argv.append(arena, "--isometric");
    if (runs.jpegxl) try argv.append(arena, "--jpegxl");
    try argv.append(arena, "--json");

    // The first warms the file cache, and prepares the blocks if they aren't yet.
    _ = try runJson(Report, arena, io, argv.items);
    const reports = try arena.alloc(Report, runs.count);
    const peaks = try arena.alloc(usize, runs.count);
    for (reports, peaks) |*report, *peak| report.*, peak.* = try runJson(Report, arena, io, argv.items);

    const first = reports[0];
    var result: Result = .{
        .version = first.version,
        .build = first.build,
        .threads = first.threads,
        .runs = runs.count,
        .chunks = first.chunks,
        .tiles = first.topdown.tiles,
        .levels = first.topdown.levels,
        .area = first.topdown.area,
        .seconds = .{
            .open = try median(arena, reports, struct {
                fn pick(r: Report) f64 {
                    return r.seconds.open;
                }
            }.pick),
            .tiles = try median(arena, reports, struct {
                fn pick(r: Report) f64 {
                    return r.topdown.seconds;
                }
            }.pick),
            .total = try median(arena, reports, struct {
                fn pick(r: Report) f64 {
                    return r.seconds.total;
                }
            }.pick),
        },
        .work = .{ .topdown = try medianWork(arena, reports, .topdown), .isometric = null },
    };
    std.mem.sort(usize, peaks, {}, std.sort.asc(usize));
    result.peak = peaks[peaks.len / 2];
    if (first.isometric != null) {
        result.isometric = try median(arena, reports, struct {
            fn pick(r: Report) f64 {
                return r.isometric.?.seconds;
            }
        }.pick);
        result.work.?.isometric = try medianWork(arena, reports, .isometric);
    }
    return result;
}

/// The median of the times `pick` picks from `reports`.
fn median(arena: std.mem.Allocator, reports: []const Report, comptime pick: fn (Report) f64) !f64 {
    const values = try arena.alloc(f64, reports.len);
    for (values, reports) |*value, report| value.* = pick(report);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

/// The median of each part of a view's time.
fn medianWork(arena: std.mem.Allocator, reports: []const Report, comptime view: enum { topdown, isometric }) !WorkerSeconds {
    var work: WorkerSeconds = undefined;
    inline for (@typeInfo(WorkerSeconds).@"struct".field_names) |name| {
        @field(work, name) = try median(arena, reports, struct {
            fn pick(r: Report) f64 {
                const seconds = switch (view) {
                    .topdown => r.topdown.workerSeconds,
                    .isometric => r.isometric.?.workerSeconds,
                };
                return @field(seconds, name);
            }
        }.pick);
    }
    return work;
}

fn build(arena: std.mem.Allocator, io: Io, folder: []const u8, zigs: []const u8) ![]const u8 {
    _ = try run(arena, io, &.{ try zigFor(arena, io, folder, zigs), "build", "-Doptimize=ReleaseFast" }, folder);
    return std.fs.path.join(arena, &.{ folder, "zig-out", "bin", "storymap" ++ exe });
}

/// The Zig release `folder`'s build.zig.zon names, from `zigs`, downloaded there first if missing.
fn zigFor(arena: std.mem.Allocator, io: Io, folder: []const u8, zigs: []const u8) ![]const u8 {
    const zon = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ folder, "build.zig.zon" }), arena, .limited(1 << 20));
    const key = ".minimum_zig_version = \"";
    const start = (std.mem.indexOf(u8, zon, key) orelse fail("{s}/build.zig.zon names no Zig version\n", .{folder})) + key.len;
    const version = zon[start .. std.mem.indexOfScalarPos(u8, zon, start, '"') orelse return error.InvalidZon];
    const target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
    const name = try std.fmt.allocPrint(arena, "zig-{s}-{s}", .{ target, version });
    const zig = try std.fs.path.join(arena, &.{ zigs, name, "zig" ++ exe });
    if (Io.Dir.cwd().access(io, zig, .{})) |_| return zig else |_| {}

    std.debug.print("downloading Zig {s}\n", .{version});
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const index = try std.json.parseFromSliceLeaky(std.json.Value, arena, try get(&client, "https://ziglang.org/download/index.json"), .{});
    const release = index.object.get(version) orelse fail("Zig {s} isn't a release on ziglang.org\n", .{version});
    const download = (release.object.get(target) orelse fail("Zig {s} has no download for {s}\n", .{ version, target })).object;
    const url = download.get("tarball").?.string;
    const archive = try get(&client, url);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), download.get("shasum").?.string)) fail("{s} doesn't match its checksum\n", .{url});

    try Io.Dir.cwd().createDirPath(io, zigs);
    var dir = try Io.Dir.cwd().openDir(io, zigs, .{});
    defer dir.close(io);
    if (std.mem.endsWith(u8, url, ".zip")) {
        // std.zip reads from a file.
        try dir.writeFile(io, .{ .sub_path = "download.zip", .data = archive });
        defer dir.deleteFile(io, "download.zip") catch {};
        var file = try dir.openFile(io, "download.zip", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        try std.zip.extract(dir, &reader, .{});
    } else {
        var input: Io.Reader = .fixed(archive);
        var xz = try std.compress.xz.Decompress.init(&input, arena, &.{});
        try std.tar.extract(io, dir, &xz.reader, .{});
    }
    return zig;
}

fn get(client: *std.http.Client, url: []const u8) ![]u8 {
    var body: Io.Writer.Allocating = .init(client.allocator);
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    if (result.status != .ok) fail("{s}: {s}\n", .{ url, @tagName(result.status) });
    return body.written();
}

/// Versions up to 0.2.0: their `storymap bench` renders `runs.count` times and takes the medians.
fn bench(arena: std.mem.Allocator, io: Io, storymap: []const u8, save: []const u8, runs: Runs) !Result {
    const count = try std.fmt.allocPrint(arena, "{}", .{runs.count});
    const report, const peak = try runJson(BenchReport, arena, io, &.{ storymap, "bench", save, count, "--json" });
    return .{
        .version = report.version,
        .build = report.build,
        .threads = report.threads,
        .runs = report.runs,
        .chunks = report.chunks,
        .tiles = report.tiles,
        .levels = report.levels,
        .area = report.area,
        .seconds = .{ .open = report.seconds.open, .tiles = report.seconds.tiles, .total = report.seconds.total },
        .peak = peak,
    };
}

/// Runs `argv` and reads the last line it prints as `T`, with the run's peak memory in bytes.
fn runJson(comptime T: type, arena: std.mem.Allocator, io: Io, argv: []const []const u8) !struct { T, usize } {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .pipe, .request_resource_usage_statistics = true });
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const stdout = try reader.interface.allocRemaining(arena, .unlimited);
    // A render's messages are a few lines, so they fit the pipe while stdout is read first.
    var errorReader = child.stderr.?.reader(io, &buffer);
    const stderr = try errorReader.interface.allocRemaining(arena, .unlimited);
    if (!(try child.wait(io)).success()) {
        std.debug.print("{s}", .{stderr});
        return error.CommandFailed;
    }
    const line = std.mem.trim(u8, stdout[(std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, stdout, "\r\n"), '\n') orelse 0)..], " \r\n");
    const value = try std.json.parseFromSliceLeaky(T, arena, line, .{ .ignore_unknown_fields = true });
    return .{ value, child.resource_usage_statistics.getMaxRss() orelse 0 };
}

fn git(arena: std.mem.Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    const all = try std.mem.concat(arena, []const u8, &.{ &.{"git"}, argv });
    return run(arena, io, all, ".");
}

/// Runs `argv` in `cwd` and returns its output; a command that fails stops the script with its
/// errors.
fn run(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    if (!result.term.success()) {
        std.debug.print("{s}", .{result.stderr});
        return error.CommandFailed;
    }
    return result.stdout;
}

/// The first 12 hex digits of the file's SHA-256: enough to tell saves apart.
fn hashFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return arena.dupe(u8, hex[0..12]);
}

/// The processor's name, as the operating system gives it, or else the CPU model Zig knows.
fn processorName(arena: std.mem.Allocator, io: Io) []const u8 {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "powershell", "-NoProfile", "-Command", "(Get-CimInstance Win32_Processor).Name" },
        .macos => &.{ "sysctl", "-n", "machdep.cpu.brand_string" },
        else => &.{ "sh", "-c", "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2" },
    };
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return builtin.cpu.model.name;
    if (!result.term.success()) return builtin.cpu.model.name;
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

/// Today's date in UTC, as YYYY-MM-DD.
fn today(io: Io, buffer: *[10]u8) []const u8 {
    const seconds: u64 = @intCast(@max(Io.Timestamp.now(io, .real).toSeconds(), 0));
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay().calculateYearDay();
    const monthDay = day.calculateMonthDay();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, monthDay.month.numeric(), monthDay.day_index + 1 }) catch unreachable;
}

fn fail(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print(format, values);
    std.process.exit(2);
}
