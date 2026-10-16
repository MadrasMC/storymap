//! The map viewer: `index.html` and `map.json`, written next to the tiles. The page is
//! `viewer.html` with the map's description inlined, because a browser opening it straight
//! from the disk won't let it fetch `map.json` beside it. `map.json` is for other tools.
const std = @import("std");
const Io = std.Io;
const tiles = @import("tiles.zig");

const template = @embedFile("viewer.html");
/// Where the page expects the map's description. The template leaves it null, which the page
/// shows as a missing map.
const marker = "<script id=\"map-data\" type=\"application/json\">null</script>";

/// The world a map shows.
pub const World = struct {
    name: []const u8,
    /// In blocks, east to west and north to south. The game shows positions relative to the
    /// world's centre, so the viewer needs these to match it.
    width: u64,
    length: u64,
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

/// Writes `map.json` and `index.html` into `folder`.
pub fn write(allocator: std.mem.Allocator, io: Io, folder: Io.Dir, world: World, views: []const View) !void {
    const json = try describe(allocator, world, views);
    defer allocator.free(json);
    try folder.writeFile(io, .{ .sub_path = "map.json", .data = json });

    // "</" would end the script element early, and "<\/" means the same in JSON.
    const inlined = try std.mem.replaceOwned(u8, allocator, json, "</", "<\\/");
    defer allocator.free(inlined);
    const at = std.mem.indexOf(u8, template, marker) orelse return error.ViewerTemplateHasNoMarker;
    const page = try std.mem.concat(allocator, u8, &.{
        template[0..at],
        "<script id=\"map-data\" type=\"application/json\">",
        inlined,
        "</script>",
        template[at + marker.len ..],
    });
    defer allocator.free(page);
    try folder.writeFile(io, .{ .sub_path = "index.html", .data = page });
}

/// The map's description as JSON. Each view lists the tiles of each level as flat x, y pairs,
/// so the viewer only asks for tiles that exist.
fn describe(allocator: std.mem.Allocator, world: World, views: []const View) ![]u8 {
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
    return std.json.Stringify.valueAlloc(allocator, .{ .world = world, .views = jsonViews }, .{});
}

test describe {
    const written = [_]tiles.Written{
        .{ .level = 0, .tile = .{ .x = 1000, .y = 999 } },
        .{ .level = 0, .tile = .{ .x = 1000, .y = 1000 } },
        .{ .level = 1, .tile = .{ .x = 500, .y = 499 } },
    };
    const json = try describe(std.testing.allocator, .{ .name = "A </script> world", .width = 1024000, .length = 1024000 }, &.{
        .{ .name = "topdown", .title = "Top-down", .projection = "topdown", .written = &written },
    });
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"world":{"name":"A </script> world","width":1024000,"length":1024000},"views":[{"name":"topdown","title":"Top-down","projection":"topdown","tileSize":512,"tiles":[[1000,999,1000,1000],[500,499]]}]}
    , json);
}

test "the template has the marker" {
    try std.testing.expect(std.mem.indexOf(u8, template, marker) != null);
}
