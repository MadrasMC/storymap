const std = @import("std");
const Save = @import("vs/Save.zig");
const Assets = @import("vs/Assets.zig");
const Prepared = @import("vs/Prepared.zig");
const bench = @import("bench.zig");
const topdown = @import("renderer/topdown.zig");
const Style = @import("renderer/Style.zig");
const viewer = @import("viewer.zig");
const build_options = @import("build_options");
const console = @import("console.zig");
const cli = @import("cli.zig");
const clap = @import("clap");

const usage =
    \\usage: storymap <save.vcdbs> [output folder] [options]
    \\       storymap prepare [blocks folder] [--game <folder>] [--data <folder>]
    \\       storymap bench <save.vcdbs> [runs] [--json]
    \\       storymap --version
    \\
    \\Renders a top-down map of a Vintage Story save as tiles in the output folder,
    \\or in out when no folder is given, with index.html beside them to view it.
    \\
    \\What the map needs from the game's and mods' assets is prepared once into the
    \\blocks folder, or blocks when none is given, the first time a render needs it,
    \\or again with --prepare; prepare does only that.
    \\
;

/// A render's parameters, the program's default command.
const renderParams = clap.parseParamsComptime(
    \\-h, --help              Show this help.
    \\    --version           Show Storymap's version.
    \\    --theme <theme>     What draws the page around the map, and colours it: printed (the default), plain, or a theme's folder (docs/themes.md).
    \\    --season <season>   Tint grass and leaves for spring, summer, fall or winter, instead of the season on the save's date.
    \\    --prepare           Prepare the blocks again, even if they were prepared before.
    \\    --blocks <folder>   The blocks folder: blocks by default.
    \\    --game <folder>     The game's install folder, if it isn't in the standard place.
    \\    --data <folder>     The game's data folder, if it isn't in the standard place.
    \\<save>                  The save to render.
    \\<folder>...             The output folder: out by default.
    \\
);

/// `storymap prepare`'s parameters.
const prepareParams = clap.parseParamsComptime(
    \\-h, --help              Show this help.
    \\    --game <folder>     The game's install folder, if it isn't in the standard place.
    \\    --data <folder>     The game's data folder, if it isn't in the standard place.
    \\<folder>...             The blocks folder: blocks by default.
    \\
);

/// Every value is read as given; Storymap checks the ones with a fixed set of choices itself.
const parsers = .{ .save = clap.parsers.string, .folder = clap.parsers.string, .theme = clap.parsers.string, .season = clap.parsers.string };

/// Where the game, its mods and the prepared blocks are.
const Folders = struct {
    game: ?[]const u8 = null,
    data: ?[]const u8 = null,
    blocks: []const u8 = Prepared.defaultFolder,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    console.useUtf8();
    defer console.restore();

    // Without the program's name, as clap takes them.
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, all.len -| 1);
    for (args, all[1..]) |*arg, given| arg.* = given;

    if (args.len > 0 and std.mem.eql(u8, args[0], "bench")) return bench.run(init, args[1..]);
    if (args.len > 0 and std.mem.eql(u8, args[0], "prepare")) {
        const parsed = cli.parse(&prepareParams, parsers, arena, args[1..], usage);
        if (parsed.args.help != 0) return cli.printHelp(init.io, &prepareParams, usage);
        const folders: Folders = .{
            .game = parsed.args.game,
            .data = parsed.args.data,
            .blocks = cli.first(parsed.positionals[0]) orelse Prepared.defaultFolder,
        };
        var prepared = prepareBlocks(init, folders, true) orelse unreachable;
        prepared.deinit();
        return;
    }

    const parsed = cli.parse(&renderParams, parsers, arena, args, usage);
    if (parsed.args.help != 0) return cli.printHelp(init.io, &renderParams, usage);
    if (parsed.args.version != 0) {
        var buffer: [64]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try stdout.interface.print("storymap {s}\n", .{build_options.version});
        return stdout.interface.flush();
    }
    const dbPath = parsed.positionals[0] orelse exitWithUsage();
    const outPath = cli.first(parsed.positionals[1]) orelse "out";
    const themeName = parsed.args.theme orelse "printed";
    const season: ?Save.Season = if (parsed.args.season) |name|
        std.meta.stringToEnum(Save.Season, name) orelse exitWith("there's no season {s}: it's spring, summer, fall or winter\n", .{name})
    else
        null;
    const folders: Folders = .{
        .game = parsed.args.game,
        .data = parsed.args.data,
        .blocks = parsed.args.blocks orelse Prepared.defaultFolder,
    };
    const force = parsed.args.prepare != 0;

    const theme = viewer.loadTheme(init.arena.allocator(), init.io, themeName) catch |err| {
        switch (err) {
            error.ThemeStyleEndsItsElement => std.debug.print("storymap: {s}/theme.css can't contain </style: it would end the theme's style in the page early\n", .{themeName}),
            error.ThemeScriptEndsItsElement => std.debug.print("storymap: {s}/theme.js can't contain </script: it would end the theme's script in the page early\n", .{themeName}),
            else => std.debug.print("storymap: there's no theme {s}: it isn't printed or plain, or a folder with theme.css and theme.js ({s})\n", .{ themeName, @errorName(err) }),
        }
        console.exit(1);
    };
    var problem: Style.Problem = .{};
    const styleFile = Style.parse(theme.topdown, &problem) catch {
        if (problem.line == 0)
            exitWith("the theme {s}'s topdown/style.txt {s} {s}\n", .{ themeName, problem.message, problem.name })
        else
            exitWith("the theme {s}'s topdown/style.txt, line {}: {s} {s}\n", .{ themeName, problem.line, problem.name, problem.message });
    };

    var out = std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err| {
        std.debug.print("storymap: can't create {s} ({s})\n", .{ outPath, @errorName(err) });
        console.exit(1);
    };
    defer out.close(init.io);
    var save = try Save.open(allocator, init.io, dbPath);
    defer save.close(allocator);
    if (season) |chosen| save.seasonProgress = chosen.progress();
    var prepared = prepareBlocks(init, folders, force);
    defer if (prepared) |*blocks| blocks.deinit();
    if (prepared) |*blocks| {
        try warnUnknownBlocks(allocator, blocks, &save);
        save.useBlocks(blocks);
    }
    const style = styleFile.complete(Save.palette);
    try topdown.render(Save, allocator, init.io, &save, .{ .folder = out }, .{ .theme = theme, .style = style });
}

/// The prepared blocks for the installed game and mods, prepared now if they weren't yet or
/// `force` is set. Without the game, the newest set prepared before, or else null; `force`
/// then stops the program.
fn prepareBlocks(init: std.process.Init, folders: Folders, force: bool) ?Prepared {
    const io = init.io;
    const arena = init.arena.allocator();

    const gamePath = folders.game orelse Assets.findFolder(arena, io, init.environ_map, .game) orelse {
        if (force) exitWith("couldn't find Vintage Story; pass its install folder with --game\n", .{});
        var blocks = std.Io.Dir.cwd().openDir(io, folders.blocks, .{ .iterate = true }) catch return noBlocks();
        defer blocks.close(io);
        const newest = (Prepared.newest(arena, io, blocks) catch null) orelse return noBlocks();
        var folder = blocks.openDir(io, newest, .{}) catch return noBlocks();
        defer folder.close(io);
        const prepared = Prepared.load(init.gpa, io, folder) catch return noBlocks();
        std.debug.print("blocks: prepared earlier for Vintage Story {s}; the game wasn't found\n", .{prepared.gameVersion});
        return prepared;
    };

    var assets = openAssets(init, gamePath, folders.data);
    defer assets.close(io);
    var keyBuffer: [16]u8 = undefined;
    const key = Prepared.key(&keyBuffer, io, &assets) catch |err| exitWith("can't read the mods ({s})\n", .{@errorName(err)});
    const folderPath = std.fs.path.join(arena, &.{ folders.blocks, key }) catch exitWith("out of memory\n", .{});
    var folder = std.Io.Dir.cwd().createDirPathOpen(io, folderPath, .{}) catch |err|
        exitWith("can't create {s} ({s})\n", .{ folderPath, @errorName(err) });
    defer folder.close(io);

    const mods = assets.sources.items.len - 1;
    const modText = if (mods == 1) "mod" else "mods";
    if (force or !Prepared.exists(io, folder)) {
        const start: std.Io.Timestamp = .now(io, .awake);
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const count = Prepared.prepare(scratch.allocator(), io, &assets, folder) catch |err|
            exitWith("can't prepare the blocks into {s} ({s})\n", .{ folderPath, @errorName(err) });
        const seconds = @as(f64, @floatFromInt(start.untilNow(io, .awake).toMilliseconds())) / 1000;
        std.debug.print("blocks: prepared {} from Vintage Story {s} and {} {s} in {d:.1} s, into {s}\n", .{
            count, assets.version orelse "(unknown version)", mods, modText, seconds, folderPath,
        });
    } else {
        std.debug.print("blocks: Vintage Story {s} and {} {s}, prepared earlier\n", .{ assets.version orelse "(unknown version)", mods, modText });
    }
    return Prepared.load(init.gpa, io, folder) catch |err| exitWith("can't read the blocks prepared in {s} ({s})\n", .{ folderPath, @errorName(err) });
}

fn noBlocks() ?Prepared {
    std.debug.print("storymap: couldn't find Vintage Story, so its blocks aren't known; pass its install folder with --game\n", .{});
    return null;
}

/// The game's assets and mods, from the folders given or else the standard ones. A folder
/// that can't be read stops the program.
fn openAssets(init: std.process.Init, game: []const u8, dataPath: ?[]const u8) Assets {
    const io = init.io;
    const data = dataPath orelse Assets.findFolder(init.arena.allocator(), io, init.environ_map, .data);
    var gameDir = std.Io.Dir.cwd().openDir(io, game, .{}) catch |err| exitWith("can't open the game folder {s} ({s})\n", .{ game, @errorName(err) });
    defer gameDir.close(io);
    var dataDir: ?std.Io.Dir = if (data) |path| std.Io.Dir.cwd().openDir(io, path, .{}) catch |err|
        exitWith("can't open the data folder {s} ({s})\n", .{ path, @errorName(err) }) else null;
    defer if (dataDir) |*dir| dir.close(io);
    return Assets.open(init.gpa, io, gameDir, dataDir) catch |err| switch (err) {
        error.NoAssetsFolder => exitWith("{s} has no assets folder; is it a Vintage Story install?\n", .{game}),
        else => exitWith("can't read the assets in {s} ({s})\n", .{ game, @errorName(err) }),
    };
}

/// Warns about the save's blocks that the prepared ones don't have: those of mods that
/// aren't installed, and any others.
fn warnUnknownBlocks(allocator: std.mem.Allocator, prepared: *const Prepared, save: *const Save) !void {
    const unknown = try prepared.unknown(allocator, save.gameData.blockCodes);
    defer allocator.free(unknown.mods);
    for (unknown.mods) |mod| std.debug.print("storymap: the world uses the mod {s}, which isn't installed\n", .{mod});
    if (unknown.example) |example| std.debug.print("storymap: {} of the world's blocks aren't defined by the game or its mods, such as {s}\n", .{ unknown.codes, example });
}

fn exitWith(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("storymap: " ++ format, args);
    console.exit(1);
}

fn exitWithUsage() noreturn {
    std.debug.print(usage, .{});
    console.exit(2);
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
    _ = @import("vs/Assets.zig");
    _ = @import("vs/Json.zig");
    _ = @import("vs/Wildcard.zig");
    _ = @import("vs/BlockTypes.zig");
    _ = @import("vs/Prepared.zig");
    _ = @import("vs/TextureColours.zig");
    _ = @import("vs/Tint.zig");
    _ = @import("vs/Save.zig");
    _ = @import("bench.zig");
    _ = @import("renderer/topdown.zig");
    _ = @import("renderer/Style.zig");
    _ = @import("columns.zig");
    _ = @import("console.zig");
    _ = @import("cli.zig");
    _ = @import("tiles.zig");
    _ = @import("viewer.zig");
}

test "the plain theme's colours are the game's" {
    const style = Style.plain;
    try std.testing.expectEqual(Save.palette.colours, style.colours);
    try std.testing.expectEqual(Save.palette.wateredge, style.wateredge);
    var problem: Style.Problem = .{};
    try std.testing.expectEqual(style, (try Style.parse("style shaded\n", &problem)).complete(Save.palette));
}
