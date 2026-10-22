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
const world = @import("world");

/// The map drawn, and so how the colours are used.
pub const Kind = union(enum) {
    /// Storymap's relief map: a type's colour is its colour at sea level; lower ground darkens
    /// towards `ink` and higher ground pales, slopes are shaded, liquids darken with depth, and
    /// coastlines are drawn in `wateredge`.
    relief,
    /// One of the game's own maps, by the name the game gives it, drawn as the game draws it in
    /// the style's colours: for Vintage Story, `shaded` or `coloured`
    /// (docs/themes.md#map-colours). Whether the game has a map by that name is up to the game.
    game: []const u8,
};

kind: Kind,
/// Each map type's colour.
colours: std.EnumArray(world.MapType, Rgb),
/// What low ground darkens towards.
ink: Rgb,
/// Where water meets land.
wateredge: Rgb,

pub const Rgb = world.Rgb;

/// What's wrong with a style file, and on which line, for a message.
pub const Problem = struct {
    line: usize = 0,
    message: []const u8 = "",
    /// The entry's name, where it's about one.
    name: []const u8 = "",
};

/// Parses a style file, taking the colours it leaves out from `defaults`, such as the game's own
/// palette. Without defaults, it must give every colour. The style must be named, and each
/// colour may be given once. On an error, `problem` says what's wrong.
pub fn parse(text: []const u8, defaults: ?world.Palette, problem: *Problem) error{InvalidStyle}!Style {
    // For the built-in themes' styles, parsed when compiling.
    @setEvalBranchQuota(100_000);
    // What the file gives, null where it leaves a colour out.
    var file: struct {
        kind: Kind = .relief,
        colours: std.EnumArray(world.MapType, ?Rgb) = .initFill(null),
        ink: ?Rgb = null,
        wateredge: ?Rgb = null,
    } = .{};
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
            file.kind = if (std.mem.eql(u8, value, "relief")) .relief else .{ .game = value };
            seenKind = true;
            continue;
        }
        const colour = parseColour(value) orelse return fail(problem, number, "has a colour that isn't #RRGGBB", name);
        const slot: *?Rgb = if (std.meta.stringToEnum(world.MapType, name)) |mapType|
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

    if (!seenKind) return fail(problem, 0, "doesn't name its style", "");

    var style: Style = .{
        .kind = file.kind,
        .colours = undefined,
        .ink = file.ink orelse if (defaults) |d| d.ink else return fail(problem, 0, "doesn't give a colour for", "ink"),
        .wateredge = file.wateredge orelse if (defaults) |d| d.wateredge else return fail(problem, 0, "doesn't give a colour for", "wateredge"),
    };
    for (std.enums.values(world.MapType)) |mapType| {
        const colour = file.colours.get(mapType) orelse if (defaults) |d| d.colours.get(mapType) else return fail(problem, 0, "doesn't give a colour for", @tagName(mapType));
        style.colours.set(mapType, colour);
    }
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
    const defaults: world.Palette = .{ .colours = .initFill(.{ 9, 9, 9 }), .ink = .{ 7, 7, 7 }, .wateredge = .{ 8, 8, 8 } };
    var problem: Problem = .{};
    // What the file leaves out comes from the defaults.
    const style = try parse("# A comment\nstyle shaded\nland #010203\nwateredge #FFFFFF\n", defaults, &problem);
    try std.testing.expectEqualStrings("shaded", style.kind.game);
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, style.colours.get(.land));
    try std.testing.expectEqual(Kind.relief, (try parse("style relief\n", defaults, &problem)).kind);
    try std.testing.expectEqual(Rgb{ 9, 9, 9 }, style.colours.get(.desert));
    try std.testing.expectEqual(Rgb{ 7, 7, 7 }, style.ink);
    try std.testing.expectEqual(Rgb{ 255, 255, 255 }, style.wateredge);

    // Without defaults, every colour must be given.
    try std.testing.expectError(error.InvalidStyle, parse("style shaded\nland #010203\n", null, &problem));
    try std.testing.expectEqual(0, problem.line);
    try std.testing.expectEqualStrings("ink", problem.name);

    try std.testing.expectError(error.InvalidStyle, parse("land #000000\n", defaults, &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #000000\nland #000000\n", defaults, &problem));
    try std.testing.expectEqual(3, problem.line);
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nink #000000\nink #000000\n", defaults, &problem));
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nfield #000000\n", defaults, &problem));
    try std.testing.expectEqual(2, problem.line);
    try std.testing.expectEqualStrings("field", problem.name);
    try std.testing.expectError(error.InvalidStyle, parse("style relief\nland AC8858\n", defaults, &problem));
}
