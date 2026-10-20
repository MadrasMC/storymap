//! `storymap <save-file>`, the default command: renders a top-down map of a save as tiles, with
//! index.html beside them to view it.
const std = @import("std");
const SaveFile = @import("vs").SaveFile;
const Prepared = @import("vs").Prepared;
const topdown = @import("renderer").topdown;
const Style = @import("renderer").Style;
const viewer = @import("viewer");
const Theme = @import("theme");
const console = @import("console");
const prepare = @import("prepare.zig");
const args = @import("args");

/// What a render takes.
pub const spec: args.Spec = .{
    .options = &.{
        .{ .name = "theme", .value = "theme", .description = "What draws the page around the map, and colours it: printed (the default), plain, or a theme's folder (docs/themes.md)." },
        .{ .name = "season", .value = "season", .description = "Tint grass and leaves for spring, summer, fall or winter, instead of the season on the save's date." },
        .{ .name = "prepare", .description = "Prepare the blocks again, even if they were prepared before." },
        .{ .name = "blocks", .value = "folder", .description = "The blocks folder: blocks by default." },
        prepare.gameOption,
        prepare.dataOption,
    },
    .positionals = &.{
        .{ .name = "save-file", .description = "The world's save file (.vcdbs)." },
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

pub fn run(init: std.process.Init, parsed: args.Parsed(spec)) !void {
    const allocator = init.gpa;
    const savePath = parsed.positional("save-file").?;
    const outPath = parsed.positional("folder") orelse "out";
    const themeName = parsed.value("theme") orelse "printed";
    const season: ?SaveFile.Season = if (parsed.value("season")) |name|
        std.meta.stringToEnum(SaveFile.Season, name) orelse console.fail("there's no season {s}: it's spring, summer, fall or winter\n", .{name})
    else
        null;
    const folders: prepare.Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.value("blocks") orelse Prepared.defaultFolder,
    };
    const force = parsed.flag("prepare");

    const theme = Theme.load(init.arena.allocator(), init.io, themeName) catch |err| switch (err) {
        error.ThemeStyleEndsItsElement => console.fail("{s}/theme.css can't contain </style: it would end the theme's style in the page early\n", .{themeName}),
        error.ThemeScriptEndsItsElement => console.fail("{s}/theme.js can't contain </script: it would end the theme's script in the page early\n", .{themeName}),
        else => console.fail("there's no theme {s}: it isn't printed or plain, or a folder with theme.css and theme.js ({s})\n", .{ themeName, @errorName(err) }),
    };
    var problem: Style.Problem = .{};
    const style = Style.parse(theme.topdown, SaveFile.palette, &problem) catch {
        if (problem.line == 0)
            console.fail("the theme {s}'s topdown/style.txt {s}{s}{s}\n", .{ themeName, problem.message, if (problem.name.len > 0) " " else "", problem.name })
        else
            console.fail("the theme {s}'s topdown/style.txt, line {}: {s} {s}\n", .{ themeName, problem.line, problem.name, problem.message });
    };

    var out = std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err|
        console.fail("can't create {s} ({s})\n", .{ outPath, @errorName(err) });
    defer out.close(init.io);
    var save = try openSaveFile(allocator, init.io, savePath);
    defer save.close(allocator);
    if (season) |chosen| save.seasonProgress = chosen.progress();
    var prepared = prepare.blocks(init, folders, force);
    defer if (prepared) |*blocks| blocks.deinit();
    if (prepared) |*blocks| {
        try warnUnknownBlocks(allocator, blocks, &save);
        save.useBlocks(blocks);
    }
    const written = try topdown.render(SaveFile, allocator, init.io, &save, .{ .folder = out }, .{ .style = style });
    defer allocator.free(written);

    // The viewer page goes next to the tiles. With more views, it'll list them all.
    const views = [_]viewer.View{.{ .name = topdown.folder, .title = topdown.title, .projection = topdown.projection, .written = written }};
    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
    try viewer.write(allocator, init.io, out, save.describe(), now, &views, theme);
}

/// The save file at `path`, opened for rendering. One that can't be read stops the program
/// with a message saying why.
pub fn openSaveFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !SaveFile {
    var problem: SaveFile.Problem = .{};
    const save = SaveFile.open(allocator, io, path, &problem) catch |err| switch (err) {
        error.InvalidSaveFile => switch (problem.kind) {
            .unopenable => console.fail("can't open {s} ({s})\n", .{ path, @errorName(problem.cause.?) }),
            .notASave => console.fail("{s} isn't a Vintage Story save ({s})\n", .{ path, @errorName(problem.cause.?) }),
            .noChunks => console.fail("{s} has no chunks, so there's nothing to draw\n", .{path}),
            .unreadableBlockList => console.fail("can't read the block list in {s} ({s})\n", .{ path, @errorName(problem.cause.?) }),
        },
        else => return err,
    };
    if (save.unsaved) std.debug.print("storymap: {s} has unsaved changes (is the game running?); they won't be on the map\n", .{path});
    return save;
}

/// Warns about the save's blocks that the prepared ones don't have: those of mods that
/// aren't installed, and any others.
fn warnUnknownBlocks(allocator: std.mem.Allocator, prepared: *const Prepared, save: *const SaveFile) !void {
    const unknown = try prepared.unknown(allocator, save.gameData.blockCodes);
    defer allocator.free(unknown.mods);
    for (unknown.mods) |mod| std.debug.print("storymap: the world uses the mod {s}, which isn't installed\n", .{mod});
    if (unknown.example) |example| std.debug.print("storymap: {} of the world's blocks aren't defined by the game or its mods, such as {s}\n", .{ unknown.codes, example });
}

test "the built-in themes' styles give every colour" {
    var problem: Style.Problem = .{};
    for (Theme.builtIn) |entry| _ = try Style.parse(entry.theme.topdown, null, &problem);
    const printed = try Style.parse(Theme.printed.topdown, null, &problem);
    try std.testing.expectEqual(.relief, printed.kind);
    try std.testing.expectEqual(Style.Rgb{ 0xE4, 0xD2, 0xA0 }, printed.colours.get(.land));
}

test "the plain theme's colours are the game's" {
    var problem: Style.Problem = .{};
    const style = try Style.parse(Theme.plain.topdown, null, &problem);
    try std.testing.expectEqual(.shaded, style.kind);
    try std.testing.expectEqual(SaveFile.palette.colours, style.colours);
    try std.testing.expectEqual(SaveFile.palette.wateredge, style.wateredge);
    try std.testing.expectEqual(style, try Style.parse("style shaded\n", SaveFile.palette, &problem));
}
