const std = @import("std");
const extract = @import("vs/extract.zig");
const Save = @import("vs/Save.zig");
const Assets = @import("vs/Assets.zig");
const bench = @import("bench.zig");
const topdown = @import("renderer/topdown.zig");
const viewer = @import("viewer.zig");

const usage =
    \\usage: storymap <save.vcdbs> [output folder] [--theme <theme>] [--game <folder>] [--data <folder>]
    \\       storymap extract-assets <output folder> [--game <folder>] [--data <folder>]
    \\       storymap bench <save.vcdbs> [runs]
    \\
    \\Renders a top-down map of a Vintage Story save as tiles in the output folder,
    \\or in out when no folder is given, with index.html beside them to view it.
    \\--theme draws the page around the map: printed (the default), plain, or the
    \\folder of a theme of your own (see docs/themes.md).
    \\--game and --data are the game's install and data folders, for its assets and
    \\mods; they default to the standard locations. An extract-assets copy works too:
    \\--game <copy>/game --data <copy>/data.
    \\Run extract-assets without arguments for its options.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "extract-assets")) return extract.run(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "bench")) return bench.run(init, args[2..]);

    // The save and the output folder in order, and the options anywhere among them.
    var paths: [2][]const u8 = undefined;
    var pathCount: usize = 0;
    var themeName: []const u8 = "printed";
    var gamePath: ?[]const u8 = null;
    var dataPath: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const option = for ([_][]const u8{ "--theme", "--game", "--data" }) |name| {
            if (std.mem.eql(u8, args[i], name)) break name;
        } else null;
        if (option) |name| {
            i += 1;
            if (i == args.len) exitWithUsage();
            switch (name[2]) {
                't' => themeName = args[i],
                'g' => gamePath = args[i],
                else => dataPath = args[i],
            }
        } else {
            if (pathCount == paths.len) exitWithUsage();
            paths[pathCount] = args[i];
            pathCount += 1;
        }
    }
    if (pathCount == 0) exitWithUsage();
    const dbPath = paths[0];
    const outPath = if (pathCount == 2) paths[1] else "out";

    const theme = viewer.loadTheme(init.arena.allocator(), init.io, themeName) catch |err| {
        switch (err) {
            error.ThemeStyleEndsItsElement => std.debug.print("storymap: {s}/theme.css can't contain </style: it would end the theme's style in the page early\n", .{themeName}),
            error.ThemeScriptEndsItsElement => std.debug.print("storymap: {s}/theme.js can't contain </script: it would end the theme's script in the page early\n", .{themeName}),
            else => std.debug.print("storymap: there's no theme {s}: it isn't printed or plain, or a folder with theme.css and theme.js ({s})\n", .{ themeName, @errorName(err) }),
        }
        std.process.exit(1);
    };

    var out = std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err| {
        std.debug.print("storymap: can't create {s} ({s})\n", .{ outPath, @errorName(err) });
        std.process.exit(1);
    };
    defer out.close(init.io);
    const save = try Save.open(allocator, init.io, dbPath);
    defer save.close(allocator);
    var assets = openAssets(init, gamePath, dataPath);
    defer if (assets) |*opened| opened.close(init.io);
    if (assets) |*opened| try warnMissingMods(allocator, opened, &save, dataPath != null);
    try topdown.render(Save, allocator, init.io, &save, .{ .folder = out }, .{ .theme = theme });
}

/// The game's assets and mods, from the folders given or else the standard ones, or null
/// without them. A folder that was given but can't be read stops the program.
fn openAssets(init: std.process.Init, gamePath: ?[]const u8, dataPath: ?[]const u8) ?Assets {
    const io = init.io;
    const arena = init.arena.allocator();
    const game = gamePath orelse Assets.findFolder(arena, io, init.environ_map, .game) orelse return null;
    const data = dataPath orelse Assets.findFolder(arena, io, init.environ_map, .data);
    var gameDir = std.Io.Dir.cwd().openDir(io, game, .{}) catch |err| exitWith("can't open the game folder {s} ({s})\n", .{ game, @errorName(err) });
    defer gameDir.close(io);
    var dataDir: ?std.Io.Dir = if (data) |path| std.Io.Dir.cwd().openDir(io, path, .{}) catch |err|
        exitWith("can't open the data folder {s} ({s})\n", .{ path, @errorName(err) }) else null;
    defer if (dataDir) |*dir| dir.close(io);
    const assets = Assets.open(init.gpa, io, gameDir, dataDir) catch |err| switch (err) {
        error.NoAssetsFolder => exitWith("{s} has no assets folder; is it a Vintage Story install?\n", .{game}),
        else => exitWith("can't read the assets in {s} ({s})\n", .{ game, @errorName(err) }),
    };
    const mods = assets.sources.items.len - 1;
    std.debug.print("assets: Vintage Story {s}, {} mod{s}\n", .{ assets.version orelse "(unknown version)", mods, if (mods == 1) "" else "s" });
    return assets;
}

/// Warns about each mod the save's blocks and items come from that isn't installed.
fn warnMissingMods(allocator: std.mem.Allocator, assets: *const Assets, save: *const Save, dataGiven: bool) !void {
    const missing = try assets.missingMods(allocator, &.{ save.gameData.blockCodes, save.gameData.itemCodes });
    defer allocator.free(missing);
    for (missing) |mod| std.debug.print("storymap: the world uses the mod {s}, which isn't in the data folder's Mods{s}\n", .{
        mod, if (dataGiven) "" else "; pass the data folder with --data",
    });
}

fn exitWith(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("storymap: " ++ format, args);
    std.process.exit(1);
}

fn exitWithUsage() noreturn {
    std.debug.print(usage, .{});
    std.process.exit(2);
}

// Every file with tests, so `zig build test` runs them all.
test {
    _ = @import("sqlite.zig");
    _ = @import("ProtoBuf.zig");
    _ = @import("vs/Compression.zig");
    _ = @import("vs/Chunk.zig");
    _ = @import("vs/MapChunk.zig");
    _ = @import("vs/GameData.zig");
    _ = @import("vs/TreeAttribute.zig");
    _ = @import("vs/BlockEntity.zig");
    _ = @import("vs/extract.zig");
    _ = @import("vs/Assets.zig");
    _ = @import("vs/Save.zig");
    _ = @import("bench.zig");
    _ = @import("renderer/topdown.zig");
    _ = @import("columns.zig");
    _ = @import("tiles.zig");
    _ = @import("viewer.zig");
}
