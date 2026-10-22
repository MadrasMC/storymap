const std = @import("std");
const world = @import("world");

/// How a theme draws the top-down map: `topdown/style.txt` in the theme's folder
/// (docs/themes.md#map-style). The style's name, then, for Storymap's own styles, a colour for
/// each map type and for the two inks, one per line; colours left out are the game's own:
///
///     # Comments start with #.
///     style relief
///     land       #E4D2A0
///     …
///     ink        #4A301A
///     wateredge  #5C462E
///
/// A game's own style, `game` or `game:<name>`, takes the game's own colours, and ignores any the
/// file gives.
pub const Style = union(enum) {
    /// Storymap's relief map, in these colours: a type's colour is its colour at sea level;
    /// lower ground darkens towards `ink` and higher ground pales, slopes are shaded, liquids
    /// darken with depth, and coastlines are drawn in `wateredge`.
    relief: world.Palette,
    /// One of the game's own styles, drawn as the game draws its map, in the game's colours:
    /// `game` for the game's default, null here, or `game:<name>` for one by name, which the game
    /// may not have.
    game: ?[]const u8,

    pub const Rgb = world.Rgb;

    /// The names Storymap's own styles are written as, for messages: "relief".
    pub const storymapNames = names: {
        var text: []const u8 = "";
        for (std.meta.fieldNames(Style)) |name| {
            if (std.mem.eql(u8, name, "game")) continue;
            text = text ++ (if (text.len > 0) ", " else "") ++ name;
        }
        break :names text;
    };

    /// What's wrong with a style file, and on which line, 0 for the file as a whole.
    pub const Problem = struct {
        kind: Kind = .missingStyle,
        line: usize = 0,
        /// The entry or style it's about.
        name: []const u8 = "",

        pub const Kind = enum {
            missingValue,
            extraValue,
            unknownStyle,
            repeatedStyle,
            missingStyle,
            unknownEntry,
            invalidColour,
            repeatedColour,
            missingColour,
        };

        /// The problem as a message, e.g. "unknown style shaded. expected: relief, game,
        /// game:<name>", for `{f}`.
        pub fn format(self: Problem, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.kind) {
                .missingValue => try writer.print("{s} has no value", .{self.name}),
                .extraValue => try writer.print("{s} has more than one value", .{self.name}),
                .unknownStyle => try writer.print("unknown style {s}. expected: {s}, game, game:<name>", .{ self.name, storymapNames }),
                .repeatedStyle => try writer.writeAll("style given twice"),
                .missingStyle => try writer.writeAll("no style"),
                .unknownEntry => try writer.print("unknown entry {s}", .{self.name}),
                .invalidColour => try writer.print("{s} isn't a #RRGGBB colour", .{self.name}),
                .repeatedColour => try writer.print("{s} given twice", .{self.name}),
                .missingColour => try writer.print("no colour for {s}", .{self.name}),
            }
        }
    };

    /// Parses a style file, a Storymap style taking the colours it leaves out from `defaults`,
    /// such as the game's own palette. Without defaults, it must give every colour. The style
    /// must be named, and each colour may be given once. On an error, `problem` says what's
    /// wrong.
    pub fn parse(text: []const u8, defaults: ?world.Palette, problem: *Problem) error{InvalidStyle}!Style {
        // For the built-in themes' styles, parsed when compiling.
        @setEvalBranchQuota(100_000);
        // What the file gives, null where it leaves something out.
        var kind: ?std.meta.Tag(Style) = null;
        var gameName: ?[]const u8 = null;
        var colours: std.EnumArray(world.MapType, ?Rgb) = .initFill(null);
        var ink: ?Rgb = null;
        var wateredge: ?Rgb = null;

        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const name = words.next().?;
            const value = words.next() orelse return fail(problem, number, .missingValue, name);
            if (words.next() != null) return fail(problem, number, .extraValue, name);

            if (std.mem.eql(u8, name, "style")) {
                if (kind != null) return fail(problem, number, .repeatedStyle, name);
                if (std.mem.eql(u8, value, "game")) {
                    kind = .game;
                } else if (std.mem.startsWith(u8, value, "game:") and value.len > "game:".len) {
                    kind = .game;
                    gameName = value["game:".len..];
                } else {
                    // A bare `game` is handled above.
                    kind = std.meta.stringToEnum(std.meta.Tag(Style), value) orelse
                        return fail(problem, number, .unknownStyle, value);
                }
                continue;
            }
            const colour = parseColour(value) orelse return fail(problem, number, .invalidColour, name);
            const slot: *?Rgb = if (std.meta.stringToEnum(world.MapType, name)) |mapType|
                colours.getPtr(mapType)
            else if (std.mem.eql(u8, name, "ink"))
                &ink
            else if (std.mem.eql(u8, name, "wateredge"))
                &wateredge
            else
                return fail(problem, number, .unknownEntry, name);
            if (slot.* != null) return fail(problem, number, .repeatedColour, name);
            slot.* = colour;
        }

        switch (kind orelse return fail(problem, 0, .missingStyle, "")) {
            .game => return .{ .game = gameName },
            .relief => {
                var palette: world.Palette = .{
                    .colours = undefined,
                    .ink = ink orelse if (defaults) |d| d.ink else return fail(problem, 0, .missingColour, "ink"),
                    .wateredge = wateredge orelse if (defaults) |d| d.wateredge else return fail(problem, 0, .missingColour, "wateredge"),
                };
                for (std.enums.values(world.MapType)) |mapType| {
                    const colour = colours.get(mapType) orelse if (defaults) |d| d.colours.get(mapType) else return fail(problem, 0, .missingColour, @tagName(mapType));
                    palette.colours.set(mapType, colour);
                }
                return .{ .relief = palette };
            },
        }
    }

    fn fail(problem: *Problem, line: usize, kind: Problem.Kind, name: []const u8) error{InvalidStyle} {
        problem.* = .{ .kind = kind, .line = line, .name = name };
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
        const palette = (try parse("# A comment\nstyle relief\nland #010203\nwateredge #FFFFFF\n", defaults, &problem)).relief;
        try std.testing.expectEqual(Rgb{ 1, 2, 3 }, palette.colours.get(.land));
        try std.testing.expectEqual(Rgb{ 9, 9, 9 }, palette.colours.get(.desert));
        try std.testing.expectEqual(Rgb{ 7, 7, 7 }, palette.ink);
        try std.testing.expectEqual(Rgb{ 255, 255, 255 }, palette.wateredge);

        // The game's own styles, by default or by name; they ignore colours.
        try std.testing.expectEqual(null, (try parse("style game\n", null, &problem)).game);
        try std.testing.expectEqualStrings("coloured", (try parse("style game:coloured\n", null, &problem)).game.?);
        try std.testing.expectEqual(null, (try parse("land #010203\nstyle game\n", null, &problem)).game);

        // Without defaults, every colour must be given.
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #010203\n", null, &problem));
        try std.testing.expectEqual(0, problem.line);
        try std.testing.expectEqualStrings("ink", problem.name);

        const unknown = [_][]const u8{ "style shaded\n", "style game:\n", "style watercolour\n" };
        for (unknown) |text| {
            try std.testing.expectError(error.InvalidStyle, parse(text, defaults, &problem));
            try std.testing.expectEqual(1, problem.line);
        }
        try std.testing.expectError(error.InvalidStyle, parse("land #000000\n", defaults, &problem));
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #000000\nland #000000\n", defaults, &problem));
        try std.testing.expectEqual(3, problem.line);
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nink #000000\nink #000000\n", defaults, &problem));
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nfield #000000\n", defaults, &problem));
        try std.testing.expectEqual(2, problem.line);
        try std.testing.expectEqualStrings("field", problem.name);
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland AC8858\n", defaults, &problem));
    }

    test "Problem.format" {
        var problem: Problem = .{};
        var buffer: [64]u8 = undefined;
        try std.testing.expectError(error.InvalidStyle, parse("style shaded\n", null, &problem));
        try std.testing.expectEqualStrings("unknown style shaded. expected: relief, game, game:<name>", try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland 010203\n", null, &problem));
        try std.testing.expectEqualStrings("land isn't a #RRGGBB colour", try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
    }
};
