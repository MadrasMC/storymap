//! `storymap prepare`: prepares what the map needs from the game's and mods' assets, and draws
//! the isometric view's sprites of the blocks, into the prepared blocks file
//! (docs/storyblk/spec.md). A render does the same when the file wasn't prepared from the game
//! and mods it runs with (`blocks`).
const std = @import("std");
const Assets = @import("vs").Assets;
const Prepared = @import("vs").Prepared;
const SaveFile = @import("vs").SaveFile;
const isometric = @import("renderer").isometric;
const Sprites = isometric.Sprites;
const storyblk = @import("storyblk");
const console = @import("console");
const args = @import("args");

pub const gameOption: args.Option = .{ .name = "game", .value = "folder", .description = "The game's install folder, if it isn't in the standard place." };
pub const dataOption: args.Option = .{ .name = "data", .value = "folder", .description = "The game's data folder, if it isn't in the standard place." };

pub const spec: args.Spec = .{
    .options = &.{ gameOption, dataOption },
    .positionals = &.{.{ .name = "file", .optional = true, .description = "The prepared blocks file: prepared.storyblk by default." }},
    .description = "Prepares what the map needs from the game's and mods' assets into the prepared blocks file, even if it was prepared before.",
};

/// Where the game, its mods and the prepared blocks are.
pub const Paths = struct {
    game: ?[]const u8 = null,
    data: ?[]const u8 = null,
    blocks: []const u8 = Prepared.defaultPath,
};

pub fn run(init: std.process.Init, parsed: args.Parsed(spec)) !void {
    const paths: Paths = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.positional("file") orelse Prepared.defaultPath,
    };
    var prepared = blocks(init, paths, true) orelse unreachable;
    prepared.deinit(init.io);
}

/// The prepared blocks, and the isometric view's sprites of them, mapped from their file.
pub const Blocks = struct {
    prepared: Prepared,
    sprites: Sprites,
    file: std.Io.File,
    map: std.Io.File.MemoryMap,

    pub fn deinit(self: *Blocks, io: std.Io) void {
        self.prepared.deinit();
        self.map.destroy(io);
        self.file.close(io);
    }
};

const spriteFormat: Prepared.SpriteFormat = .{
    .generatorVersion = Sprites.generatorVersion,
    .layoutVersion = Sprites.layoutVersion,
    .blockWidth = isometric.blockWidth,
};

/// The blocks for the installed game and mods, from the prepared blocks file, prepared into it
/// first if it wasn't prepared from them or `force` is set. Without the game, the file as it is,
/// if this Storymap made it the way it would now, or else null; `force` then stops the program.
pub fn blocks(init: std.process.Init, paths: Paths, force: bool) ?Blocks {
    const io = init.io;
    const arena = init.arena.allocator();
    const path = paths.blocks;

    const gamePath = paths.game orelse Assets.findFolder(arena, io, init.environ_map, .game) orelse {
        if (force) console.fail("could not locate Vintage Story; pass `--game <folder>`", .{});
        var problem: Problem = .none;
        const found = open(init, path, &problem) catch |err| {
            switch (problem) {
                .none => switch (err) {
                    error.FileNotFound => noBlocks(),
                    error.NotPreparedBlocks => console.warn("{s}: not a prepared blocks file; drawing the map without block colours", .{path}),
                    else => console.warn("{s}: could not read the prepared blocks ({s}); drawing the map without block colours", .{ path, @errorName(err) }),
                },
                .generatorVersion => |other| console.warn("{s}: prepared by another Storymap (its {s} section is version {}, this one makes {}); drawing the map without block colours; pass `--game <folder>` to prepare it again", .{ path, other.section, other.file, other.this }),
                .blockWidth => |width| console.warn("{s}: sprites {} pixels wide, this Storymap's are {}; drawing the map without block colours; pass `--game <folder>` to prepare it again", .{ path, width, isometric.blockWidth }),
            }
            return null;
        };
        const mods = found.prepared.mods.len;
        console.log("blocks: Vintage Story {s} and {} {s}, prepared earlier ({s}; game not found)", .{ versionText(found.prepared.gameVersion), mods, modText(mods), path });
        return found;
    };

    var assets = openAssets(init, gamePath, paths.data);
    defer assets.close(io);
    const hash = Prepared.hash(io, &assets, spriteFormat) catch |err| console.fail("could not read the mods ({s})", .{@errorName(err)});
    const mods = assets.sources.items.len - 1;
    const version = versionText(assets.version orelse "");
    if (!force) if (hashOf(init, path)) |existing| if (existing == hash) {
        var problem: Problem = .none;
        if (open(init, path, &problem)) |found| {
            console.log("blocks: Vintage Story {s} and {} {s}, prepared earlier ({s})", .{ version, mods, modText(mods), path });
            return found;
        } else |_| {}
    };

    storyblk.checkReplaceable(io, std.Io.Dir.cwd(), path) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not read ({s})", .{ path, @errorName(err) }),
    };
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    const start: std.Io.Timestamp = .now(io, .awake);
    var contents = Prepared.prepare(init.gpa, scratch.allocator(), io, &assets) catch |err|
        console.fail("{s}: could not prepare the blocks ({s})", .{ path, @errorName(err) });
    console.log("blocks: {} prepared from Vintage Story {s} and {} {s} in {d:.1} s ({s})", .{
        contents.blocks.len, version, mods, modText(mods), secondsSince(io, start), path,
    });
    const drawing: std.Io.Timestamp = .now(io, .awake);
    var spriteSections = Sprites.Sections.init() catch |err|
        console.fail("{s}: could not draw the blocks' sprites ({s})", .{ path, @errorName(err) });
    defer spriteSections.deinit();
    const sprites = drawSprites(scratch.allocator(), &contents, &spriteSections) catch |err|
        console.fail("{s}: could not draw the blocks' sprites ({s})", .{ path, @errorName(err) });
    console.log("sprites: {} drawn in {d:.1} s", .{ spriteSections.entries.items.len, secondsSince(io, drawing) });
    const sections = (contents.encode(scratch.allocator()) catch |err|
        console.fail("{s}: could not prepare the blocks ({s})", .{ path, @errorName(err) })) ++ sprites;
    storyblk.writeFile(io, std.Io.Dir.cwd(), path, hash, contents.info(), &sections) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not write ({s})", .{ path, @errorName(err) }),
    };

    var problem: Problem = .none;
    return open(init, path, &problem) catch |err| console.fail("{s}: could not read the prepared blocks ({s})", .{ path, @errorName(err) });
}

/// Draws the sprites of every block in `contents` into `sprites`, giving each block its own.
/// Returns the `sprites` and `sprite_layers` sections.
fn drawSprites(arena: std.mem.Allocator, contents: *Prepared.Contents, sprites: *Sprites.Sections) ![2]storyblk.Section {
    const drawables = try arena.alloc(isometric.Drawable, contents.blocks.len);
    for (drawables, contents.blocks) |*drawable, *entry| drawable.* = .{
        .cube = if (entry.block.cube) |*cube| cube else null,
        .shapes = entry.block.shapes,
        .colour = SaveFile.colourOf(&entry.block),
        .turned = entry.block.randomizeRotations,
    };
    contents.useSprites(try isometric.drawSprites(arena, drawables, sprites));
    return .{
        .{ .name = Sprites.entriesSection, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = try sprites.entryBytes(arena, isometric.blockWidth) },
        .{ .name = Sprites.layersSection, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = sprites.layers.written() },
    };
}

/// The hash in the header of the file at `path`, which is closed again before it's compared
/// (spec §1); null for a file that can't be read or isn't a prepared blocks file.
fn hashOf(init: std.process.Init, path: []const u8) ?u64 {
    const io = init.io;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    const header, _ = storyblk.readInfo(scratch.allocator(), &reader.interface) catch return null;
    return header.hash;
}

/// Why a prepared blocks file this Storymap could read isn't one it can use.
const Problem = union(enum) {
    none,
    /// A section made by other code than this Storymap's (spec §7).
    generatorVersion: struct { section: []const u8, file: u16, this: u16 },
    /// Sprites drawn for a cube's square this many pixels wide.
    blockWidth: u16,
};

/// The prepared blocks file at `path`, mapped. One made other than the way this Storymap makes
/// it now is error.OtherVersion, and `problem` says how.
fn open(init: std.process.Init, path: []const u8, problem: *Problem) !Blocks {
    const io = init.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const size = (try file.stat(io)).size;
    if (size == 0 or size > std.math.maxInt(usize)) return error.NotPreparedBlocks;
    var map: std.Io.File.MemoryMap = try .create(io, file, .{ .len = @intCast(size), .protection = .{ .read = true }, .populate = false });
    errdefer map.destroy(io);
    const parsed = try storyblk.parse(init.arena.allocator(), map.memory);
    for (Prepared.sectionNames) |name| try checkVersion(&parsed, name, Prepared.layoutVersion, Prepared.generatorVersion, problem);
    for ([_][]const u8{ Sprites.entriesSection, Sprites.layersSection }) |name| try checkVersion(&parsed, name, Sprites.layoutVersion, Sprites.generatorVersion, problem);
    // Each section starts on a multiple of 8 in the mapped file.
    const entries = try parsed.section(Sprites.entriesSection, Sprites.layoutVersion);
    const layers = try parsed.section(Sprites.layersSection, Sprites.layoutVersion);
    const sprites = try Sprites.parse(@alignCast(entries.bytes), @alignCast(layers.bytes));
    if (sprites.blockWidth != isometric.blockWidth) {
        problem.* = .{ .blockWidth = sprites.blockWidth };
        return error.OtherVersion;
    }
    const prepared = try Prepared.load(init.gpa, &parsed, sprites.entries.len);
    return .{ .prepared = prepared, .sprites = sprites, .file = file, .map = map };
}

fn checkVersion(file: *const storyblk.File, name: []const u8, layoutVersion: u8, generatorVersion: u16, problem: *Problem) !void {
    const section = try file.section(name, layoutVersion);
    if (section.generatorVersion == generatorVersion) return;
    problem.* = .{ .generatorVersion = .{ .section = name, .file = section.generatorVersion, .this = generatorVersion } };
    return error.OtherVersion;
}

fn noBlocks() void {
    console.warn("could not locate Vintage Story; drawing the map without block colours; pass `--game <folder>`", .{});
}

fn versionText(version: []const u8) []const u8 {
    return if (version.len == 0) "(unknown version)" else version;
}

fn modText(count: usize) []const u8 {
    return if (count == 1) "mod" else "mods";
}

fn secondsSince(io: std.Io, start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.untilNow(io, .awake).toMilliseconds())) / 1000;
}

/// Without `dataPath`, the data folder is looked for in the standard place. A folder that can't
/// be read stops the program.
fn openAssets(init: std.process.Init, game: []const u8, dataPath: ?[]const u8) Assets {
    const io = init.io;
    const data = dataPath orelse Assets.findFolder(init.arena.allocator(), io, init.environ_map, .data);
    var gameDir = std.Io.Dir.cwd().openDir(io, game, .{}) catch |err| console.fail("{s}: could not open the game folder ({s})", .{ game, @errorName(err) });
    defer gameDir.close(io);
    var dataDir: ?std.Io.Dir = if (data) |path| std.Io.Dir.cwd().openDir(io, path, .{}) catch |err|
        console.fail("{s}: could not open the data folder ({s})", .{ path, @errorName(err) }) else null;
    defer if (dataDir) |*dir| dir.close(io);
    return Assets.open(init.gpa, io, gameDir, dataDir) catch |err| switch (err) {
        error.NoAssetsFolder => console.fail("{s}: not a Vintage Story install (missing assets folder)", .{game}),
        else => console.fail("{s}: could not read the assets ({s})", .{ game, @errorName(err) }),
    };
}
