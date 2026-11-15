//! Benchmarks tagged versions of Storymap on one save file, for docs/performance.md. Each `v*` tag
//! is checked out into its own worktree in `.benchmark/`, built with -Doptimize=ReleaseFast by the
//! Zig release its build.zig.zon names, and run `--runs` times after one untimed run, taking the
//! median of each time. From the project's folder:
//!
//!     zig run scripts/benchmark.zig -- <save-file> [--runs 7] [--tag v0.1.0 ...] [--current]
//!         [--isometric] [--write] [--jpegxl | --webp [--lossy-from <level>]]
//!         [--game <folder> [--data <folder>]] [--zigs <folder>]
//!
//! Each run is `storymap <save-file> --no-write --json` in the slowest styles, the Plain theme's
//! with `game:coloured` top-down (`styles`), drawing the top-down view. `--isometric` draws the
//! isometric view alone instead (`--views isometric`), with the world's area from one untimed
//! top-down render for its km²/s, `--write` writes the tiles into
//! `.benchmark/out`, so writing them is timed too, `--jpegxl` or `--webp` encodes them as JPEG XL
//! or WebP, and `--lossy-from` makes WebP lossy from a level up.
//!
//! A run's end to end is its whole process, from starting it to its exit, timed here for every
//! version. Its other times come from its `--json`; versions up to 0.2.0 have none, and render
//! only with their tiles written, so they're measured only with `--write`, their other times
//! are left blank, and their km²/s and chunks/s take the save's area and chunks from a version
//! that reports them. A version without what the options ask for (`--views`, the format) is
//! left out.
//!
//! Each version prepares its blocks into its own `.benchmark/<tag>.storyblk`, or
//! `.benchmark/<tag>.blocks/` for versions that keep them in a folder, with its own `prepare`, from
//! `--game` and `--data` if they're given and the blocks aren't there yet; renders don't look for
//! the game, so they don't hash its assets.
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

const usage = "usage: zig run scripts/benchmark.zig -- <save-file> [--runs 7] [--tag v0.1.0 ...] [--current] [--isometric] [--write] [--jpegxl | --webp [--lossy-from <level>]] [--game <folder> [--data <folder>]] [--zigs <folder>]\n";

const styles = [_][]const u8{ "--theme", "plain", "--style", "game:coloured" };
const outFolder = ".benchmark/out";

/// One version's medians. What its `--json` gives is null for versions without one.
const Result = struct {
    version: []const u8,
    runs: usize,
    /// The whole process, from starting it to its exit.
    total: f64,
    /// The peak memory of a run, in bytes, from the operating system.
    peak: usize,
    chunks: ?usize = null,
    /// The view's tiles, at every level, and its levels.
    tiles: ?usize = null,
    levels: ?usize = null,
    /// The top-down map's area in square metres; null for the isometric view, which has none.
    area: ?usize = null,
    /// Opening the save, its block list and which tiles it has.
    open: ?f64 = null,
    /// Drawing, encoding and the zoomed-out levels of every tile of the view.
    view: ?f64 = null,
    /// The view's time per part of the tile pipeline, summed over all workers.
    work: ?WorkerSeconds = null,
};

const ViewKind = enum { topdown, isometric };

/// The keys of `storymap <save-file> --json` this reads.
const Report = struct {
    version: []const u8,
    chunks: usize,
    seconds: struct { open: f64 },
    topdown: ?View = null,
    isometric: ?View = null,

    const View = struct {
        tiles: usize,
        levels: usize,
        area: ?usize = null,
        seconds: f64,
        workerSeconds: WorkerSeconds,
    };
};

const WorkerSeconds = struct { draw: f64, filter: f64, compress: f64, write: f64, shrink: f64 };

/// How each run is made.
const Runs = struct {
    count: usize,
    isometric: bool,
    write: bool,
    /// The option choosing the tiles' format, or null for PNG.
    format: ?[]const u8,
    /// `--lossy-from`'s level, passed on as it's written.
    lossyFrom: ?[]const u8 = null,
    /// The game's install and data folders, for preparing blocks.
    game: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const given = try init.minimal.args.toSlice(arena);

    var savePath: ?[]const u8 = null;
    var runs: Runs = .{ .count = 7, .isometric = false, .write = false, .format = null };
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
        } else if (std.mem.eql(u8, arg, "--jpegxl") or std.mem.eql(u8, arg, "--webp")) {
            if (runs.format != null) fail("--jpegxl and --webp: choose one\n", .{});
            runs.format = arg;
        } else if (isOneOf(arg, &.{ "--runs", "--tag", "--zigs", "--lossy-from", "--game", "--data" })) {
            i += 1;
            if (i == given.len) fail("{s} needs a value\n" ++ usage, .{arg});
            const value = given[i];
            if (std.mem.eql(u8, arg, "--runs")) {
                runs.count = std.fmt.parseInt(usize, value, 10) catch 0;
                if (runs.count == 0) fail("--runs: expected a whole number above 0, not {s}\n", .{value});
            }
            if (std.mem.eql(u8, arg, "--tag")) try tags.append(arena, value);
            if (std.mem.eql(u8, arg, "--zigs")) zigsPath = value;
            if (std.mem.eql(u8, arg, "--lossy-from")) runs.lossyFrom = value;
            if (std.mem.eql(u8, arg, "--game")) runs.game = value;
            if (std.mem.eql(u8, arg, "--data")) runs.data = value;
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
    try out.writeAll("| version | save | end to end | km²/s | chunks/s | drawing | open | peak memory |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    try out.flush();

    // Newest first, as the table lists them. The save's chunks and the area its top-down view
    // draws are the same for every version, so those who don't report them take them from one
    // that did.
    var results: std.ArrayList(Result) = .empty;
    var known: Save = .{};
    if (current) {
        std.debug.print("measuring the working tree\n", .{});
        if (try measureBuild(arena, io, "the working tree", try build(arena, io, ".", zigs), ".benchmark/working-tree", save, runs)) |measured| {
            var result = measured;
            result.version = try std.fmt.allocPrint(arena, "{s} (working tree)", .{result.version});
            try results.append(arena, result);
            known.learn(result);
            try writeRow(out, result, saveHash, known);
        }
    }
    for (tags.items) |tag| {
        std.debug.print("measuring {s}\n", .{tag});
        const result = try measure(arena, io, tag, save, runs, zigs) orelse continue;
        try results.append(arena, result);
        known.learn(result);
        try writeRow(out, result, saveHash, known);
    }
    if (results.items.len == 0) fail("no version measured\n", .{});

    try out.print("\nsave: {s} ({s})\n", .{ std.fs.path.basename(save), saveHash });
    for (results.items) |result| {
        const tiles = result.tiles orelse continue;
        try out.print("world: {} chunks, {d:.2} km², {s}: {} tiles in {} levels\n", .{
            result.chunks.?, @as(f64, @floatFromInt(result.area orelse 0)) / 1e6, if (runs.isometric) "isometric" else "top-down", tiles, result.levels.?,
        });
        break;
    }
    var date: [10]u8 = undefined;
    try out.print("machine: {s}, {} threads, {s}; ReleaseFast builds, median of {} runs{s}{s}, measured {s} UTC\n", .{
        processorName(arena, io), std.Thread.getCpuCount() catch 0, @tagName(builtin.os.tag), runs.count, if (runs.format) |format| if (std.mem.eql(u8, format, "--webp")) ", WebP tiles" else ", JPEG XL tiles" else "", if (runs.write) ", tiles written" else "", today(io, &date),
    });
    for (results.items) |result| {
        const work = result.work orelse continue;
        try writeWork(out, result.version, if (runs.isometric) "isometric" else "top-down", work);
    }
    try out.flush();
}

fn isOneOf(arg: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, arg, option)) return true;
    return false;
}

/// What's known of the save from the versions that report it.
const Save = struct {
    chunks: ?usize = null,
    area: ?usize = null,

    fn learn(self: *Save, result: Result) void {
        self.chunks = self.chunks orelse result.chunks;
        self.area = self.area orelse result.area;
    }
};

fn writeRow(out: *Io.Writer, result: Result, saveHash: []const u8, save: Save) !void {
    try out.print("| {s} | {s} | {d:.3} s |", .{ result.version, saveHash, result.total });
    if (result.area orelse save.area) |area| try out.print(" {d:.2} |", .{@as(f64, @floatFromInt(area)) / 1e6 / result.total}) else try out.writeAll(" – |");
    if (result.chunks orelse save.chunks) |chunks| try out.print(" {d:.0} |", .{@as(f64, @floatFromInt(chunks)) / result.total}) else try out.writeAll(" – |");
    if (result.view) |seconds| try out.print(" {d:.3} s |", .{seconds}) else try out.writeAll(" – |");
    if (result.open) |seconds| try out.print(" {d:.3} s |", .{seconds}) else try out.writeAll(" – |");
    try out.print(" {d:.0} MiB |\n", .{@as(f64, @floatFromInt(result.peak)) / (1 << 20)});
    try out.flush();
}

fn writeWork(out: *Io.Writer, version: []const u8, view: []const u8, work: WorkerSeconds) !void {
    try out.print("{s}, {s}, workers' time: draw {d:.2} s, filter {d:.2} s, compress {d:.2} s, write {d:.2} s, shrink {d:.2} s\n", .{
        version, view, work.draw, work.filter, work.compress, work.write, work.shrink,
    });
}

/// Checks `tag` out into `.benchmark/<tag>`, builds and benchmarks it, and removes the worktree.
/// Null for a version left out.
fn measure(arena: std.mem.Allocator, io: Io, tag: []const u8, save: []const u8, runs: Runs, zigs: []const u8) !?Result {
    const folder = try std.fs.path.join(arena, &.{ ".benchmark", tag });
    // Left over from a run that stopped.
    if (Io.Dir.cwd().access(io, folder, .{})) |_| {
        _ = try git(arena, io, &.{ "worktree", "remove", "--force", folder });
    } else |_| {}
    _ = try git(arena, io, &.{ "worktree", "add", "--detach", folder, tag });
    defer _ = git(arena, io, &.{ "worktree", "remove", "--force", folder }) catch {};
    return measureBuild(arena, io, tag, try build(arena, io, folder, zigs), folder, save, runs);
}

/// Prepares the blocks of `storymap`, named `label` in messages, into `blocksBase` with the
/// extension its kind of blocks takes, then runs it; null, with a message, if it hasn't what
/// `runs` asks for.
fn measureBuild(arena: std.mem.Allocator, io: Io, label: []const u8, storymap: []const u8, blocksBase: []const u8, save: []const u8, runs: Runs) !?Result {
    const help = try run(arena, io, &.{ storymap, "--help" }, ".");
    const has = struct {
        fn f(text: []const u8, option: []const u8) bool {
            return std.mem.indexOf(u8, text, option) != null;
        }
    }.f;
    if (runs.isometric and !has(help, "--views <views>")) return leftOut(label, "no isometric view of its own");
    if (runs.format) |format| if (!has(help, format)) return leftOut(label, "no such format");
    if (runs.lossyFrom != null and !has(help, "--lossy-from")) return leftOut(label, "no --lossy-from");
    const reports = has(help, "--json");
    if (!runs.write and !has(help, "--no-write")) return leftOut(label, "renders only with its tiles written: give --write");

    // Versions up to 0.2.0 keep their prepared blocks in a folder, later ones in a file.
    const blocks: ?[]const u8 = if (has(help, "--blocks <file>"))
        try std.fmt.allocPrint(arena, "{s}.storyblk", .{blocksBase})
    else if (has(help, "--blocks <folder>"))
        try std.fmt.allocPrint(arena, "{s}.blocks", .{blocksBase})
    else
        null;
    if (blocks) |path| if (runs.game) |game| {
        if (Io.Dir.cwd().access(io, path, .{})) |_| {} else |_| {
            std.debug.print("preparing the blocks of {s}\n", .{label});
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ storymap, "prepare", path, "--game", game });
            if (runs.data) |data| try argv.appendSlice(arena, &.{ "--data", data });
            _ = try run(arena, io, argv.items, ".");
        }
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ storymap, save });
    if (runs.write) try argv.append(arena, outFolder) else try argv.append(arena, "--no-write");
    if (blocks) |path| try argv.appendSlice(arena, &.{ "--blocks", path });
    try argv.appendSlice(arena, &styles);
    if (runs.isometric) try argv.appendSlice(arena, &.{ "--views", "isometric" });
    if (runs.format) |format| try argv.append(arena, format);
    if (runs.lossyFrom) |level| try argv.appendSlice(arena, &.{ "--lossy-from", level });
    if (reports) try argv.append(arena, "--json");

    // The first warms the file cache, and prepares the blocks if they aren't yet.
    _ = try timedRun(arena, io, argv.items, runs.write);
    const totals = try arena.alloc(f64, runs.count);
    const peaks = try arena.alloc(usize, runs.count);
    const parsed = try arena.alloc(Report, if (reports) runs.count else 0);
    for (totals, peaks, 0..) |*total, *peak, n| {
        const timed = try timedRun(arena, io, argv.items, runs.write);
        total.*, peak.* = .{ timed.seconds, timed.peak };
        if (reports) parsed[n] = try lastJson(Report, arena, timed.stdout);
    }
    Io.Dir.cwd().deleteTree(io, outFolder) catch {};
    std.mem.sort(f64, totals, {}, std.sort.asc(f64));
    std.mem.sort(usize, peaks, {}, std.sort.asc(usize));

    var result: Result = .{
        .version = if (reports) parsed[0].version else try versionOf(arena, io, storymap),
        .runs = runs.count,
        .total = totals[totals.len / 2],
        .peak = peaks[peaks.len / 2],
    };
    if (reports) {
        if (runs.isometric) try addView(.isometric, arena, &result, parsed) else try addView(.topdown, arena, &result, parsed);
    }
    if (runs.isometric and reports) {
        // The isometric view doesn't count the area it draws, so it's taken from an untimed
        // top-down render of the same world.
        var topdown: std.ArrayList([]const u8) = .empty;
        try topdown.appendSlice(arena, &.{ storymap, save, "--no-write" });
        if (blocks) |path| try topdown.appendSlice(arena, &.{ "--blocks", path });
        try topdown.appendSlice(arena, &styles);
        try topdown.appendSlice(arena, &.{ "--views", "topdown", "--json" });
        result.area = (try lastJson(Report, arena, (try timedRun(arena, io, topdown.items, false)).stdout)).topdown.?.area;
    }
    return result;
}

fn leftOut(label: []const u8, reason: []const u8) ?Result {
    std.debug.print("{s}: {s}; left out\n", .{ label, reason });
    return null;
}

/// What `reports`, of runs drawing the `which` view, say beyond the time this measures.
fn addView(comptime which: ViewKind, arena: std.mem.Allocator, result: *Result, reports: []const Report) !void {
    const view = viewOf(reports[0], which);
    result.chunks = reports[0].chunks;
    result.tiles = view.tiles;
    result.levels = view.levels;
    result.area = view.area;
    result.open = try median(arena, reports, struct {
        fn pick(r: Report) f64 {
            return r.seconds.open;
        }
    }.pick);
    result.view = try median(arena, reports, struct {
        fn pick(r: Report) f64 {
            return viewOf(r, which).seconds;
        }
    }.pick);
    result.work = try medianWork(arena, reports, which);
}

fn viewOf(report: Report, comptime which: ViewKind) Report.View {
    return switch (which) {
        .topdown => report.topdown.?,
        .isometric => report.isometric.?,
    };
}

/// The median of the times `pick` picks from `reports`.
fn median(arena: std.mem.Allocator, reports: []const Report, comptime pick: fn (Report) f64) !f64 {
    const values = try arena.alloc(f64, reports.len);
    for (values, reports) |*value, report| value.* = pick(report);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

/// The median of each part of a view's time.
fn medianWork(arena: std.mem.Allocator, reports: []const Report, comptime which: ViewKind) !WorkerSeconds {
    var work: WorkerSeconds = undefined;
    inline for (@typeInfo(WorkerSeconds).@"struct".field_names) |name| {
        @field(work, name) = try median(arena, reports, struct {
            fn pick(r: Report) f64 {
                return @field(viewOf(r, which).workerSeconds, name);
            }
        }.pick);
    }
    return work;
}

/// `storymap --version`'s version, for versions without `--json`.
fn versionOf(arena: std.mem.Allocator, io: Io, storymap: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, try run(arena, io, &.{ storymap, "--version" }, "."), " \r\n");
    return if (std.mem.lastIndexOfScalar(u8, text, ' ')) |space| text[space + 1 ..] else text;
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

const Timed = struct { stdout: []const u8, seconds: f64, peak: usize };

/// Runs `argv`, from starting it to its exit, with the run's peak memory in bytes. With
/// `writes`, the output folder is removed first, so every run writes its tiles afresh.
fn timedRun(arena: std.mem.Allocator, io: Io, argv: []const []const u8, writes: bool) !Timed {
    if (writes) Io.Dir.cwd().deleteTree(io, outFolder) catch {};
    const start: Io.Timestamp = .now(io, .awake);
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .pipe, .request_resource_usage_statistics = true });
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const stdout = try reader.interface.allocRemaining(arena, .unlimited);
    // A render's messages are a few lines, so they fit the pipe while stdout is read first.
    var errorReader = child.stderr.?.reader(io, &buffer);
    const stderr = try errorReader.interface.allocRemaining(arena, .unlimited);
    const term = try child.wait(io);
    const seconds = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e9;
    if (!term.success()) {
        std.debug.print("{s}", .{stderr});
        return error.CommandFailed;
    }
    return .{ .stdout = stdout, .seconds = seconds, .peak = child.resource_usage_statistics.getMaxRss() orelse 0 };
}

/// The last line of `stdout`, read as `T`.
fn lastJson(comptime T: type, arena: std.mem.Allocator, stdout: []const u8) !T {
    const line = std.mem.trim(u8, stdout[(std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, stdout, "\r\n"), '\n') orelse 0)..], " \r\n");
    return std.json.parseFromSliceLeaky(T, arena, line, .{ .ignore_unknown_fields = true });
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
