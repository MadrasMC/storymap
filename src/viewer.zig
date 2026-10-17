//! The map viewer: `index.html` and `map.json`, written next to the tiles. The page is
//! `viewer.html`, the map itself, with a theme drawing everything around it, and with the
//! theme and the map's description inlined, because a browser opening it straight from the
//! disk won't let it fetch files beside it. `map.json` is for other tools.
const std = @import("std");
const Io = std.Io;
const tiles = @import("tiles.zig");

const template = @embedFile("viewer.html");
/// Where the page expects the map's description. The template leaves it null, which the page
/// shows as a missing map.
const marker = "<script id=\"map-data\" type=\"application/json\">null</script>";
/// Where the page expects its theme's stylesheet and script.
const styleMarker = "<style id=\"theme-style\"></style>";
const scriptMarker = "<script id=\"theme-script\"></script>";

/// A theme: the stylesheet and script that draw everything around the map, as described in
/// `docs/themes.md`.
pub const Theme = struct {
    style: []const u8,
    script: []const u8,
};

/// The map as a printed sheet: a neatline, a grid labelled in the margin, a title cartouche and
/// a key of hills for zooming.
pub const printed: Theme = .{
    .style = @embedFile("themes/printed/theme.css"),
    .script = @embedFile("themes/printed/theme.js"),
};

/// The map filling the window, with small panels over it, light or dark with the reader's
/// setting. Short on purpose, as a place to start a theme of one's own.
pub const plain: Theme = .{
    .style = @embedFile("themes/plain/theme.css"),
    .script = @embedFile("themes/plain/theme.js"),
};

/// The themes built into Storymap, by the name `--theme` takes.
pub const themes = [_]struct { name: []const u8, theme: Theme }{
    .{ .name = "printed", .theme = printed },
    .{ .name = "plain", .theme = plain },
};

/// The built-in theme called `name`, or else the theme in the folder at that path: its
/// `theme.css` and `theme.js`, read with `arena` and kept for the render.
pub fn loadTheme(arena: std.mem.Allocator, io: Io, name: []const u8) !Theme {
    for (themes) |builtIn| {
        if (std.mem.eql(u8, builtIn.name, name)) return builtIn.theme;
    }
    var folder = try Io.Dir.cwd().openDir(io, name, .{});
    defer folder.close(io);
    const theme: Theme = .{
        .style = try folder.readFileAlloc(io, "theme.css", arena, .limited(16 << 20)),
        .script = try folder.readFileAlloc(io, "theme.js", arena, .limited(16 << 20)),
    };
    // Either closing tag would end its element early once the theme is inlined.
    if (std.mem.indexOf(u8, theme.style, "</style") != null) return error.ThemeStyleEndsItsElement;
    if (std.mem.indexOf(u8, theme.script, "</script") != null) return error.ThemeScriptEndsItsElement;
    return theme;
}

/// The game a map's world is from, e.g. "Vintage Story", and the version that last saved the
/// world, e.g. "1.22.7".
pub const Game = struct {
    name: []const u8,
    version: []const u8,
};

/// The world a map shows.
pub const World = struct {
    name: []const u8,
    /// The block the game shows as position 0, 0, so the viewer shows positions as the game
    /// does: x east, z south.
    origin: struct { x: i64, z: i64 },
};

/// One view's tiles, as the pipeline wrote them.
pub const View = struct {
    /// Its folder, e.g. "topdown".
    name: []const u8,
    title: []const u8,
    /// How the viewer turns a level-0 pixel into a block position: "topdown" is one pixel per
    /// block, pixel x and y being block x and z.
    projection: []const u8,
    written: []const tiles.Written,
};

/// Writes `map.json` and `index.html` into `folder`, the page drawn with `theme`. `rendered` is
/// when, in seconds since 1970 (UTC).
pub fn write(allocator: std.mem.Allocator, io: Io, folder: Io.Dir, game: Game, world: World, rendered: i64, views: []const View, theme: Theme) !void {
    var buffer: [24]u8 = undefined;
    const json = try describe(allocator, game, world, utc(&buffer, rendered), views);
    defer allocator.free(json);
    try folder.writeFile(io, .{ .sub_path = "map.json", .data = json });

    // "</" would end the script element early, and "<\/" means the same in JSON.
    const inlined = try std.mem.replaceOwned(u8, allocator, json, "</", "<\\/");
    defer allocator.free(inlined);
    // The theme goes in first: it's ours, while the description holds the world's name, which
    // could contain anything.
    const themed = try fill(allocator, template, styleMarker, &.{ "<style id=\"theme-style\">", theme.style, "</style>" });
    defer allocator.free(themed);
    const scripted = try fill(allocator, themed, scriptMarker, &.{ "<script id=\"theme-script\">", theme.script, "</script>" });
    defer allocator.free(scripted);
    const page = try fill(allocator, scripted, marker, &.{ "<script id=\"map-data\" type=\"application/json\">", inlined, "</script>" });
    defer allocator.free(page);
    try folder.writeFile(io, .{ .sub_path = "index.html", .data = page });
}

/// `page` with its first `wanted` swapped for `parts`, joined.
fn fill(allocator: std.mem.Allocator, page: []const u8, wanted: []const u8, parts: []const []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, page, wanted) orelse return error.ViewerTemplateHasNoMarker;
    var pieces: [8][]const u8 = undefined;
    pieces[0] = page[0..at];
    @memcpy(pieces[1..][0..parts.len], parts);
    pieces[1 + parts.len] = page[at + wanted.len ..];
    return std.mem.concat(allocator, u8, pieces[0 .. parts.len + 2]);
}

/// A time as an ISO 8601 UTC timestamp, which browsers read as it is, e.g.
/// "2026-10-17T09:05:00Z".
fn utc(buffer: *[24]u8, seconds: i64) []const u8 {
    const clamped: u64 = @intCast(@max(seconds, 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = clamped };
    const yearDay = epoch.getEpochDay().calculateYearDay();
    const monthDay = yearDay.calculateMonthDay();
    const daySeconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yearDay.year,                 monthDay.month.numeric(),        monthDay.day_index + 1,
        daySeconds.getHoursIntoDay(), daySeconds.getMinutesIntoHour(), daySeconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

test utc {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", utc(&buffer, 0));
    // 2026-10-17 09:05:07 UTC.
    try std.testing.expectEqualStrings("2026-10-17T09:05:07Z", utc(&buffer, 1792227907));
}

/// The map's description as JSON. Each view lists the tiles of each level as flat x, y pairs,
/// so the viewer only asks for tiles that exist.
fn describe(allocator: std.mem.Allocator, game: Game, world: World, rendered: []const u8, views: []const View) ![]u8 {
    const JsonView = struct {
        name: []const u8,
        title: []const u8,
        projection: []const u8,
        tileSize: usize,
        tiles: []const []const i32,
    };
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const jsonViews = try arena.allocator().alloc(JsonView, views.len);
    for (jsonViews, views) |*out, view| {
        var levels: usize = 0;
        for (view.written) |w| levels = @max(levels, @as(usize, w.level) + 1);
        const perLevel = try arena.allocator().alloc(std.ArrayList(i32), levels);
        @memset(perLevel, .empty);
        for (view.written) |w| try perLevel[w.level].appendSlice(arena.allocator(), &.{ w.tile.x, w.tile.y });
        const flat = try arena.allocator().alloc([]const i32, levels);
        for (flat, perLevel) |*level, list| level.* = list.items;
        out.* = .{ .name = view.name, .title = view.title, .projection = view.projection, .tileSize = tiles.size, .tiles = flat };
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .game = game, .world = world, .rendered = rendered, .views = jsonViews }, .{});
}

test describe {
    const written = [_]tiles.Written{
        .{ .level = 0, .tile = .{ .x = 1000, .y = 999 } },
        .{ .level = 0, .tile = .{ .x = 1000, .y = 1000 } },
        .{ .level = 1, .tile = .{ .x = 500, .y = 499 } },
    };
    const json = try describe(std.testing.allocator, .{ .name = "Vintage Story", .version = "1.22.7" }, .{ .name = "A </script> world", .origin = .{ .x = 512000, .z = 512000 } }, "2026-10-17T09:05:07Z", &.{
        .{ .name = "topdown", .title = "Top-down", .projection = "topdown", .written = &written },
    });
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"game":{"name":"Vintage Story","version":"1.22.7"},"world":{"name":"A </script> world","origin":{"x":512000,"z":512000}},"rendered":"2026-10-17T09:05:07Z","views":[{"name":"topdown","title":"Top-down","projection":"topdown","tileSize":512,"tiles":[[1000,999,1000,1000],[500,499]]}]}
    , json);
}

test "the template has the markers" {
    for ([_][]const u8{ marker, styleMarker, scriptMarker }) |wanted| {
        try std.testing.expect(std.mem.indexOf(u8, template, wanted) != null);
    }
}

test "the built-in themes can be inlined" {
    // Either closing tag would end its element early.
    for (themes) |builtIn| {
        try std.testing.expect(std.mem.indexOf(u8, builtIn.theme.style, "</style") == null);
        try std.testing.expect(std.mem.indexOf(u8, builtIn.theme.script, "</script") == null);
    }
}
