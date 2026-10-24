const std = @import("std");
const world = @import("world");

/// How a theme draws the top-down map: `topdown/style.txt` in the theme's folder
/// (docs/themes.md#map-style). The style's name, then a colour for each map type and for the
/// two inks, one per line:
///
///     # Comments start with #.
///     style relief
///     land       #E4D2A0
///     …
///     ink        #4A301A
///     wateredge  #5C462E
pub const Style = union(enum) {
    /// Storymap's relief map, in these colours: a type's colour is its colour at sea level;
    /// lower ground darkens towards `ink` and higher ground pales, slopes are shaded, liquids
    /// darken with depth, and coastlines are drawn in `wateredge`.
    relief: world.Palette,
    /// One of the game's own styles, in the game's colours: the name after `game:`, or null for
    /// `game`, the game's default.
    game: ?[]const u8,

    pub const Rgb = world.Rgb;

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

    /// A style's name as written: `relief`, `game` or `game:<name>`.
    pub const Name = struct {
        kind: std.meta.Tag(Style),
        /// For a game style, the name after `game:`, or null for the game's default.
        game: ?[]const u8 = null,
    };

    /// Its name as written, without its colours.
    pub fn format(self: Style, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .relief => try writer.writeAll("relief"),
            .game => |name| if (name) |given| try writer.print("game:{s}", .{given}) else try writer.writeAll("game"),
        }
    }

    pub fn parseName(text: []const u8) ?Name {
        if (std.mem.eql(u8, text, "game")) return .{ .kind = .game };
        if (std.mem.startsWith(u8, text, "game:")) {
            if (text.len == "game:".len) return null;
            return .{ .kind = .game, .game = text["game:".len..] };
        }
        return .{ .kind = std.meta.stringToEnum(std.meta.Tag(Style), text) orelse return null };
    }

    /// Colours the file leaves out come from `defaults`; without them, it must give every colour.
    /// `override` replaces the file's style.
    pub fn parse(text: []const u8, defaults: ?world.Palette, override: ?Name, problem: *Problem) error{InvalidStyle}!Style {
        // For the built-in themes' styles, parsed when compiling.
        @setEvalBranchQuota(100_000);
        var named: ?Name = null;
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
                if (named != null) return fail(problem, number, .repeatedStyle, name);
                named = parseName(value) orelse return fail(problem, number, .unknownStyle, value);
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

        const style = override orelse named orelse return fail(problem, 0, .missingStyle, "");
        switch (style.kind) {
            .game => return .{ .game = style.game },
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
        const palette = (try parse("# A comment\nstyle relief\nland #010203\nwateredge #FFFFFF\n", defaults, null, &problem)).relief;
        try std.testing.expectEqual(Rgb{ 1, 2, 3 }, palette.colours.get(.land));
        try std.testing.expectEqual(Rgb{ 9, 9, 9 }, palette.colours.get(.desert));
        try std.testing.expectEqual(Rgb{ 7, 7, 7 }, palette.ink);
        try std.testing.expectEqual(Rgb{ 255, 255, 255 }, palette.wateredge);

        // The game's own styles, by default or by name; they ignore colours.
        try std.testing.expectEqual(null, (try parse("style game\n", null, null, &problem)).game);
        try std.testing.expectEqualStrings("coloured", (try parse("style game:coloured\n", null, null, &problem)).game.?);
        try std.testing.expectEqual(null, (try parse("land #010203\nstyle game\n", null, null, &problem)).game);

        // Without defaults, every colour must be given.
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #010203\n", null, null, &problem));
        try std.testing.expectEqual(0, problem.line);
        try std.testing.expectEqualStrings("ink", problem.name);

        const unknown = [_][]const u8{ "style shaded\n", "style game:\n", "style watercolour\n" };
        for (unknown) |text| {
            try std.testing.expectError(error.InvalidStyle, parse(text, defaults, null, &problem));
            try std.testing.expectEqual(1, problem.line);
        }
        try std.testing.expectError(error.InvalidStyle, parse("land #000000\n", defaults, null, &problem));
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland #000000\nland #000000\n", defaults, null, &problem));
        try std.testing.expectEqual(3, problem.line);
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nink #000000\nink #000000\n", defaults, null, &problem));
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nfield #000000\n", defaults, null, &problem));
        try std.testing.expectEqual(2, problem.line);
        try std.testing.expectEqualStrings("field", problem.name);
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland AC8858\n", defaults, null, &problem));
    }

    test parseName {
        try std.testing.expectEqualDeep(Name{ .kind = .relief }, parseName("relief").?);
        try std.testing.expectEqualDeep(Name{ .kind = .game }, parseName("game").?);
        try std.testing.expectEqualDeep(Name{ .kind = .game, .game = "coloured" }, parseName("game:coloured").?);
        for ([_][]const u8{ "game:", "shaded", "Relief" }) |text| try std.testing.expectEqual(null, parseName(text));
    }

    test "parse with an override" {
        const defaults: world.Palette = .{ .colours = .initFill(.{ 9, 9, 9 }), .ink = .{ 7, 7, 7 }, .wateredge = .{ 8, 8, 8 } };
        var problem: Problem = .{};
        // The file's colours, though its own style ignores them, and the rest from the defaults.
        const palette = (try parse("style game\nland #010203\n", defaults, .{ .kind = .relief }, &problem)).relief;
        try std.testing.expectEqual(Rgb{ 1, 2, 3 }, palette.colours.get(.land));
        try std.testing.expectEqual(Rgb{ 9, 9, 9 }, palette.colours.get(.desert));
        // A file without a style line.
        try std.testing.expectEqualStrings("coloured", (try parse("land #010203\n", null, .{ .kind = .game, .game = "coloured" }, &problem)).game.?);
    }

    test "Problem.format" {
        var problem: Problem = .{};
        var buffer: [64]u8 = undefined;
        try std.testing.expectError(error.InvalidStyle, parse("style shaded\n", null, null, &problem));
        try std.testing.expectEqualStrings("unknown style shaded. expected: relief, game, game:<name>", try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
        try std.testing.expectError(error.InvalidStyle, parse("style relief\nland 010203\n", null, null, &problem));
        try std.testing.expectEqualStrings("land isn't a #RRGGBB colour", try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
    }
};
