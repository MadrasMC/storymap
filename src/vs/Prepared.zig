//! The game's and mods' blocks as rendering needs them, prepared once from their assets so a
//! render never reads assets itself (docs/rendering.md#preparing-blocks).
//!
//! A prepared set is a folder `<blocks folder>/<key>/` (see `key`) holding `blocks.txt`.
//! Textures come first, each with its average colour and grain (`TextureColours`), then the
//! colour maps with their padding and flags, each image beside it as `colormaps/<code>.png`.
//! Blocks name their two textures and their climate and season colour maps by number from 0,
//! or `-` for none:
//!
//!     storymap blocks 4
//!     game 1.22.7
//!     mod primitivesurvival_5.1.4.zip
//!     domain game
//!     domain primitivesurvival
//!     texture game:block/stone/rock/granite1 8A7F78 978B83 …
//!     …
//!     colormap climatePlantTint 4 0
//!     …
//!     block rock-granite Stone land 0 0 - -
//!     …
const Prepared = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const world = @import("world");
const Assets = @import("Assets.zig");
const BlockTypes = @import("BlockTypes.zig");
const TextureColours = @import("TextureColours.zig");
const Json = @import("Json.zig");
const Tint = @import("Tint.zig");

arena: std.heap.ArenaAllocator,
gameVersion: []const u8 = "",
mods: std.ArrayList([]const u8) = .empty,
/// The domains the game and mods have assets in.
domains: std.StringHashMapUnmanaged(void) = .empty,
/// Every block, by its code as a save names it.
blocks: std.StringHashMapUnmanaged(Block) = .empty,

pub const Block = struct {
    /// One of `BlockTypes.materials`, e.g. "Stone".
    material: []const u8,
    /// Its colour on the game's map, e.g. "land" or "forest" (docs/rendering.md#block-colours).
    colorCode: []const u8,
    /// Its texture's average colour and grain, from the textures the game's colour-accurate map
    /// uses (`BlockTypes.Textures`), where readable.
    colour: ?world.Rgb = null,
    grain: []const world.Rgb = &.{},
    /// The colour maps tinting it by climate and season, where it has them and they're readable.
    climateColourMap: ?*const Tint.ColourMap = null,
    seasonColourMap: ?*const Tint.ColourMap = null,
};

/// The format of `blocks.txt`, and of what goes into it: raise it when either changes, so
/// sets prepared before are prepared again.
const formatVersion = 4;
const fileName = "blocks.txt";
const colourMapFolder = "colormaps";

/// Blocks the game registers itself rather than from a block type file.
const builtInBlocks = [_][]const u8{ "air", "mantle" };

pub fn deinit(self: *Prepared) void {
    self.arena.deinit();
}

/// Where prepared sets go when no folder is given, relative to the current folder.
pub const defaultFolder = "blocks";

/// The folder name for the set prepared from `assets`: changes with the game version, the
/// mods (their names, sizes and times) and `formatVersion`.
pub fn key(buffer: *[16]u8, io: Io, assets: *const Assets) ![]const u8 {
    var hasher: std.hash.Wyhash = .init(formatVersion);
    hasher.update(assets.version orelse "");
    for (assets.sources.items[1..]) |source| {
        hasher.update(&.{0});
        hasher.update(source.name);
        switch (source.kind) {
            .zip => |zip| {
                const stat = try zip.file.stat(io);
                hasher.update(std.mem.asBytes(&stat.size));
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            },
            .folders => |folders| for (folders) |folder| {
                const stat = try folder.dir.stat(io);
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            },
        }
    }
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{hasher.final()}) catch unreachable;
}

/// Replaces what `folder` held. Returns the block count.
pub fn prepare(arena: std.mem.Allocator, io: Io, assets: *const Assets, folder: Dir) !usize {
    const blocks = try BlockTypes.expand(arena, io, assets);
    var textures: Textures = .{ .arena = arena, .io = io, .assets = assets };
    const colourMaps = try prepareColourMaps(arena, io, assets, folder);
    const numbers = try arena.alloc([4]?usize, blocks.len);
    for (numbers, blocks) |*number, block| number.* = .{
        try textures.number(block.textures.colour),
        try textures.number(block.textures.grain),
        colourMapNumber(colourMaps, block.climateColorMap),
        colourMapNumber(colourMaps, block.seasonColorMap),
    };

    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.print("storymap blocks {}\ngame {s}\n", .{ formatVersion, assets.version orelse "" });
    for (assets.sources.items[1..]) |source| try w.print("mod {s}\n", .{source.name});
    for (assets.domains.keys()) |domain| try w.print("domain {s}\n", .{domain});
    for (textures.read.items) |texture| {
        try w.print("texture {s} {X}", .{ texture.location, &texture.colours.average });
        for (texture.colours.grain) |sample| try w.print(" {X}", .{&sample});
        try w.writeByte('\n');
    }
    for (colourMaps) |map| try w.print("colormap {s} {} {}\n", .{ map.code, map.padding, map.extraFlags });
    for (blocks, numbers) |block, number| {
        try w.print("block {s} {s} {s}", .{ block.code, block.material, block.colorCode });
        for (number) |n| if (n) |i| try w.print(" {}", .{i}) else try w.writeAll(" -");
        try w.writeByte('\n');
    }
    // Written beside it first, so a set is never left half written.
    const partial = fileName ++ ".partial";
    try folder.writeFile(io, .{ .sub_path = partial, .data = text.written() });
    try folder.rename(partial, folder, fileName, io);
    return blocks.len;
}

const PreparedColourMap = struct {
    code: []const u8,
    padding: usize,
    /// 1 for a tropical season map.
    extraFlags: u32,
};

/// Copies the images of the colour maps in the game's `config/colormaps.json` into `folder`.
/// Returns those it could read, in the file's order.
fn prepareColourMaps(arena: std.mem.Allocator, io: Io, assets: *const Assets, folder: Dir) ![]const PreparedColourMap {
    const file = "config/colormaps.json";
    const bytes = try assets.read(arena, io, Assets.gameDomain, file) orelse return &.{};
    const json = Json.parse(arena, bytes) catch |err| {
        std.debug.print("storymap: {s}: could not read ({s}); nothing will be tinted\n", .{ file, @errorName(err) });
        return &.{};
    };
    if (json != .array) return &.{};
    try folder.createDirPath(io, colourMapFolder);
    var maps: std.ArrayList(PreparedColourMap) = .empty;
    for (json.array) |entry| {
        const code = (entry.get("code") orelse continue).asString() orelse continue;
        const base = ((entry.get("texture") orelse continue).get("base") orelse continue).asString() orelse continue;
        const colon = std.mem.indexOfScalar(u8, base, ':');
        const domain = if (colon) |c| base[0..c] else Assets.gameDomain;
        const path = try std.fmt.allocPrint(arena, "textures/{s}.png", .{if (colon) |c| base[c + 1 ..] else base});
        const png = try assets.read(arena, io, domain, path) orelse {
            std.debug.print("storymap: colour map {s}: no image {s}:{s}\n", .{ code, domain, path });
            continue;
        };
        const sub = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ colourMapFolder, code });
        try folder.writeFile(io, .{ .sub_path = sub, .data = png });
        try maps.append(arena, .{ .code = code, .padding = integer(entry.get("padding")), .extraFlags = @intCast(integer(entry.get("extraFlags"))) });
    }
    return maps.items;
}

/// A whole number in the game's JSON, or 0 without one.
fn integer(value: ?Json.Value) usize {
    const number = value orelse return 0;
    if (number != .number) return 0;
    return std.fmt.parseInt(usize, number.number, 10) catch 0;
}

fn colourMapNumber(maps: []const PreparedColourMap, code: ?[]const u8) ?usize {
    const wanted = code orelse return null;
    for (maps, 0..) |map, i| if (std.mem.eql(u8, map.code, wanted)) return i;
    return null;
}

/// The textures the blocks name, each read once, numbered in the order they're first named.
const Textures = struct {
    arena: std.mem.Allocator,
    io: Io,
    assets: *const Assets,
    /// Each location named so far, and its number, or null if it can't be read.
    numbers: std.StringHashMapUnmanaged(?usize) = .empty,
    read: std.ArrayList(struct { location: []const u8, colours: TextureColours }) = .empty,
    /// Every texture file, listed the first time a location ends in `*`.
    files: ?[]const Assets.Name = null,

    /// Reads the texture the first time; null without a location or if it can't be read.
    fn number(self: *Textures, location: ?[]const u8) !?usize {
        const wanted = location orelse return null;
        const entry = try self.numbers.getOrPut(self.arena, wanted);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;
        const colours = try self.readColours(wanted) orelse return null;
        try self.read.append(self.arena, .{ .location = wanted, .colours = colours });
        entry.value_ptr.* = self.read.items.len - 1;
        return entry.value_ptr.*;
    }

    fn readColours(self: *Textures, location: []const u8) !?TextureColours {
        const colon = std.mem.indexOfScalar(u8, location, ':').?;
        const domain = location[0..colon];
        var path = try std.fmt.allocPrint(self.arena, "textures/{s}.png", .{location[colon + 1 ..]});
        if (std.mem.endsWith(u8, location, "*")) {
            // The first file it starts, by name (vsapi `CompositeTexture.Bake`).
            const start = path[0 .. path.len - "*.png".len];
            const files = self.files orelse try self.assets.list(self.arena, self.io, "textures");
            self.files = files;
            path = for (files) |file| {
                if (std.mem.eql(u8, file.domain, domain) and std.mem.startsWith(u8, file.path, start) and std.mem.endsWith(u8, file.path, ".png")) break @constCast(file.path);
            } else return null;
        }
        const png = try self.assets.read(self.arena, self.io, domain, path) orelse return null;
        return TextureColours.ofPng(png);
    }
};

pub fn exists(io: Io, folder: Dir) bool {
    folder.access(io, fileName, .{}) catch return false;
    return true;
}

pub fn load(allocator: std.mem.Allocator, io: Io, folder: Dir) !Prepared {
    var self: Prepared = .{ .arena = .init(allocator) };
    errdefer self.deinit();
    const arena = self.arena.allocator();
    const text = try folder.readFileAlloc(io, fileName, arena, .limited(256 << 20));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const header = lines.next() orelse return error.NotPreparedBlocks;
    if (!std.mem.eql(u8, header, std.fmt.comptimePrint("storymap blocks {}", .{formatVersion}))) return error.NotPreparedBlocks;
    var textures: std.ArrayList(*const TextureColours) = .empty;
    // Null where a colour map's image can't be read, so the numbers still count.
    var colourMaps: std.ArrayList(?*const Tint.ColourMap) = .empty;
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        const kind = words.next() orelse continue;
        const first = words.next() orelse "";
        if (std.mem.eql(u8, kind, "game")) {
            self.gameVersion = first;
        } else if (std.mem.eql(u8, kind, "mod")) {
            try self.mods.append(arena, first);
        } else if (std.mem.eql(u8, kind, "domain")) {
            try self.domains.put(arena, first, {});
        } else if (std.mem.eql(u8, kind, "texture")) {
            const colours = try arena.create(TextureColours);
            colours.average = try parseRgb(words.next());
            for (&colours.grain) |*sample| sample.* = try parseRgb(words.next());
            try textures.append(arena, colours);
        } else if (std.mem.eql(u8, kind, "colormap")) {
            const padding = std.fmt.parseInt(usize, words.next() orelse "", 10) catch return error.NotPreparedBlocks;
            const flags = std.fmt.parseInt(u32, words.next() orelse "", 10) catch return error.NotPreparedBlocks;
            try colourMaps.append(arena, try loadColourMap(arena, io, folder, first, padding, flags == 1));
        } else if (std.mem.eql(u8, kind, "block")) {
            const material = words.next() orelse return error.NotPreparedBlocks;
            const colorCode = words.next() orelse return error.NotPreparedBlocks;
            const colour = try numbered(*const TextureColours, textures.items, words.next());
            const grain = try numbered(*const TextureColours, textures.items, words.next());
            const climate = try numbered(?*const Tint.ColourMap, colourMaps.items, words.next());
            const season = try numbered(?*const Tint.ColourMap, colourMaps.items, words.next());
            try self.blocks.put(arena, first, .{
                .material = material,
                .colorCode = colorCode,
                .colour = if (colour) |texture| texture.average else null,
                .grain = if (grain) |texture| &texture.grain else &.{},
                .climateColourMap = climate orelse null,
                .seasonColourMap = season orelse null,
            });
        }
    }
    return self;
}

/// Null if the colour map's image can't be read.
fn loadColourMap(arena: std.mem.Allocator, io: Io, folder: Dir, code: []const u8, padding: usize, tropical: bool) !?*const Tint.ColourMap {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}.png", .{ colourMapFolder, code }) catch return null;
    const png = folder.readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const map = try arena.create(Tint.ColourMap);
    map.* = try Tint.ColourMap.decode(arena, code, png, padding, tropical) orelse return null;
    return map;
}

fn parseRgb(word: ?[]const u8) !world.Rgb {
    const hex = word orelse return error.NotPreparedBlocks;
    var rgb: world.Rgb = undefined;
    if (hex.len != 6) return error.NotPreparedBlocks;
    _ = std.fmt.hexToBytes(&rgb, hex) catch return error.NotPreparedBlocks;
    return rgb;
}

/// The texture or colour map a block names by its number, or null for `-`.
fn numbered(comptime T: type, items: []const T, word: ?[]const u8) !?T {
    const n = word orelse return error.NotPreparedBlocks;
    if (std.mem.eql(u8, n, "-")) return null;
    const i = std.fmt.parseInt(usize, n, 10) catch return error.NotPreparedBlocks;
    if (i >= items.len) return error.NotPreparedBlocks;
    return items[i];
}

/// The folder name of the most recently prepared set in `blocks`, or null without any. For
/// when the game isn't there to give the key.
pub fn newest(arena: std.mem.Allocator, io: Io, blocks: Dir) !?[]const u8 {
    var best: ?[]const u8 = null;
    var bestTime: i96 = std.math.minInt(i96);
    var it = blocks.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ entry.name, fileName });
        const stat = blocks.statFile(io, path, .{}) catch continue;
        if (stat.mtime.nanoseconds > bestTime) {
            bestTime = stat.mtime.nanoseconds;
            best = try arena.dupe(u8, entry.name);
        }
    }
    return best;
}

/// What a save's blocks have that the prepared set doesn't: the mods (domains) it lacks, and
/// how many codes in known domains it lacks, with an example.
pub const Unknown = struct {
    mods: []const []const u8,
    codes: usize,
    example: ?[]const u8,
};

pub fn unknown(self: *const Prepared, allocator: std.mem.Allocator, codes: []const ?[]const u8) !Unknown {
    var mods: std.ArrayList([]const u8) = .empty;
    errdefer mods.deinit(allocator);
    var count: usize = 0;
    var example: ?[]const u8 = null;
    codes: for (codes) |maybeCode| {
        const code = maybeCode orelse continue;
        if (self.blocks.contains(code)) continue;
        for (builtInBlocks) |builtIn| if (std.mem.eql(u8, code, builtIn)) continue :codes;
        const colon = std.mem.indexOfScalar(u8, code, ':');
        const domain = if (colon) |c| code[0..c] else Assets.gameDomain;
        if (!self.domains.contains(domain)) {
            for (mods.items) |seen| {
                if (std.mem.eql(u8, seen, domain)) break;
            } else try mods.append(allocator, domain);
            continue;
        }
        count += 1;
        if (example == null) example = code;
    }
    return .{ .mods = try mods.toOwnedSlice(allocator), .codes = count, .example = example };
}

test "prepare, load and compare with a save" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "game/assets/version-1.22.7.txt", "" },
        .{ "game/assets/survival/worldproperties/block/rock.json", "{ code: 'rock', variants: [ { code: 'granite' } ] }" },
        .{ "game/assets/survival/blocktypes/rock.json", "{ code: 'rock', variantgroups: [ { loadFromProperties: 'block/rock' } ], textures: { all: { base: 'block/stone/{rock}*' } }, climateColorMap: 'climateTest', seasonColorMap: 'missing' }" },
        .{ "game/assets/survival/textures/block/stone/granite1.png", @embedFile("testdata/red.png") },
        .{ "game/assets/survival/config/colormaps.json", "[ { code: 'climateTest', texture: { base: 'environment/test' } }, { code: 'missing', texture: { base: 'environment/none' } } ]" },
        .{ "game/assets/game/textures/environment/test.png", @embedFile("testdata/red.png") },
        .{ "game/assets/survival/textures/block/stone/granite2.png", "not read: granite1 comes first" },
        .{ "data/Mods/testmod.zip", @embedFile("testdata/testmod.zip") },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var game = try tmp.dir.openDir(io, "game", .{});
    defer game.close(io);
    var data = try tmp.dir.openDir(io, "data", .{});
    defer data.close(io);
    var assets = try Assets.open(std.testing.allocator, io, game, data);
    defer assets.close(io);

    var buffer: [16]u8 = undefined;
    const name = try key(&buffer, io, &assets);
    try std.testing.expectEqual(16, name.len);
    try tmp.dir.createDirPath(io, name);
    var folder = try tmp.dir.openDir(io, name, .{});
    defer folder.close(io);
    try std.testing.expect(!exists(io, folder));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // rock-granite, and the test mod's thing.
    try std.testing.expectEqual(2, try prepare(arena.allocator(), io, &assets, folder));
    try std.testing.expect(exists(io, folder));

    var prepared = try load(std.testing.allocator, io, folder);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("1.22.7", prepared.gameVersion);
    try std.testing.expectEqualStrings("testmod.zip", prepared.mods.items[0]);
    try std.testing.expectEqualStrings("Stone", prepared.blocks.get("rock-granite").?.material);
    try std.testing.expectEqualStrings("land", prepared.blocks.get("rock-granite").?.colorCode);
    // The transparent pixel counts for nothing.
    try std.testing.expectEqual(world.Rgb{ 200, 40, 20 }, prepared.blocks.get("rock-granite").?.colour.?);
    try std.testing.expectEqual(TextureColours.samples, prepared.blocks.get("rock-granite").?.grain.len);
    // The colour map's image, 2 × 1; the other one has none, so it isn't there.
    const climate = prepared.blocks.get("rock-granite").?.climateColourMap.?;
    try std.testing.expectEqualStrings("climateTest", climate.code);
    try std.testing.expectEqual(2, climate.width);
    try std.testing.expectEqual(null, prepared.blocks.get("rock-granite").?.seasonColourMap);
    try std.testing.expect(prepared.blocks.contains("testmod:thing"));
    try std.testing.expectEqual(null, prepared.blocks.get("testmod:thing").?.colour);

    const codes = [_]?[]const u8{ "air", "rock-granite", "rock-basalt", null, "testmod:thing", "othermod:x", "othermod:y" };
    const missing = try prepared.unknown(std.testing.allocator, &codes);
    defer std.testing.allocator.free(missing.mods);
    try std.testing.expectEqual(1, missing.mods.len);
    try std.testing.expectEqualStrings("othermod", missing.mods[0]);
    try std.testing.expectEqual(1, missing.codes);
    try std.testing.expectEqualStrings("rock-basalt", missing.example.?);
}
