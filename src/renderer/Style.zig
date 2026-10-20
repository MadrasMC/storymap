//! How a theme colours the top-down map: `topdown/style.txt` in the theme's folder
//! (docs/themes.md#map-colours). A drawing style, and a colour for each map type and for the
//! two inks, one per line; colours left out are the game's own:
//!
//!     # Comments start with #.
//!     style relief
//!     land       #E4D2A0
//!     …
//!     ink        #4A301A
//!     wateredge  #5C462E
const Style = @This();

const std = @import("std");
const columns = @import("columns");
const viewer = @import("viewer");

/// How the colours are used.
pub const Kind = enum {
    /// A relief map: a type's colour is its colour at sea level; lower ground darkens towards
    /// `ink` and higher ground pales, slopes are shaded, liquids darken with depth, and
    /// coastlines are drawn in `wateredge`.
    relief,
    /// As the game draws its own map: each type's colour as it is, whatever the height, with
    /// the game's hill shading, and lakes unshaded with an edge in `wateredge`.
    shaded,
    /// As the game draws its colour-accurate map: each block in its texture's colour, with
    /// grain, and the game's hill shading. A block without a texture takes its type's colour.
    coloured,
};

kind: Kind,
/// Each map type's colour.
colours: std.EnumArray(columns.MapType, Rgb),
/// What low ground darkens towards.
ink: Rgb,
/// Where water meets land.
wateredge: Rgb,

pub const Rgb = columns.Rgb;

/// A style file as written: the colours it leaves out are null, until `complete` fills them
/// with the game's.
pub const File = struct {
    kind: Kind,
    colours: std.EnumArray(columns.MapType, ?Rgb) = .initFill(null),
    ink: ?Rgb = null,
    wateredge: ?Rgb = null,

    /// The style, with what the file leaves out taken from the game's own palette.
    pub fn complete(self: File, game: columns.Palette) Style {
        var style: Style = .{ .kind = self.kind, .colours = undefined, .ink = self.ink orelse game.ink, .wateredge = self.wateredge orelse game.wateredge };
        for (std.enums.values(columns.MapType)) |mapType| style.colours.set(mapType, self.colours.get(mapType) orelse game.colours.get(mapType));
        return style;
    }
};

/// The Printed theme's style, the default.
pub const printed = parsed(viewer.printed.topdown);
/// The plain theme's: the game's own map colours, drawn as the game draws them.
pub const plain = parsed(viewer.plain.topdown);

/// A style parsed when compiling, for the built-in themes. They give every colour, so they
/// don't depend on any game.
pub fn parsed(comptime text: []const u8) Style {
    comptime {
        @setEvalBranchQuota(100_000);
        var problem: Problem = .{};
        const file = parse(text, &problem) catch @compileError(problem.message);
        var palette: columns.Palette = .{
            .colours = undefined,
            .ink = file.ink orelse @compileError("a built-in style has no colour for ink"),
            .wateredge = file.wateredge orelse @compileError("a built-in style has no colour for wateredge"),
        };
        for (std.enums.values(columns.MapType)) |mapType| palette.colours.set(mapType, file.colours.get(mapType) orelse
            @compileError("a built-in style has no colour for " ++ @tagName(mapType)));
        return file.complete(palette);
    }
}

/// What's wrong with a style file, and on which line, for a message.
pub const Problem = struct {
    line: usize = 0,
    message: []const u8 = "",
    /// The entry's name, where it's about one.
    name: []const u8 = "",
};

/// Parses a style file. The style must be named, and each colour may be given once. On an
/// error, `problem` says what's wrong.
pub fn parse(text: []const u8, problem: *Problem) error{InvalidStyle}!File {
    var file: File = .{ .kind = .relief };
    var seenKind = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const name = words.next().?;
        const value = words.next() orelse return fail(problem, number, "has a name but no value", name);
        if (words.next() != null) return fail(problem, number, "has more than a name and a value", name);

        if (std.mem.eql(u8, name, "style")) {
            if (seenKind) return fail(problem, number, "names the style a second time", name);
            file.kind = std.meta.stringToEnum(Kind, value) orelse return fail(problem, number, "names a style that isn't relief, shaded or coloured", value);
            seenKind = true;
            continue;
        }
        const colour = parseColour(value) orelse return fail(problem, number, "has a colour that isn't #RRGGBB", name);
        const slot: *?Rgb = if (std.meta.stringToEnum(columns.MapType, name)) |mapType|
            file.colours.getPtr(mapType)
        else if (std.mem.eql(u8, name, "ink"))
            &file.ink
        else if (std.mem.eql(u8, name, "wateredge"))
            &file.wateredge
        else
            return fail(problem, number, "names something that isn't a map type, ink or wateredge", name);
        if (slot.* != null) return fail(problem, number, "gives a colour a second time", name);
        slot.* = colour;
    }

    if (!seenKind) return fail(problem, 0, "doesn't name its style", "style");
    return file;
}

fn fail(problem: *Problem, line: usize, message: []const u8, name: []const u8) error{InvalidStyle} {
    problem.* = .{ .line = line, .message = message, .name = name };
    return error.InvalidStyle;
}

fn parseColour(text: []const u8) ?Rgb {
    if (text.len != 7 or text[0] != '#') return null;
    var colour: Rgb = undefined;
    for (&colour, 0..) |*channel, i| channel.* = std.fmt.parseInt(u8, text[1 + i * 2 ..][0..2], 16) catch return null;
    return colour;
}

test parse {
    try std.testing.expectEqual(Kind.relief, printed.kind);
    try std.testing.expectEqual(Rgb{ 0xE4, 0xD2, 0xA0 }, printed.colours.get(.land));
    try std.testing.expectEqual(Kind.shaded, plain.kind);
    try std.testing.expectEqual(Rgb{ 0xAC, 0x88, 0x58 }, plain.colours.get(.land));

    var problem: Problem = .{};
    const file = try parse("# A comment\nstyle shaded\nland #010203\nwateredge #FFFFFF\n", &problem);
    try std.testing.expectEqual(Kind.shaded, file.kind);
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, file.colours.get(.land).?);
    try std.testing.expectEqual(null, file.colours.get(.desert));
    try std.testing.expectEqual(null, file.ink);

    try std.testing.expectError(error.InvalidStyle, parse("land #000000\n", &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #000000\nland #000000\n", &problem));
    try std.testing.expectEqual(3, problem.line);
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nink #000000\nink #000000\n", &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nfield #000000\n", &problem));
    try std.testing.expectEqual(2, problem.line);
    try std.testing.expectEqualStrings("field", problem.name);
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nland AC8858\n", &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style watercolour\n", &problem));
}

test "File.complete" {
    var problem: Problem = .{};
    const file = try parse("style shaded\nland #010203\nwateredge #FFFFFF\n", &problem);
    const style = file.complete(.{ .colours = .initFill(.{ 9, 9, 9 }), .ink = .{ 7, 7, 7 }, .wateredge = .{ 8, 8, 8 } });
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, style.colours.get(.land));
    try std.testing.expectEqual(Rgb{ 9, 9, 9 }, style.colours.get(.desert));
    try std.testing.expectEqual(Rgb{ 7, 7, 7 }, style.ink);
    try std.testing.expectEqual(Rgb{ 255, 255, 255 }, style.wateredge);
}
