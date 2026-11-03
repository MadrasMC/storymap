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
        .{ .name = "views", .value = "views", .description = "Which views to draw, joined by +: topdown (the default), isometric, or isometric@rotations, of 0, 90, 180 and 270 joined by commas." },
        .{ .name = "clip", .value = "shape", .description = "Draw only part of the world, around a position as the game shows it: circle:radius@x,z, square:side@x,z or rect:widthxheight@x,z, in blocks, or between two corners, rect:x,z..x,z." },
        .{ .name = "name", .value = "name", .description = "The world's name on the page, instead of the save's." },
        .{ .name = "season", .value = "season", .description = "Tint grass and leaves for spring, summer, fall or winter, instead of the season on the save's date." },
        .{ .name = "jpegxl", .description = "Encode the tiles as lossless JPEG XL instead of PNG, which not every browser shows." },
        .{ .name = "webp", .description = "Encode the tiles as lossless WebP instead of PNG." },
        .{ .name = "lossy-from", .value = "level", .description = "With --webp, encode the tiles from this level up as lossy WebP: level 0 is full detail, 2 where blocks are 8 pixels wide." },
        .{ .name = "no-write", .description = "Draw and encode the tiles without writing anything, to time the rest." },
        .{ .name = "json", .description = "Print the render's times and counts on stdout as one line of JSON, for scripts." },
        .{ .name = "prepare", .description = "Prepare the blocks again, even if they were prepared before." },
        .{ .name = "blocks", .value = "file", .description = "The prepared blocks file: prepared.storyblk by default." },
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
    \\What the map needs from the game's and mods' assets is prepared once into the prepared
    \\blocks file, the first time a render needs it, or again with --prepare; prepare does only
    \\that.
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
    const area: ?SaveFile.Area = if (parsed.value("clip")) |text|
        parseClip(text) orelse console.fail("`--clip`: invalid clip {s}. expected: circle:radius@x,z, square:side@x,z, rect:widthxheight@x,z or rect:x,z..x,z", .{text})
    else
        null;
    const chosen: Views = if (parsed.value("views")) |text|
        parseViews(text) orelse console.fail("`--views`: invalid views {s}. expected: topdown, isometric or isometric@0,90,180,270, joined by +", .{text})
    else
        .{ .topdown = true };
    const paths: prepare.Paths = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.value("blocks") orelse Prepared.defaultPath,
    };
    const force = parsed.flag("prepare");
    const write = !parsed.flag("no-write");
    const theme = loadTheme(init, themeName, parsed.value("style"));

    const out: ?std.Io.Dir = if (write) std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err|
        console.fail("{s}: could not create ({s})", .{ outPath, @errorName(err) }) else null;
    defer if (out) |dir| dir.close(init.io);
    if (parsed.flag("jpegxl") and parsed.flag("webp")) console.fail("`--jpegxl` and `--webp`: choose one", .{});
    const format: tiles.Format = if (parsed.flag("jpegxl")) .jpegxl else if (parsed.flag("webp")) .webp else .png;
    const lossyFrom: ?u8 = if (parsed.value("lossy-from")) |text| level: {
        if (format != .webp) console.fail("`--lossy-from`: only with `--webp`", .{});
        break :level std.fmt.parseInt(u8, text, 10) catch console.fail("`--lossy-from`: invalid level {s}. expected: a level from 0", .{text});
    } else null;
    const output: tiles.Output = .{ .folder = out, .format = format, .lossyFrom = lossyFrom };

    const loading: std.Io.Timestamp = .now(init.io, .awake);
    var prepared = prepare.blocks(init, paths, force);
    defer if (prepared) |*blocks| blocks.deinit(init.io);
    const blocksTime = loading.untilNow(init.io, .awake);

    const opening: std.Io.Timestamp = .now(init.io, .awake);
    var save = try openSaveFile(allocator, init.io, savePath, area);
    defer save.close(allocator);
    if (season) |drawn| save.seasonProgress = drawn.progress();
    if (prepared) |*blocks| {
        try warnUnknownBlocks(allocator, &blocks.prepared, &save);
        save.useBlocks(&blocks.prepared);
    }
    const openTime = opening.untilNow(init.io, .awake);

    var views: std.ArrayList(viewer.View) = .empty;
    defer views.deinit(allocator);

    var topdownStats: ?topdown.Stats = null;
    const writtenTopdown = if (chosen.topdown) list: {
        topdownStats = .{};
        break :list try topdown.render(SaveFile, allocator, init.io, &save, output, .{ .style = theme.topdown }, &topdownStats.?);
    } else null;
    defer if (writtenTopdown) |list| allocator.free(list);
    if (topdownStats) |stats| logTopdown(&save, stats);
    if (writtenTopdown) |list| try views.append(allocator, .{ .name = topdown.folder, .title = topdown.title, .projection = topdown.projection, .format = output.format, .written = list });

    var isometricStats: [isometric.Sprites.rotationCount]?isometric.Stats = @splat(null);
    var writtenIsometric: [isometric.Sprites.rotationCount]?[]tiles.Written = @splat(null);
    defer for (writtenIsometric) |written| if (written) |list| allocator.free(list);
    for (chosen.rotations, std.enums.values(isometric.Rotation), &isometricStats, &writtenIsometric) |wanted, rotation, *rotationStats, *written| {
        if (!wanted) continue;
        var stats: isometric.Stats = .{};
        const sprites = if (prepared) |*blocks| &blocks.sprites else null;
        const list = try isometric.render(SaveFile, allocator, init.io, &save, output, .{ .style = theme.isometric, .sprites = sprites, .rotation = rotation }, &stats);
        written.* = list;
        rotationStats.* = stats;
        console.log("{s}: {} tiles in {} levels in {d:.2} s, {} chunks read", .{ rotation.folder(), stats.tiles, stats.levels, seconds(stats.duration), stats.chunksRead });
        try views.append(allocator, .{ .name = rotation.folder(), .title = rotation.title(), .projection = isometric.projection, .blockWidth = isometric.blockWidth, .rotation = rotation.degrees(), .format = output.format, .written = list });
    }

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
    const isometricStyle = try std.fmt.allocPrint(arena, "{f}", .{theme.isometric});
    const report: Report = .{
        .version = build_options.version,
        .world = std.fs.path.basename(savePath),
        .build = @tagName(builtin.mode),
        .threads = std.Thread.getCpuCount() catch 1,
        .written = write,
        .format = @tagName(output.format),
        .chunks = try save.countChunks(),
        .seconds = .{ .blocks = seconds(blocksTime), .open = seconds(openTime), .total = seconds(total) },
        .topdown = if (topdownStats) |stats| .{
            .style = try std.fmt.allocPrint(arena, "{f}", .{theme.topdown}),
            .tiles = stats.tiles,
            .levels = stats.levels,
            .chunksRead = stats.chunksRead,
            .area = stats.area,
            .seconds = seconds(stats.duration),
            .workerSeconds = .of(stats.pipeline),
        } else null,
        .isometric = .ofIsometric(isometricStyle, isometricStats[0]),
        .@"isometric-90" = .ofIsometric(isometricStyle, isometricStats[1]),
        .@"isometric-180" = .ofIsometric(isometricStyle, isometricStats[2]),
        .@"isometric-270" = .ofIsometric(isometricStyle, isometricStats[3]),
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
    topdown: ?View = null,
    isometric: ?View = null,
    @"isometric-90": ?View = null,
    @"isometric-180": ?View = null,
    @"isometric-270": ?View = null,

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

        fn ofIsometric(style: []const u8, drawn: ?isometric.Stats) ?View {
            const stats = drawn orelse return null;
            return .{
                .style = style,
                .tiles = stats.tiles,
                .levels = stats.levels,
                .chunksRead = stats.chunksRead,
                .seconds = seconds(stats.duration),
                .workerSeconds = .of(stats.pipeline),
            };
        }
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

/// The views `--views` names.
const Views = struct {
    topdown: bool = false,
    /// Which of the isometric view's rotations, by quarter turn from 0.
    rotations: [4]bool = @splat(false),
};

/// The views `--views` names, or null if it isn't a list of them. One named twice is one view.
fn parseViews(text: []const u8) ?Views {
    var views: Views = .{};
    var names = std.mem.splitScalar(u8, text, '+');
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "topdown")) {
            views.topdown = true;
        } else if (std.mem.eql(u8, name, "isometric")) {
            views.rotations[0] = true;
        } else if (std.mem.startsWith(u8, name, "isometric@")) {
            var rotations = std.mem.splitScalar(u8, name["isometric@".len..], ',');
            while (rotations.next()) |rotation| {
                const degrees = std.fmt.parseInt(u16, rotation, 10) catch return null;
                if (degrees % 90 != 0 or degrees >= 360) return null;
                views.rotations[degrees / 90] = true;
            }
        } else return null;
    }
    return views;
}

test parseViews {
    try std.testing.expectEqual(Views{ .topdown = true }, parseViews("topdown").?);
    const front: Views = .{ .rotations = .{ true, false, false, false } };
    try std.testing.expectEqual(front, parseViews("isometric").?);
    try std.testing.expectEqual(front, parseViews("isometric@0").?);
    try std.testing.expectEqual(Views{ .topdown = true, .rotations = .{ true, false, false, false } }, parseViews("topdown+isometric").?);
    try std.testing.expectEqual(Views{ .rotations = .{ false, true, false, false } }, parseViews("isometric@90").?);
    try std.testing.expectEqual(Views{ .rotations = .{ true, true, true, true } }, parseViews("isometric@0,90,180,270").?);
    try std.testing.expectEqual(Views{ .rotations = .{ true, false, true, false } }, parseViews("isometric@0+isometric@180").?);
    // Named twice, one view.
    try std.testing.expectEqual(Views{ .topdown = true }, parseViews("topdown+topdown").?);
    try std.testing.expectEqual(front, parseViews("isometric@0,0+isometric").?);
    for ([_][]const u8{ "", "+", "topdown+", "side", "topdown@90", "isometric@", "isometric@45", "isometric@360", "isometric@-90", "isometric@90,", "Isometric" }) |text| {
        try std.testing.expectEqual(null, parseViews(text));
    }
}

/// The area `--clip` names, or null if it isn't one.
fn parseClip(text: []const u8) ?SaveFile.Area {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    if (std.mem.indexOf(u8, text, "..")) |dots| {
        if (!std.mem.eql(u8, text[0..colon], "rect") or dots < colon) return null;
        return rectBetween(parsePosition(text[colon + 1 .. dots]) orelse return null, parsePosition(text[dots + 2 ..]) orelse return null);
    }
    const at = std.mem.indexOfScalarPos(u8, text, colon, '@') orelse return null;
    const size = text[colon + 1 .. at];
    const position = parsePosition(text[at + 1 ..]) orelse return null;
    const shape: SaveFile.Area.Shape = if (std.mem.eql(u8, text[0..colon], "circle"))
        .{ .circle = std.fmt.parseInt(u32, size, 10) catch return null }
    else if (std.mem.eql(u8, text[0..colon], "rect")) rect: {
        const by = std.mem.indexOfScalar(u8, size, 'x') orelse return null;
        const width = std.fmt.parseInt(u32, size[0..by], 10) catch return null;
        const height = std.fmt.parseInt(u32, size[by + 1 ..], 10) catch return null;
        if (width == 0 or height == 0) return null;
        break :rect .{ .rect = .{ .width = width, .height = height } };
    } else if (std.mem.eql(u8, text[0..colon], "square")) square: {
        const side = std.fmt.parseInt(u32, size, 10) catch return null;
        if (side == 0) return null;
        break :square .{ .rect = .{ .width = side, .height = side } };
    } else return null;
    return .{ .x = position[0], .z = position[1], .shape = shape };
}

/// Position x,z, or null if it isn't one.
fn parsePosition(text: []const u8) ?[2]i64 {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    return .{
        std.fmt.parseInt(i64, text[0..comma], 10) catch return null,
        std.fmt.parseInt(i64, text[comma + 1 ..], 10) catch return null,
    };
}

/// The rectangle with these opposite corners, both in it; null if it's too large to name.
fn rectBetween(a: [2]i64, b: [2]i64) ?SaveFile.Area {
    const west = @min(a[0], b[0]);
    const north = @min(a[1], b[1]);
    const width = std.math.cast(u32, @abs(a[0] - b[0]) + 1) orelse return null;
    const height = std.math.cast(u32, @abs(a[1] - b[1]) + 1) orelse return null;
    return .{ .x = west + width / 2, .z = north + height / 2, .shape = .{ .rect = .{ .width = width, .height = height } } };
}

test parseClip {
    try std.testing.expectEqual(SaveFile.Area{ .x = 220, .z = -5997, .shape = .{ .circle = 100 } }, parseClip("circle:100@220,-5997").?);
    try std.testing.expectEqual(SaveFile.Area{ .x = -1, .z = 2, .shape = .{ .rect = .{ .width = 300, .height = 100 } } }, parseClip("rect:300x100@-1,2").?);
    try std.testing.expectEqual(SaveFile.Area{ .x = 0, .z = 0, .shape = .{ .rect = .{ .width = 200, .height = 200 } } }, parseClip("square:200@0,0").?);
    // Corners, both in it, in any order: 5 by 3 blocks, from x 10 to 14 and z -3 to -1.
    const corners: SaveFile.Area = .{ .x = 12, .z = -2, .shape = .{ .rect = .{ .width = 5, .height = 3 } } };
    try std.testing.expectEqual(corners, parseClip("rect:10,-3..14,-1").?);
    try std.testing.expectEqual(corners, parseClip("rect:14,-1..10,-3").?);
    // An even size reaches further west: 10 to 13 is 4 blocks, 2 west of 12.
    try std.testing.expectEqual(SaveFile.Area{ .x = 12, .z = 0, .shape = .{ .rect = .{ .width = 4, .height = 1 } } }, parseClip("rect:10,0..13,0").?);
    for ([_][]const u8{ "circle:1,2..3,4", "rect:1,2..", "rect:..3,4", "rect:1..3,4", "rect:1,2..3,z", "rect:0,0..9999999999,0", "..:1,2", "", "abc", "circle:100", "circle:100@1", "circle:x@1,2", "circle:-1@1,2", "circle:1x2@1,2", "oval:1@1,2", "rect:200@1,2", "rect:0x1@1,2", "rect:1x0@1,2", "rect:1x@1,2", "rect:2x2@1,z", "square:0@1,2", "square:2x2@1,2" }) |text| {
        try std.testing.expectEqual(null, parseClip(text));
    }
}

/// A save that can't be read stops the program with a message saying why.
fn openSaveFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, area: ?SaveFile.Area) !SaveFile {
    var problem: SaveFile.Problem = .{};
    const save = SaveFile.open(allocator, io, path, area, &problem) catch |err| switch (err) {
        error.InvalidSaveFile => switch (problem.kind) {
            .unopenable => console.fail("{s}: could not open ({s})", .{ path, @errorName(problem.cause.?) }),
            .notASave => console.fail("{s}: not a Vintage Story save ({s})", .{ path, @errorName(problem.cause.?) }),
            .noChunks => console.fail("{s}: no chunks to draw", .{path}),
            .noChunksInArea => console.fail("{s}: no chunks to draw in `--clip`", .{path}),
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
