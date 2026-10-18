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
const columns = @import("../columns.zig");

/// How the colours are used.
pub const Kind = enum {
    /// A relief map: a type's colour is its colour at sea level; lower ground darkens towards
    /// `ink` and higher ground pales, slopes are shaded, liquids darken with depth, and
    /// coastlines are drawn in `wateredge`.
    relief,
    /// As the game draws its own map: each type's colour as it is, whatever the height, with
    /// the game's hill shading, and lakes unshaded with an edge in `wateredge`.
    shaded,
};

kind: Kind,
/// Each map type's colour.
colours: std.EnumArray(columns.MapType, Rgb),
/// What low ground darkens towards.
ink: Rgb,
/// Where water meets land.
wateredge: Rgb,

pub const Rgb = [3]u8;

/// The game's own map colours (vsessentialsmod `ChunkMapLayer`), for every entry a style
/// file leaves out.
pub const gameColours: std.EnumArray(columns.MapType, Rgb) = .init(.{
    .land = .{ 0xAC, 0x88, 0x58 },
    .desert = .{ 0xC4, 0xA4, 0x68 },
    .forest = .{ 0x98, 0x84, 0x4C },
    .plant = .{ 0x80, 0x86, 0x50 },
    .settlement = .{ 0x85, 0x68, 0x44 },
    .road = .{ 0x80, 0x50, 0x30 },
    .devastation = .{ 0x75, 0x5C, 0x3C },
    .glacier = .{ 0xE0, 0xE0, 0xC0 },
    .lake = .{ 0xCC, 0xC8, 0x90 },
    .ocean = .{ 0xCC, 0xC8, 0x90 },
    .lava = .{ 0xCC, 0xC8, 0x90 },
});
/// The game's ink, which it draws water's edges in.
pub const gameInk: Rgb = .{ 0x48, 0x30, 0x18 };

/// The Printed theme's style, the default.
pub const printed = parsed(@embedFile("../themes/printed/topdown/style.txt"));
/// The plain theme's: the game's own map colours, drawn as the game draws them.
pub const plain = parsed(@embedFile("../themes/plain/topdown/style.txt"));

/// A style parsed when compiling, for the built-in themes.
pub fn parsed(comptime text: []const u8) Style {
    @setEvalBranchQuota(100_000);
    var problem: Problem = .{};
    return comptime parse(text, &problem) catch @compileError(problem.message);
}

/// What's wrong with a style file, and on which line, for a message.
pub const Problem = struct {
    line: usize = 0,
    message: []const u8 = "",
    /// The entry's name, where it's about one.
    name: []const u8 = "",
};

/// Parses a style file. The style must be named; each colour may be given once, and those left
/// out are the game's. On an error, `problem` says what's wrong.
pub fn parse(text: []const u8, problem: *Problem) error{InvalidStyle}!Style {
    var style: Style = .{ .kind = .relief, .colours = gameColours, .ink = gameInk, .wateredge = gameInk };
    var seenKind = false;
    var seenColours: std.EnumSet(columns.MapType) = .empty;
    var seenInk = false;
    var seenEdge = false;

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
            style.kind = std.meta.stringToEnum(Kind, value) orelse return fail(problem, number, "names a style that isn't relief or shaded", value);
            seenKind = true;
            continue;
        }
        const colour = parseColour(value) orelse return fail(problem, number, "has a colour that isn't #RRGGBB", name);
        if (std.meta.stringToEnum(columns.MapType, name)) |mapType| {
            if (seenColours.contains(mapType)) return fail(problem, number, "gives a colour a second time", name);
            style.colours.set(mapType, colour);
            seenColours.insert(mapType);
        } else if (std.mem.eql(u8, name, "ink")) {
            if (seenInk) return fail(problem, number, "gives a colour a second time", name);
            style.ink = colour;
            seenInk = true;
        } else if (std.mem.eql(u8, name, "wateredge")) {
            if (seenEdge) return fail(problem, number, "gives a colour a second time", name);
            style.wateredge = colour;
            seenEdge = true;
        } else return fail(problem, number, "names something that isn't a map type, ink or wateredge", name);
    }

    if (!seenKind) return fail(problem, 0, "doesn't name its style", "style");
    return style;
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

    const complete =
        \\# A comment
        \\style relief
        \\land #010203
        \\desert #000000
        \\forest #000000
        \\plant #000000
        \\settlement #000000
        \\road #000000
        \\devastation #000000
        \\glacier #000000
        \\lake #000000
        \\ocean #000000
        \\lava #000000
        \\ink #000000
        \\wateredge #FFFFFF
        \\
    ;
    var problem: Problem = .{};
    const style = try parse(complete, &problem);
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, style.colours.get(.land));
    try std.testing.expectEqual(Rgb{ 255, 255, 255 }, style.wateredge);

    const partial = try parse("style shaded\nland #010203\n", &problem);
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, partial.colours.get(.land));
    try std.testing.expectEqual(gameColours.get(.desert), partial.colours.get(.desert));
    try std.testing.expectEqual(gameInk, partial.wateredge);
    try std.testing.expectEqualDeep(plain.colours, (try parse("style shaded\n", &problem)).colours);

    try std.testing.expectError(error.InvalidStyle, parse("land #000000\n", &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #000000\nland #000000\n", &problem));
    try std.testing.expectEqual(3, problem.line);
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nfield #000000\n", &problem));
    try std.testing.expectEqual(2, problem.line);
    try std.testing.expectEqualStrings("field", problem.name);
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nland AC8858\n", &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style watercolour\n", &problem));
}
