//! `storymap <save-file>`, the default command: renders a top-down map of a save as tiles, with
//! index.html beside them to view it.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const tiles = @import("tiles");
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
        .{ .name = "jpegxl", .description = "Encode the tiles as lossless JPEG XL instead of PNG, which not every browser shows." },
        .{ .name = "webp", .description = "Encode the tiles as lossless WebP instead of PNG." },
        .{ .name = "no-write", .description = "Draw and encode the tiles without writing anything, to time the rest." },
        .{ .name = "json", .description = "Print the render's times and counts on stdout as one line of JSON, for scripts." },
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
    const start: std.Io.Timestamp = .now(init.io, .awake);
    const allocator = init.gpa;
    const savePath = parsed.positional("save-file").?;
    const outPath = parsed.positional("folder") orelse "out";
    const themeName = parsed.value("theme") orelse "printed";
    const season: ?SaveFile.Season = if (parsed.value("season")) |name|
        std.meta.stringToEnum(SaveFile.Season, name) orelse console.fail("`--season`: unknown season {s}. expected: spring, summer, fall, winter", .{name})
    else
        null;
    const folders: prepare.Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.value("blocks") orelse Prepared.defaultFolder,
    };
    const force = parsed.flag("prepare");
    const write = !parsed.flag("no-write");
    const theme = loadTheme(init, themeName, parsed.value("style"));

    const out: ?std.Io.Dir = if (write) std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err|
        console.fail("{s}: could not create ({s})", .{ outPath, @errorName(err) }) else null;
    defer if (out) |dir| dir.close(init.io);
    if (parsed.flag("jpegxl") and parsed.flag("webp")) console.fail("`--jpegxl` and `--webp`: choose one", .{});
    const format: tiles.Format = if (parsed.flag("jpegxl")) .jpegxl else if (parsed.flag("webp")) .webp else .png;
    const output: tiles.Output = .{ .folder = out, .format = format };

    const loading: std.Io.Timestamp = .now(init.io, .awake);
    var prepared = prepare.blocks(init, folders, force);
    defer if (prepared) |*blocks| blocks.deinit();
    const blocksTime = loading.untilNow(init.io, .awake);

    const opening: std.Io.Timestamp = .now(init.io, .awake);
    var save = try openSaveFile(allocator, init.io, savePath);
    defer save.close(allocator);
    if (season) |chosen| save.seasonProgress = chosen.progress();
    if (prepared) |*blocks| {
        try warnUnknownBlocks(allocator, blocks, &save);
        save.useBlocks(blocks);
    }
    const openTime = opening.untilNow(init.io, .awake);

    var topdownStats: topdown.Stats = .{};
    const written = try topdown.render(SaveFile, allocator, init.io, &save, output, .{ .style = theme.topdown }, &topdownStats);
    defer allocator.free(written);
    logTopdown(&save, topdownStats);
    var views: std.ArrayList(viewer.View) = .empty;
    defer views.deinit(allocator);
    try views.append(allocator, .{ .name = topdown.folder, .title = topdown.title, .projection = topdown.projection, .format = output.format, .written = written });

    var isometricStats: ?isometric.Stats = null;
    const writtenIsometric = if (parsed.flag("isometric")) list: {
        isometricStats = .{};
        break :list try isometric.render(SaveFile, allocator, init.io, &save, output, .{ .style = theme.isometric }, &isometricStats.?);
    } else null;
    defer if (writtenIsometric) |list| allocator.free(list);
    if (isometricStats) |stats| console.log("isometric: {} tiles in {} levels in {d:.2} s, {} chunks read", .{ stats.tiles, stats.levels, seconds(stats.duration), stats.chunksRead });
    if (writtenIsometric) |list| try views.append(allocator, .{ .name = isometric.folder, .title = isometric.title, .projection = isometric.projection, .blockWidth = isometric.blockWidth, .format = output.format, .written = list });

    if (out) |dir| {
        const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
        var description = save.describe();
        if (parsed.value("name")) |name| description.name = name;
        try viewer.write(allocator, init.io, dir, description, now, views.items, theme);
    }
    const total = start.untilNow(init.io, .awake);
    if (write) {
        console.log("done in {d:.2} s: {s}/index.html", .{ seconds(total), outPath });
    } else {
        console.log("done in {d:.2} s, nothing written", .{seconds(total)});
    }

    if (!parsed.flag("json")) return;
    const arena = init.arena.allocator();
    const report: Report = .{
        .version = build_options.version,
        .world = std.fs.path.basename(savePath),
        .build = @tagName(builtin.mode),
        .threads = std.Thread.getCpuCount() catch 1,
        .written = write,
        .format = @tagName(output.format),
        .chunks = try save.countChunks(),
        .seconds = .{ .blocks = seconds(blocksTime), .open = seconds(openTime), .total = seconds(total) },
        .topdown = .{
            .style = try std.fmt.allocPrint(arena, "{f}", .{theme.topdown}),
            .tiles = topdownStats.tiles,
            .levels = topdownStats.levels,
            .chunksRead = topdownStats.chunksRead,
            .area = topdownStats.area,
            .seconds = seconds(topdownStats.duration),
            .workerSeconds = .of(topdownStats.pipeline),
        },
        .isometric = if (isometricStats) |stats| .{
            .style = try std.fmt.allocPrint(arena, "{f}", .{theme.isometric}),
            .tiles = stats.tiles,
            .levels = stats.levels,
            .chunksRead = stats.chunksRead,
            .seconds = seconds(stats.duration),
            .workerSeconds = .of(stats.pipeline),
        } else null,
    };
    try console.print(init.io, "{f}\n", .{std.json.fmt(report, .{ .emit_null_optional_fields = false })});
}

/// What `--json` prints: the render's times and counts.
const Report = struct {
    /// Storymap's version, from build.zig.zon.
    version: []const u8,
    /// The save's file name.
    world: []const u8,
    /// The build mode, as Zig names it.
    build: []const u8,
    threads: usize,
    /// Whether anything was written: not with `--no-write`.
    written: bool,
    /// What the tiles are encoded as: "png", "jpegxl" or "webp".
    format: []const u8,
    /// Every chunk in the save, though a render reads only those it needs.
    chunks: usize,
    seconds: struct {
        /// Loading the prepared blocks, or preparing them.
        blocks: f64,
        /// Opening the save and giving it the blocks.
        open: f64,
        /// The whole render, from reading the options to writing the page.
        total: f64,
    },
    topdown: View,
    isometric: ?View = null,

    const View = struct {
        style: []const u8,
        /// Tiles written at every level, and the levels.
        tiles: usize,
        levels: usize,
        chunksRead: usize,
        /// Block columns drawn at full detail: the map's area in square metres. Top-down only.
        area: ?usize = null,
        /// Drawing, encoding and writing every tile.
        seconds: f64,
        workerSeconds: WorkerSeconds,
    };

    /// Each part of the tile pipeline, summed over all workers (`tiles.Stats`).
    const WorkerSeconds = struct {
        draw: f64,
        filter: f64,
        compress: f64,
        write: f64,
        shrink: f64,

        fn of(stats: tiles.Stats) WorkerSeconds {
            return .{
                .draw = seconds(stats.draw),
                .filter = seconds(stats.filter),
                .compress = seconds(stats.compress),
                .write = seconds(stats.write),
                .shrink = seconds(stats.shrink),
            };
        }
    };
};

fn seconds(duration: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(duration.nanoseconds)) / std.time.ns_per_s;
}

/// The top-down view's tiles, time and surface, and its most common blocks by name.
fn logTopdown(save: *const SaveFile, stats: topdown.Stats) void {
    if (stats.surface) |surface| {
        console.log("top-down: {} tiles in {} levels in {d:.2} s, surface y {}..{}", .{ stats.tiles, stats.levels, seconds(stats.duration), surface.lowest, surface.highest });
    } else {
        console.log("top-down: {} tiles in {} levels in {d:.2} s", .{ stats.tiles, stats.levels, seconds(stats.duration) });
    }
    var buffer: [512]u8 = undefined;
    // A line too long for the buffer is cut short.
    var line: std.Io.Writer = .fixed(&buffer);
    for (stats.commonBlocks, 0..) |common, i| {
        const block = common orelse break;
        const separator = if (i == 0) "" else ",";
        if (save.blockName(block.id)) |code| {
            line.print("{s} {s} {}%", .{ separator, code, block.percent }) catch break;
        } else {
            line.print("{s} #{} {}%", .{ separator, block.id, block.percent }) catch break;
        }
    }
    if (line.buffered().len > 0) console.log("most common surface blocks:{s}", .{line.buffered()});
}

/// The theme `themeName`, with its top-down style replaced by `styleText`, `--style`'s value, if
/// given. A theme or style that can't be used stops the program with a message saying why.
fn loadTheme(init: std.process.Init, themeName: []const u8, styleText: ?[]const u8) Theme {
    const style: ?Style.Name = if (styleText) |text|
        Style.parseName(text) orelse console.fail("`--style`: unknown style {s}. expected: {s}", .{ text, styleNames })
    else
        null;

    var problem: Theme.Problem = .{};
    const theme = Theme.load(init.arena.allocator(), init.io, themeName, style, &problem) catch switch (problem.kind) {
        .unreadable => console.fail("`--theme`: unknown theme {s} ({s}). expected: printed, plain, or a folder with theme.css and theme.js", .{ themeName, @errorName(problem.cause.?) }),
        .stylesheetEndsItsElement => console.fail("{s}/theme.css: contains </style, which would end it early", .{themeName}),
        .scriptEndsItsElement => console.fail("{s}/theme.js: contains </script, which would end it early", .{themeName}),
        .invalidStyle => if (problem.style.line == 0)
            console.fail("{s}/topdown/style.txt: {f}", .{ themeName, problem.style })
        else
            console.fail("{s}/topdown/style.txt:{}: {f}", .{ themeName, problem.style.line, problem.style }),
        .invalidIsometricStyle => if (problem.style.line == 0)
            console.fail("{s}/isometric/style.txt: {f}", .{ themeName, problem.style })
        else
            console.fail("{s}/isometric/style.txt:{}: {f}", .{ themeName, problem.style.line, problem.style }),
    };
    switch (theme.topdown) {
        .game => |gameStyle| if (gameStyle) |name| if (std.meta.stringToEnum(SaveFile.MapStyle, name) == null) {
            if (style != null) console.fail("`--style`: unknown style game:{s}. expected: {s}", .{ name, gameStyles });
            console.fail("{s}/topdown/style.txt: unknown style game:{s}. expected: {s}", .{ themeName, name, gameStyles });
        },
        else => {},
    }
    // The isometric view has one game style, `game`.
    switch (theme.isometric) {
        .game => |gameStyle| if (gameStyle) |name| console.fail("{s}/isometric/style.txt: unknown style game:{s}. expected: {s}, game", .{ themeName, name, Style.storymapNames }),
        else => {},
    }
    return theme;
}

const gameStyles = names: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(SaveFile.MapStyle)) |name| text = text ++ (if (text.len > 0) ", " else "") ++ "game:" ++ name;
    break :names text;
};

const styleNames = Style.storymapNames ++ ", game, " ++ gameStyles;

/// A save that can't be read stops the program with a message saying why.
fn openSaveFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !SaveFile {
    var problem: SaveFile.Problem = .{};
    const save = SaveFile.open(allocator, io, path, &problem) catch |err| switch (err) {
        error.InvalidSaveFile => switch (problem.kind) {
            .unopenable => console.fail("{s}: could not open ({s})", .{ path, @errorName(problem.cause.?) }),
            .notASave => console.fail("{s}: not a Vintage Story save ({s})", .{ path, @errorName(problem.cause.?) }),
            .noChunks => console.fail("{s}: no chunks to draw", .{path}),
            .unreadableBlockList => console.fail("{s}: could not read the block list ({s})", .{ path, @errorName(problem.cause.?) }),
        },
        else => return err,
    };
    if (save.unsaved) console.warn("{s}: unsaved changes won't be on the map (is the game running?)", .{path});
    return save;
}

/// Also names the mods that aren't installed.
fn warnUnknownBlocks(allocator: std.mem.Allocator, prepared: *const Prepared, save: *const SaveFile) !void {
    const unknown = try prepared.unknown(allocator, save.gameData.blockCodes);
    defer allocator.free(unknown.mods);
    for (unknown.mods) |mod| console.warn("mod {s}: not found", .{mod});
    if (unknown.example) |example| console.warn("{} blocks unknown to the game and its mods, e.g. {s}", .{ unknown.codes, example });
}

test "the plain theme draws the game's default style" {
    try std.testing.expectEqual(Style{ .game = null }, Theme.plain.topdown);
}
