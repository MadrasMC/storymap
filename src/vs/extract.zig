//! `storymap extract-assets`: copies what rendering needs from a Vintage Story install and
//! the user's mods into a folder with the same layout as the originals, so the renderer can
//! read either one the same way (see Assets.zig). Which folders and why:
//! docs/rendering.md#assets.
//!
//! The game and data folders are only ever read.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;
const Assets = @import("Assets.zig");

pub const usage =
    \\usage: storymap extract-assets <output folder> [--game <install folder>] [--data <data folder>]
    \\
    \\Copies the block, item, shape and texture assets of a Vintage Story install,
    \\and every mod in the data folder's Mods, into an empty output folder:
    \\  <output>/game/assets/...   same layout as the install
    \\  <output>/data/Mods/...     same layout as the data folder
    \\--game and --data default to the game's standard locations.
    \\
;

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var outPath: ?[]const u8 = null;
    var gamePath: ?[]const u8 = null;
    var dataPath: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--game") or std.mem.eql(u8, arg, "--data")) {
            i += 1;
            if (i == args.len) fail(2, "{s} needs a folder\n\n" ++ usage, .{arg});
            if (arg[2] == 'g') gamePath = args[i] else dataPath = args[i];
        } else if (outPath == null and !std.mem.startsWith(u8, arg, "--")) {
            outPath = arg;
        } else fail(2, usage, .{});
    }
    const out = outPath orelse fail(2, usage, .{});

    const game = gamePath orelse Assets.findFolder(arena, io, init.environ_map, .game) orelse
        fail(1, "storymap: couldn't find Vintage Story; pass its install folder with --game\n", .{});
    const data = dataPath orelse Assets.findFolder(arena, io, init.environ_map, .data);

    var gameDir = Dir.cwd().openDir(io, game, .{}) catch |err|
        fail(1, "storymap: can't open the game folder {s} ({s})\n", .{ game, @errorName(err) });
    defer gameDir.close(io);
    var assetsDir = gameDir.openDir(io, "assets", .{ .iterate = true }) catch
        fail(1, "storymap: {s} has no assets folder; is it a Vintage Story install?\n", .{game});
    defer assetsDir.close(io);

    // Refuse to write into (or over) the folders we're reading from.
    const cwd = try realPath(arena, io, Dir.cwd());
    const outAbs = try std.fs.path.resolveAlloc(arena, &.{ cwd, out });
    for ([_]?[]const u8{ game, data }) |source| {
        const sourceAbs = try std.fs.path.resolveAlloc(arena, &.{ cwd, source orelse continue });
        if (isWithin(outAbs, sourceAbs) or isWithin(sourceAbs, outAbs))
            fail(1, "storymap: the output folder can't be inside or around {s}\n", .{sourceAbs});
    }

    var outDir = try openEmptyOutput(io, out);
    defer outDir.close(io);

    const version = try Assets.findVersion(arena, io, assetsDir) orelse "(unknown version)";
    var outAssets = try outDir.createDirPathOpen(io, "game/assets", .{});
    defer outAssets.close(io);
    const assetFiles = try copyAssets(init.gpa, io, assetsDir, outAssets);

    var mods: usize = 0;
    if (data) |dataFolder| {
        mods = try copyMods(init.gpa, io, dataFolder, outDir);
    } else {
        std.debug.print("storymap: no data folder found, so no mods copied; pass it with --data\n", .{});
    }

    std.debug.print("Copied {} asset files from Vintage Story {s} and {} mod{s} into {s}\n", .{
        assetFiles, version, mods, if (mods == 1) "" else "s", out,
    });
}

fn fail(status: u8, comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(status);
}

fn copyAssets(gpa: std.mem.Allocator, io: Io, assetsDir: Dir, outAssets: Dir) !usize {
    var walker = try assetsDir.walkSelectively(gpa);
    defer walker.deinit();
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        parts.clearRetainingCapacity();
        var it = std.mem.tokenizeScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |part| try parts.append(gpa, part);
        switch (Assets.actionFor(parts.items, entry.kind == .directory)) {
            .skip => {},
            .enter => try walker.enter(io, entry),
            .copy => {
                try entry.dir.copyFile(entry.basename, outAssets, entry.path, io, .{ .make_path = true });
                files += 1;
            },
        }
    }
    return files;
}

/// Copies every mod zip and mod folder in `<data>/Mods`, whole. Returns how many.
fn copyMods(gpa: std.mem.Allocator, io: Io, dataFolder: []const u8, outDir: Dir) !usize {
    var modsDir = Dir.cwd().openDir(io, dataFolder, .{}) catch |err|
        fail(1, "storymap: can't open the data folder {s} ({s})\n", .{ dataFolder, @errorName(err) });
    defer modsDir.close(io);
    var source = modsDir.openDir(io, "Mods", .{ .iterate = true }) catch return 0;
    defer source.close(io);
    var outMods = try outDir.createDirPathOpen(io, "data/Mods", .{});
    defer outMods.close(io);

    var mods: usize = 0;
    var it = source.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            try copyTree(gpa, io, source, entry.name, outMods);
            mods += 1;
        } else if (std.ascii.endsWithIgnoreCase(entry.name, ".zip")) {
            try source.copyFile(entry.name, outMods, entry.name, io, .{});
            mods += 1;
        } else {
            // Code-only mods (.dll, .cs) carry no assets.
            std.debug.print("storymap: skipped Mods/{s} (not a zip or folder)\n", .{entry.name});
        }
    }
    return mods;
}

fn copyTree(gpa: std.mem.Allocator, io: Io, parent: Dir, name: []const u8, outParent: Dir) !void {
    var dir = try parent.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);
    var outDir = try outParent.createDirPathOpen(io, name, .{});
    defer outDir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) try entry.dir.copyFile(entry.basename, outDir, entry.path, io, .{ .make_path = true });
    }
}

/// The output folder must be new or empty, so an old extraction never mixes with a new one.
fn openEmptyOutput(io: Io, path: []const u8) !Dir {
    if (Dir.cwd().openDir(io, path, .{ .iterate = true })) |dir| {
        var it = dir.iterate();
        if (try it.next(io) != null) fail(1, "storymap: {s} isn't empty; extract into a new or empty folder\n", .{path});
        return dir;
    } else |err| switch (err) {
        error.FileNotFound => {
            try Dir.cwd().createDirPath(io, path);
            return Dir.cwd().openDir(io, path, .{});
        },
        else => return err,
    }
}

fn realPath(allocator: std.mem.Allocator, io: Io, dir: Dir) ![]const u8 {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

/// Whether `path` is `parent` or inside it. Both must be absolute and normalised.
fn isWithin(path: []const u8, parent: []const u8) bool {
    const sep = std.fs.path.sep;
    const caseInsensitive = builtin.os.tag == .windows or builtin.os.tag.isDarwin();
    const parentTrimmed = std.mem.trimEnd(u8, parent, &.{sep});
    if (path.len < parentTrimmed.len) return false;
    const head = path[0..parentTrimmed.len];
    const same = if (caseInsensitive) std.ascii.eqlIgnoreCase(head, parentTrimmed) else std.mem.eql(u8, head, parentTrimmed);
    return same and (path.len == parentTrimmed.len or path[parentTrimmed.len] == sep);
}

test isWithin {
    const sep = std.fs.path.sep_str;
    const game = "C:" ++ sep ++ "Games" ++ sep ++ "Vintagestory";
    try std.testing.expect(isWithin(game, game));
    try std.testing.expect(isWithin(game ++ sep ++ "out", game));
    try std.testing.expect(!isWithin(game ++ "Data", game));
    try std.testing.expect(!isWithin("C:" ++ sep ++ "Games", game));
}
