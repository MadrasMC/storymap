//! A theme, as described in `docs/themes.md`: a folder holding the stylesheet and script that
//! draw the viewer page around the map, which the viewer inlines into the page, and how the
//! map itself is coloured, its `topdown/style.txt`, for the renderer.
const Theme = @This();

const std = @import("std");
const Io = std.Io;
pub const Style = @import("style.zig").Style;
const world = @import("world");

/// `theme.css`.
stylesheet: []const u8,
/// `theme.js`.
script: []const u8,
/// `topdown/style.txt`, parsed: the map's colours.
topdown: Style,

/// The map as a printed sheet: a neatline, a grid labelled in the margin, a title cartouche and
/// a key of hills for zooming, around a sepia relief map.
pub const printed: Theme = .{
    .stylesheet = @embedFile("printed/theme.css"),
    .script = @embedFile("printed/theme.js"),
    .topdown = builtInStyle("printed", @embedFile("printed/topdown/style.txt")),
};

/// The map filling the window, with small panels over it, light or dark with the reader's
/// setting. Short on purpose, as a place to start a theme of one's own.
pub const plain: Theme = .{
    .stylesheet = @embedFile("plain/theme.css"),
    .script = @embedFile("plain/theme.js"),
    .topdown = builtInStyle("plain", @embedFile("plain/topdown/style.txt")),
};

/// The themes built into Storymap, by the name `--theme` takes.
pub const builtIn = [_]struct { name: []const u8, theme: Theme }{
    .{ .name = "printed", .theme = printed },
    .{ .name = "plain", .theme = plain },
};

/// A built-in theme's style, parsed when compiling. A Storymap style gives every colour, so it
/// doesn't depend on any game's.
fn builtInStyle(comptime name: []const u8, comptime text: []const u8) Style {
    comptime {
        var problem: Style.Problem = .{};
        return Style.parse(text, null, &problem) catch
            @compileError(std.fmt.comptimePrint("{s}/topdown/style.txt:{}: {f}", .{ name, problem.line, problem }));
    }
}

/// Why a theme can't be loaded, for a message.
pub const Problem = struct {
    kind: Kind = .unreadable,
    /// The error behind it, for `unreadable`.
    cause: ?anyerror = null,
    /// What's wrong with `topdown/style.txt`, for `invalidStyle`.
    style: Style.Problem = .{},

    pub const Kind = enum {
        /// Not a built-in theme, and not a folder with `theme.css` and `theme.js`.
        unreadable,
        /// `theme.css` holds `</style`, which would end its element early once inlined.
        stylesheetEndsItsElement,
        /// `theme.js` holds `</script`, which would end its element early once inlined.
        scriptEndsItsElement,
        invalidStyle,
    };
};

/// The built-in theme called `name`, or else the theme in the folder at that path: its
/// `theme.css`, `theme.js` and `topdown/style.txt`, read with `arena` and kept for the render.
/// The colours its style leaves out come from `defaults`, such as the game's own palette, and a
/// folder without `topdown/style.txt` colours the map as the Printed theme does. If it can't be
/// loaded, returns error.InvalidTheme and `problem` says why.
pub fn load(arena: std.mem.Allocator, io: Io, name: []const u8, defaults: ?world.Palette, problem: *Problem) error{InvalidTheme}!Theme {
    for (builtIn) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.theme;
    }
    return loadFolder(arena, io, name, defaults, problem) catch |err| switch (err) {
        error.InvalidTheme => return error.InvalidTheme,
        else => {
            problem.* = .{ .kind = .unreadable, .cause = err };
            return error.InvalidTheme;
        },
    };
}

fn loadFolder(arena: std.mem.Allocator, io: Io, path: []const u8, defaults: ?world.Palette, problem: *Problem) !Theme {
    var folder = try Io.Dir.cwd().openDir(io, path, .{});
    defer folder.close(io);
    const stylesheet = try folder.readFileAlloc(io, "theme.css", arena, .limited(16 << 20));
    const script = try folder.readFileAlloc(io, "theme.js", arena, .limited(16 << 20));
    // Either closing tag would end its element early once the theme is inlined.
    if (std.mem.indexOf(u8, stylesheet, "</style") != null) return fail(problem, .stylesheetEndsItsElement);
    if (std.mem.indexOf(u8, script, "</script") != null) return fail(problem, .scriptEndsItsElement);

    const text = folder.readFileAlloc(io, "topdown/style.txt", arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .stylesheet = stylesheet, .script = script, .topdown = printed.topdown },
        else => return err,
    };
    const topdown = Style.parse(text, defaults, &problem.style) catch return fail(problem, .invalidStyle);
    return .{ .stylesheet = stylesheet, .script = script, .topdown = topdown };
}

fn fail(problem: *Problem, kind: Problem.Kind) error{InvalidTheme} {
    problem.kind = kind;
    return error.InvalidTheme;
}

test {
    _ = Style;
}

test "the built-in themes can be inlined" {
    // Either closing tag would end its element early.
    for (builtIn) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.theme.stylesheet, "</style") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.theme.script, "</script") == null);
    }
}
