//! Benchmarks tagged versions of Storymap on one save file, for docs/performance.md. Each `v*` tag
//! is checked out into its own worktree in `.benchmark/`, built with -Doptimize=ReleaseFast by the
//! Zig release its build.zig.zon names, and run as `storymap bench <save-file> <runs> --json`.
//! From the project's folder:
//!
//!     zig run scripts/benchmark.zig -- <save-file> [--runs 7] [--tag v0.1.0 ...] [--current]
//!         [--zigs <folder>]
//!
//! Zig releases are looked for in `--zigs` (`.benchmark/zig` by default) as their archives unpack,
//! e.g. `zig-x86_64-windows-0.17.0/`, and downloaded there from ziglang.org if missing.
//!
//! Prints a Markdown table, a row per version as it's measured, then the save, the world and the
//! machine.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const exe = if (builtin.os.tag == .windows) ".exe" else "";

const usage = "usage: zig run scripts/benchmark.zig -- <save-file> [--runs 7] [--tag v0.1.0 ...] [--current] [--zigs <folder>]\n";

/// The keys of `storymap bench --json` this reads.
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
    areaPerSecond: f64,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const given = try init.minimal.args.toSlice(arena);

    var savePath: ?[]const u8 = null;
    var runs: []const u8 = "7";
    var tags: std.ArrayList([]const u8) = .empty;
    var current = false;
    var zigsPath: []const u8 = ".benchmark/zig";
    var i: usize = 1;
    while (i < given.len) : (i += 1) {
        const arg = given[i];
        if (std.mem.eql(u8, arg, "--current")) {
            current = true;
        } else if (std.mem.eql(u8, arg, "--runs") or std.mem.eql(u8, arg, "--tag") or std.mem.eql(u8, arg, "--zigs")) {
            i += 1;
            if (i == given.len) fail("{s} needs a value\n" ++ usage, .{arg});
            if (std.mem.eql(u8, arg, "--runs")) runs = given[i];
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
        var list = std.mem.tokenizeAny(u8, try git(arena, io, &.{ "tag", "--list", "v*", "--sort=v:refname" }), "\r\n");
        while (list.next()) |tag| try tags.append(arena, tag);
    }
    if (tags.items.len == 0 and !current) fail("no tags to measure\n", .{});

    var buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    const saveHash = try hashFile(arena, io, save);
    try out.writeAll("| version | save | end to end | km²/s | chunks/s | tiles | open |\n| --- | --- | --- | --- | --- | --- | --- |\n");
    try out.flush();

    var last: ?Result = null;
    for (tags.items) |tag| {
        std.debug.print("measuring {s}\n", .{tag});
        last = try measure(arena, io, tag, save, runs, zigs);
        try writeRow(out, last.?, "", saveHash);
    }
    if (current) {
        std.debug.print("measuring the working tree\n", .{});
        last = try bench(arena, io, try build(arena, io, ".", zigs), save, runs);
        try writeRow(out, last.?, " (working tree)", saveHash);
    }

    const result = last.?;
    var date: [10]u8 = undefined;
    try out.print("\nsave: {s} ({s})\nworld: {} chunks, {d:.2} km², {} tiles in {} levels\n", .{
        std.fs.path.basename(save), saveHash, result.chunks, @as(f64, @floatFromInt(result.area)) / 1e6, result.tiles, result.levels,
    });
    try out.print("machine: {s}, {} threads, {s}; {s} build, median of {} runs, measured {s} UTC\n", .{
        processorName(arena, io), result.threads, @tagName(builtin.os.tag), result.build, result.runs, today(io, &date),
    });
    try out.flush();
}

fn writeRow(out: *Io.Writer, result: Result, label: []const u8, saveHash: []const u8) !void {
    const chunksPerSecond = @as(f64, @floatFromInt(result.chunks)) / result.seconds.total;
    try out.print("| {s}{s} | {s} | {d:.3} s | {d:.1} | {d:.0} | {d:.3} s | {d:.3} s |\n", .{
        result.version, label, saveHash, result.seconds.total, result.areaPerSecond / 1e6, chunksPerSecond, result.seconds.tiles, result.seconds.open,
    });
    try out.flush();
}

/// Checks `tag` out into `.benchmark/<tag>`, builds and benchmarks it, and removes the worktree.
fn measure(arena: std.mem.Allocator, io: Io, tag: []const u8, save: []const u8, runs: []const u8, zigs: []const u8) !Result {
    const folder = try std.fs.path.join(arena, &.{ ".benchmark", tag });
    // Left over from a run that stopped.
    if (Io.Dir.cwd().access(io, folder, .{})) |_| {
        _ = try git(arena, io, &.{ "worktree", "remove", "--force", folder });
    } else |_| {}
    _ = try git(arena, io, &.{ "worktree", "add", "--detach", folder, tag });
    defer _ = git(arena, io, &.{ "worktree", "remove", "--force", folder }) catch {};
    return bench(arena, io, try build(arena, io, folder, zigs), save, runs);
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

fn bench(arena: std.mem.Allocator, io: Io, storymap: []const u8, save: []const u8, runs: []const u8) !Result {
    const stdout = try run(arena, io, &.{ storymap, "bench", save, runs, "--json" }, ".");
    const line = std.mem.trim(u8, stdout[(std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, stdout, "\r\n"), '\n') orelse 0)..], " \r\n");
    return std.json.parseFromSliceLeaky(Result, arena, line, .{ .ignore_unknown_fields = true });
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
