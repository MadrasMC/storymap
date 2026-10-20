//! A theme, as described in `docs/themes.md`: a folder holding the stylesheet and script that
//! draw the viewer page around the map, and how the map itself is coloured. Its files are kept
//! as they are; the viewer inlines the first two into the page, and the renderer's style reads
//! the third.
const Theme = @This();

const std = @import("std");
const Io = std.Io;

/// `theme.css`.
style: []const u8,
/// `theme.js`.
script: []const u8,
/// `topdown/style.txt`: the map's colours.
topdown: []const u8,

/// The map as a printed sheet: a neatline, a grid labelled in the margin, a title cartouche and
/// a key of hills for zooming, around a sepia relief map.
pub const printed: Theme = .{
    .style = @embedFile("printed/theme.css"),
    .script = @embedFile("printed/theme.js"),
    .topdown = @embedFile("printed/topdown/style.txt"),
};

/// The map filling the window, with small panels over it, light or dark with the reader's
/// setting. Short on purpose, as a place to start a theme of one's own.
pub const plain: Theme = .{
    .style = @embedFile("plain/theme.css"),
    .script = @embedFile("plain/theme.js"),
    .topdown = @embedFile("plain/topdown/style.txt"),
};

/// The themes built into Storymap, by the name `--theme` takes.
pub const builtIn = [_]struct { name: []const u8, theme: Theme }{
    .{ .name = "printed", .theme = printed },
    .{ .name = "plain", .theme = plain },
};

/// The built-in theme called `name`, or else the theme in the folder at that path: its
/// `theme.css`, `theme.js` and `topdown/style.txt`, read with `arena` and kept for the render.
/// A folder without `topdown/style.txt` colours the map as the Printed theme does.
pub fn load(arena: std.mem.Allocator, io: Io, name: []const u8) !Theme {
    for (builtIn) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.theme;
    }
    var folder = try Io.Dir.cwd().openDir(io, name, .{});
    defer folder.close(io);
    const theme: Theme = .{
        .style = try folder.readFileAlloc(io, "theme.css", arena, .limited(16 << 20)),
        .script = try folder.readFileAlloc(io, "theme.js", arena, .limited(16 << 20)),
        .topdown = folder.readFileAlloc(io, "topdown/style.txt", arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => printed.topdown,
            else => return err,
        },
    };
    // Either closing tag would end its element early once the theme is inlined.
    if (std.mem.indexOf(u8, theme.style, "</style") != null) return error.ThemeStyleEndsItsElement;
    if (std.mem.indexOf(u8, theme.script, "</script") != null) return error.ThemeScriptEndsItsElement;
    return theme;
}

test "the built-in themes can be inlined" {
    // Either closing tag would end its element early.
    for (builtIn) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.theme.style, "</style") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.theme.script, "</script") == null);
    }
}
