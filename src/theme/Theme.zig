//! A theme (docs/themes.md): the stylesheet and script of the viewer page around the map, and
//! the views' styles, `topdown/style.txt` and `isometric/style.txt`.
const Theme = @This();

const std = @import("std");
const Io = std.Io;
pub const Style = @import("style.zig").Style;
const world = @import("world");

/// `theme.css`.
stylesheet: []const u8,
/// `theme.js`.
script: []const u8,
/// `topdown/style.txt`, parsed.
topdown: Style,
/// `isometric/style.txt`, parsed: `relief` draws blocks as cubes in its colours, `game` in the
/// game's textures. Colours it leaves out are the top-down style's.
isometric: Style,

const printedStyle = @embedFile("printed/topdown/style.txt");
const plainStyle = @embedFile("plain/topdown/style.txt");

/// The map as a printed sheet: a neatline, a grid labelled in the margin, a title cartouche and
/// a key of hills for zooming, around a sepia relief map.
pub const printed: Theme = .{
    .stylesheet = @embedFile("printed/theme.css"),
    .script = @embedFile("printed/theme.js"),
    .topdown = printedTopdown,
    .isometric = builtInStyle("printed/isometric", @embedFile("printed/isometric/style.txt"), printedTopdown.relief),
};
const printedTopdown = builtInStyle("printed/topdown", printedStyle, null);

/// The map filling the window, with small panels over it, light or dark with the reader's
/// setting. Short on purpose, as a place to start a theme of one's own.
pub const plain: Theme = .{
    .stylesheet = @embedFile("plain/theme.css"),
    .script = @embedFile("plain/theme.js"),
    .topdown = builtInStyle("plain/topdown", plainStyle, null),
    .isometric = builtInStyle("plain/isometric", @embedFile("plain/isometric/style.txt"), null),
};

pub const builtIn = [_]struct { name: []const u8, theme: Theme, style: []const u8 }{
    .{ .name = "printed", .theme = printed, .style = printedStyle },
    .{ .name = "plain", .theme = plain, .style = plainStyle },
};

/// The colours for those a theme's style leaves out: the Printed theme's, which gives every
/// colour.
pub const defaultColours: world.Palette = printed.topdown.relief;

/// Parsed when compiling. A built-in top-down style gives every colour; an isometric one takes
/// those it leaves out from `defaults`.
fn builtInStyle(comptime path: []const u8, comptime text: []const u8, comptime defaults: ?world.Palette) Style {
    comptime {
        var problem: Style.Problem = .{};
        return Style.parse(text, defaults, null, &problem) catch
            @compileError(std.fmt.comptimePrint("{s}/style.txt:{}: {f}", .{ path, problem.line, problem }));
    }
}

/// The isometric style of a theme without `isometric/style.txt`: its top-down one, with any of
/// the game's styles as `game`, which is the one the isometric view has.
fn isometricOf(topdown: Style) Style {
    return switch (topdown) {
        .relief => topdown,
        .game => .{ .game = null },
    };
}

/// The colours an isometric style leaves out: the top-down style's, if it has any.
fn coloursOf(topdown: Style) world.Palette {
    return switch (topdown) {
        .relief => |palette| palette,
        .game => defaultColours,
    };
}

pub const Problem = struct {
    kind: Kind = .unreadable,
    /// The error behind it, for `unreadable`.
    cause: ?anyerror = null,
    /// What's wrong with `topdown/style.txt` or `isometric/style.txt`, for `invalidStyle` and
    /// `invalidIsometricStyle`.
    style: Style.Problem = .{},

    pub const Kind = enum {
        /// Not a built-in theme, and not a folder with `theme.css` and `theme.js`.
        unreadable,
        /// `theme.css` holds `</style`, which would end its element early once inlined.
        stylesheetEndsItsElement,
        /// `theme.js` holds `</script`, which would end its element early once inlined.
        scriptEndsItsElement,
        invalidStyle,
        invalidIsometricStyle,
    };
};

/// The built-in theme called `name`, or else the theme in the folder at that path. Colours its
/// top-down style leaves out are `defaultColours`; a folder without `topdown/style.txt` draws
/// the map as Printed does, and one without `isometric/style.txt` the isometric view in its
/// top-down style (`isometricOf`). `style` replaces the top-down style its file names.
pub fn load(arena: std.mem.Allocator, io: Io, name: []const u8, style: ?Style.Name, problem: *Problem) error{InvalidTheme}!Theme {
    for (builtIn) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (style == null) return entry.theme;
        var theme = entry.theme;
        theme.topdown = Style.parse(entry.style, defaultColours, style, &problem.style) catch return fail(problem, .invalidStyle);
        return theme;
    }
    return loadFolder(arena, io, name, style, problem) catch |err| switch (err) {
        error.InvalidTheme => return error.InvalidTheme,
        else => {
            problem.* = .{ .kind = .unreadable, .cause = err };
            return error.InvalidTheme;
        },
    };
}

fn loadFolder(arena: std.mem.Allocator, io: Io, path: []const u8, style: ?Style.Name, problem: *Problem) !Theme {
    var folder = try Io.Dir.cwd().openDir(io, path, .{});
    defer folder.close(io);
    const stylesheet = try folder.readFileAlloc(io, "theme.css", arena, .limited(16 << 20));
    const script = try folder.readFileAlloc(io, "theme.js", arena, .limited(16 << 20));
    if (std.mem.indexOf(u8, stylesheet, "</style") != null) return fail(problem, .stylesheetEndsItsElement);
    if (std.mem.indexOf(u8, script, "</script") != null) return fail(problem, .scriptEndsItsElement);

    const text = folder.readFileAlloc(io, "topdown/style.txt", arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => printedStyle,
        else => return err,
    };
    const topdown = Style.parse(text, defaultColours, style, &problem.style) catch return fail(problem, .invalidStyle);
    const isometric = if (folder.readFileAlloc(io, "isometric/style.txt", arena, .limited(1 << 20))) |isometricText|
        Style.parse(isometricText, coloursOf(topdown), null, &problem.style) catch return fail(problem, .invalidIsometricStyle)
    else |err| switch (err) {
        error.FileNotFound => isometricOf(topdown),
        else => return err,
    };
    return .{ .stylesheet = stylesheet, .script = script, .topdown = topdown, .isometric = isometric };
}

fn fail(problem: *Problem, kind: Problem.Kind) error{InvalidTheme} {
    problem.kind = kind;
    return error.InvalidTheme;
}

test {
    _ = Style;
}

test "the built-in isometric styles" {
    try std.testing.expectEqualDeep(Style{ .relief = printed.topdown.relief }, printed.isometric);
    try std.testing.expectEqualDeep(Style{ .game = null }, plain.isometric);
}

test isometricOf {
    try std.testing.expectEqualDeep(Style{ .game = null }, isometricOf(.{ .game = "coloured" }));
    try std.testing.expectEqualDeep(printed.topdown, isometricOf(printed.topdown));
}

test "the built-in themes can be inlined" {
    for (builtIn) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.theme.stylesheet, "</style") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.theme.script, "</script") == null);
    }
}
