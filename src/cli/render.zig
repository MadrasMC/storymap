//! `storymap <save-file>`, the default command: renders a top-down map of a save as tiles, with
//! index.html beside them to view it.
const std = @import("std");
const SaveFile = @import("vs").SaveFile;
const Prepared = @import("vs").Prepared;
const topdown = @import("renderer").topdown;
const isometric = @import("renderer").isometric;
const Style = @import("theme").Style;
const viewer = @import("viewer");
const Theme = @import("theme");
const console = @import("console");
const prepare = @import("prepare.zig");
const args = @import("args");

pub const spec: args.Spec = .{
    .options = &.{
        .{ .name = "theme", .value = "theme", .description = "What draws the page around the map, and the map's style: printed (the default), plain, or a theme's folder (docs/themes.md)." },
        .{ .name = "style", .value = "style", .description = "How to draw the map, instead of the theme's style: " ++ styleNames ++ " (docs/themes.md#map-style)." },
        .{ .name = "isometric", .description = "Also draw the isometric view." },
        .{ .name = "name", .value = "name", .description = "The world's name on the page, instead of the save's." },
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
        std.meta.stringToEnum(SaveFile.Season, name) orelse console.fail("`--season`: unknown season {s}. expected: spring, summer, fall, winter\n", .{name})
    else
        null;
    const folders: prepare.Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.value("blocks") orelse Prepared.defaultFolder,
    };
    const force = parsed.flag("prepare");
    const style: ?Style.Name = if (parsed.value("style")) |text|
        Style.parseName(text) orelse console.fail("`--style`: unknown style {s}. expected: {s}\n", .{ text, styleNames })
    else
        null;

    var problem: Theme.Problem = .{};
    const theme = Theme.load(init.arena.allocator(), init.io, themeName, style, &problem) catch switch (problem.kind) {
        .unreadable => console.fail("`--theme`: unknown theme {s} ({s}). expected: printed, plain, or a folder with theme.css and theme.js\n", .{ themeName, @errorName(problem.cause.?) }),
        .stylesheetEndsItsElement => console.fail("{s}/theme.css: contains </style, which would end it early\n", .{themeName}),
        .scriptEndsItsElement => console.fail("{s}/theme.js: contains </script, which would end it early\n", .{themeName}),
        .invalidStyle => if (problem.style.line == 0)
            console.fail("{s}/topdown/style.txt: {f}\n", .{ themeName, problem.style })
        else
            console.fail("{s}/topdown/style.txt:{}: {f}\n", .{ themeName, problem.style.line, problem.style }),
        .invalidIsometricStyle => if (problem.style.line == 0)
            console.fail("{s}/isometric/style.txt: {f}\n", .{ themeName, problem.style })
        else
            console.fail("{s}/isometric/style.txt:{}: {f}\n", .{ themeName, problem.style.line, problem.style }),
    };
    switch (theme.topdown) {
        .game => |gameStyle| if (gameStyle) |name| if (std.meta.stringToEnum(SaveFile.MapStyle, name) == null) {
            if (style != null) console.fail("`--style`: unknown style game:{s}. expected: {s}\n", .{ name, gameStyles });
            console.fail("{s}/topdown/style.txt: unknown style game:{s}. expected: {s}\n", .{ themeName, name, gameStyles });
        },
        else => {},
    }
    // The isometric view has one game style, `game`.
    switch (theme.isometric) {
        .game => |gameStyle| if (gameStyle) |name| console.fail("{s}/isometric/style.txt: unknown style game:{s}. expected: {s}, game\n", .{ themeName, name, Style.storymapNames }),
        else => {},
    }

    var out = std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err|
        console.fail("{s}: could not create ({s})\n", .{ outPath, @errorName(err) });
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
    const written = try topdown.render(SaveFile, allocator, init.io, &save, .{ .folder = out }, .{ .style = theme.topdown });
    defer allocator.free(written);
    var views: std.ArrayList(viewer.View) = .empty;
    defer views.deinit(allocator);
    try views.append(allocator, .{ .name = topdown.folder, .title = topdown.title, .projection = topdown.projection, .written = written });

    // The game's textures come with textured cubes (TODO.md item 8); until then, `game` draws
    // relief cubes in the default colours.
    const palette = switch (theme.isometric) {
        .relief => |colours| colours,
        .game => Theme.defaultColours,
    };
    const writtenIsometric = if (parsed.flag("isometric"))
        try isometric.render(SaveFile, allocator, init.io, &save, .{ .folder = out }, .{ .palette = palette })
    else
        null;
    defer if (writtenIsometric) |list| allocator.free(list);
    if (writtenIsometric) |list| try views.append(allocator, .{ .name = isometric.folder, .title = isometric.title, .projection = isometric.projection, .blockWidth = isometric.blockWidth, .written = list });

    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
    var description = save.describe();
    if (parsed.value("name")) |name| description.name = name;
    try viewer.write(allocator, init.io, out, description, now, views.items, theme);
}

const gameStyles = names: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(SaveFile.MapStyle)) |name| text = text ++ (if (text.len > 0) ", " else "") ++ "game:" ++ name;
    break :names text;
};

const styleNames = Style.storymapNames ++ ", game, " ++ gameStyles;

/// A save that can't be read stops the program with a message saying why.
pub fn openSaveFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !SaveFile {
    var problem: SaveFile.Problem = .{};
    const save = SaveFile.open(allocator, io, path, &problem) catch |err| switch (err) {
        error.InvalidSaveFile => switch (problem.kind) {
            .unopenable => console.fail("{s}: could not open ({s})\n", .{ path, @errorName(problem.cause.?) }),
            .notASave => console.fail("{s}: not a Vintage Story save ({s})\n", .{ path, @errorName(problem.cause.?) }),
            .noChunks => console.fail("{s}: no chunks to draw\n", .{path}),
            .unreadableBlockList => console.fail("{s}: could not read the block list ({s})\n", .{ path, @errorName(problem.cause.?) }),
        },
        else => return err,
    };
    if (save.unsaved) std.log.warn("{s}: unsaved changes won't be on the map (is the game running?)", .{path});
    return save;
}

/// Also names the mods that aren't installed.
fn warnUnknownBlocks(allocator: std.mem.Allocator, prepared: *const Prepared, save: *const SaveFile) !void {
    const unknown = try prepared.unknown(allocator, save.gameData.blockCodes);
    defer allocator.free(unknown.mods);
    for (unknown.mods) |mod| std.log.warn("mod {s}: not found", .{mod});
    if (unknown.example) |example| std.log.warn("{} blocks unknown to the game and its mods, e.g. {s}", .{ unknown.codes, example });
}

test "the plain theme draws the game's default style" {
    try std.testing.expectEqual(Style{ .game = null }, Theme.plain.topdown);
}
