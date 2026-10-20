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
const args = @import("args");

const gameOption: args.Option = .{ .name = "game", .value = "folder", .description = "The game's install folder, if it isn't in the standard place." };
const dataOption: args.Option = .{ .name = "data", .value = "folder", .description = "The game's data folder, if it isn't in the standard place." };

/// What a render takes, the program's default command.
const renderSpec: args.Spec = .{
    .options = &.{
        .{ .name = "theme", .value = "theme", .description = "What draws the page around the map, and colours it: printed (the default), plain, or a theme's folder (docs/themes.md)." },
        .{ .name = "season", .value = "season", .description = "Tint grass and leaves for spring, summer, fall or winter, instead of the season on the save's date." },
        .{ .name = "prepare", .description = "Prepare the blocks again, even if they were prepared before." },
        .{ .name = "blocks", .value = "folder", .description = "The blocks folder: blocks by default." },
        gameOption,
        dataOption,
    },
    .positionals = &.{
        .{ .name = "save", .description = "The save to render." },
        .{ .name = "folder", .optional = true, .description = "The output folder: out by default." },
    },
    .description =
    \\Renders a top-down map of a Vintage Story save as tiles in the output folder, with
    \\index.html beside them to view it.
    \\
    \\What the map needs from the game's and mods' assets is prepared once into the blocks
    \\folder, the first time a render needs it, or again with --prepare; prepare does only that.
    ,
};

/// What `storymap prepare` takes.
const prepareSpec: args.Spec = .{
    .options = &.{ gameOption, dataOption },
    .positionals = &.{.{ .name = "folder", .optional = true, .description = "The blocks folder: blocks by default." }},
    .description = "Prepares what the map needs from the game's and mods' assets into the blocks folder, even if it was prepared before.",
};

/// Where the game, its mods and the prepared blocks are.
const Folders = struct {
    game: ?[]const u8 = null,
    data: ?[]const u8 = null,
    blocks: []const u8 = Prepared.defaultFolder,
};

const program: args.Program = .{ .name = "storymap", .header = "storymap " ++ build_options.version };

const commands = .{
    args.Command(null, renderSpec, render),
    args.Command("prepare", prepareSpec, prepare),
    args.Command("bench", bench.spec, bench.run),
    args.Action(.{ .name = "version", .description = "Show Storymap's version." }, printVersion),
};

pub fn main(init: std.process.Init) !void {
    console.useUtf8();
    defer console.restore();

    var problem: args.Problem = .{};
    const given = try args.ofProcess(init.arena.allocator(), init.minimal.args);
    args.dispatch(program, commands, init.io, init, given, &problem) catch |err| switch (err) {
        error.InvalidArguments => {
            if (problem.kind != .missingArguments) std.debug.print("storymap: {f}\n\n", .{problem});
            std.debug.print("{s}", .{problem.usage});
            console.exit(2);
        },
        else => return err,
    };
}

/// `storymap --version`.
fn printVersion(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("{s}\n", .{program.header});
    try stdout.interface.flush();
}

/// `storymap prepare`: prepares the blocks, even if they were prepared before.
fn prepare(init: std.process.Init, parsed: args.Parsed(prepareSpec)) !void {
    const folders: Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.positional("folder") orelse Prepared.defaultFolder,
    };
    var prepared = prepareBlocks(init, folders, true) orelse unreachable;
    prepared.deinit();
}

/// `storymap <save.vcdbs>`: renders the save's map.
fn render(init: std.process.Init, parsed: args.Parsed(renderSpec)) !void {
    const allocator = init.gpa;
    const dbPath = parsed.positional("save").?;
    const outPath = parsed.positional("folder") orelse "out";
    const themeName = parsed.value("theme") orelse "printed";
    const season: ?Save.Season = if (parsed.value("season")) |name|
        std.meta.stringToEnum(Save.Season, name) orelse exitWith("there's no season {s}: it's spring, summer, fall or winter\n", .{name})
    else
        null;
    const folders: Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.value("blocks") orelse Prepared.defaultFolder,
    };
    const force = parsed.flag("prepare");

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

fn exitWith(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print("storymap: " ++ format, values);
    console.exit(1);
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
