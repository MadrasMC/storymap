//! The map viewer: `index.html` and `map.json`, written next to the tiles. The page is
//! `viewer.html` with the theme and the map's description inlined, as a browser opening it from
//! disk can't fetch files beside it. `map.json` is for other tools.
const std = @import("std");
const Io = std.Io;
const tiles = @import("tiles");
const Theme = @import("theme");
const world = @import("world");

const template = @embedFile("viewer.html");
/// Where the page expects the map's description. The template leaves it null, which the page
/// shows as a missing map.
const marker = "<script id=\"map-data\" type=\"application/json\">null</script>";
const styleMarker = "<style id=\"theme-style\"></style>";
const scriptMarker = "<script id=\"theme-script\"></script>";

/// One view's tiles, as the pipeline wrote them.
pub const View = struct {
    /// Its folder, e.g. "topdown".
    name: []const u8,
    title: []const u8,
    /// How the viewer turns a level-0 pixel into a block position, e.g. "topdown".
    projection: []const u8,
    /// For an isometric view, a block's width in level-0 pixels.
    blockWidth: ?u16 = null,
    written: []const tiles.Written,
};

/// Writes `map.json` and `index.html` into `folder`. `rendered` is the render's Unix time, in
/// seconds.
pub fn write(allocator: std.mem.Allocator, io: Io, folder: Io.Dir, description: world.Description, rendered: i64, views: []const View, theme: Theme) !void {
    var buffer: [24]u8 = undefined;
    const json = try describe(allocator, description, utc(&buffer, rendered), views);
    defer allocator.free(json);
    try folder.writeFile(io, .{ .sub_path = "map.json", .data = json });

    // "</" would end the script element early, and "<\/" means the same in JSON.
    const inlined = try std.mem.replaceOwned(u8, allocator, json, "</", "<\\/");
    defer allocator.free(inlined);
    // The theme goes in first: it's ours, while the description holds the world's name, which
    // could contain anything.
    const themed = try fill(allocator, template, styleMarker, &.{ "<style id=\"theme-style\">", theme.stylesheet, "</style>" });
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
    try std.testing.expectEqualStrings("2026-10-17T09:05:07Z", utc(&buffer, 1792227907));
}

/// The map's description as JSON. Each view lists the tiles of each level as flat x, y pairs,
/// so the viewer only asks for tiles that exist.
fn describe(allocator: std.mem.Allocator, description: world.Description, rendered: []const u8, views: []const View) ![]u8 {
    const JsonView = struct {
        name: []const u8,
        title: []const u8,
        projection: []const u8,
        blockWidth: ?u16,
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
        out.* = .{ .name = view.name, .title = view.title, .projection = view.projection, .blockWidth = view.blockWidth, .tileSize = tiles.size, .tiles = flat };
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .game = description.game,
        .world = .{ .name = description.name, .origin = description.origin, .seaLevel = description.seaLevel },
        .rendered = rendered,
        .views = jsonViews,
    }, .{ .emit_null_optional_fields = false });
}

test describe {
    const written = [_]tiles.Written{
        .{ .level = 0, .tile = .{ .x = 1000, .y = 999 } },
        .{ .level = 0, .tile = .{ .x = 1000, .y = 1000 } },
        .{ .level = 1, .tile = .{ .x = 500, .y = 499 } },
    };
    const json = try describe(std.testing.allocator, .{ .game = .{ .name = "Vintage Story", .version = "1.22.7" }, .name = "A </script> world", .origin = .{ .x = 512000, .z = 512000 }, .seaLevel = 110 }, "2026-10-17T09:05:07Z", &.{
        .{ .name = "topdown", .title = "Top-down", .projection = "topdown", .written = &written },
        .{ .name = "isometric", .title = "Isometric", .projection = "isometric", .blockWidth = 16, .written = written[0..1] },
    });
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"game":{"name":"Vintage Story","version":"1.22.7"},"world":{"name":"A </script> world","origin":{"x":512000,"z":512000},"seaLevel":110},"rendered":"2026-10-17T09:05:07Z","views":[{"name":"topdown","title":"Top-down","projection":"topdown","tileSize":512,"tiles":[[1000,999,1000,1000],[500,499]]},{"name":"isometric","title":"Isometric","projection":"isometric","blockWidth":16,"tileSize":512,"tiles":[[1000,999]]}]}
    , json);
}

test "the template has the markers" {
    for ([_][]const u8{ marker, styleMarker, scriptMarker }) |wanted| {
        try std.testing.expect(std.mem.indexOf(u8, template, wanted) != null);
    }
}
