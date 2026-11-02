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
    const gamePath = findGame(init, paths) orelse noGame();
    var assets = openAssets(init, gamePath, paths.data);
    defer assets.close(init.io);
    prepareFile(init, &assets, paths.blocks, hashAssets(init.io, &assets));
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
    const path = paths.blocks;

    const gamePath = findGame(init, paths) orelse {
        if (force) noGame();
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
    const hash = hashAssets(io, &assets);
    const reason = reason: {
        if (force) break :reason "`--prepare`";
        const existing = hashOf(init, path) orelse break :reason "no readable file";
        if (existing != hash) break :reason "the game, its mods or Storymap changed";
        var problem: Problem = .none;
        const found = open(init, path, &problem) catch break :reason "the file could not be opened";
        const mods = assets.sources.items.len - 1;
        console.log("blocks: Vintage Story {s} and {} {s}, prepared earlier ({s})", .{ versionText(assets.version orelse ""), mods, modText(mods), path });
        return found;
    };

    console.log("blocks: preparing: {s} ({s})", .{ reason, path });
    prepareFile(init, &assets, path, hash);
    var problem: Problem = .none;
    return open(init, path, &problem) catch |err| console.fail("{s}: could not read the prepared blocks ({s})", .{ path, @errorName(err) });
}

/// Prepares the blocks from `assets`, writes their sprites to the partial file as they're drawn,
/// and finishes the file at `path`. All it held is freed before it returns. A problem stops the
/// program.
fn prepareFile(init: std.process.Init, assets: *const Assets, path: []const u8, hash: u64) void {
    const io = init.io;
    const mods = assets.sources.items.len - 1;
    const version = versionText(assets.version orelse "");
    storyblk.checkReplaceable(io, std.Io.Dir.cwd(), path) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not read ({s})", .{ path, @errorName(err) }),
    };
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    const start: std.Io.Timestamp = .now(io, .awake);
    var contents = Prepared.prepare(init.gpa, scratch.allocator(), io, assets) catch |err|
        console.fail("{s}: could not prepare the blocks ({s})", .{ path, @errorName(err) });
    console.log("blocks: {} prepared from Vintage Story {s} and {} {s} in {d:.1} s ({s})", .{
        contents.blocks.len, version, mods, modText(mods), secondsSince(io, start), path,
    });
    writeFile(init, &scratch, &contents, path, hash) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not write ({s})", .{ path, @errorName(err) }),
    };
}

/// Writes the file: the sprites as they're drawn, then the sections before them, whose lengths
/// were known all along, once what they're made from can be freed.
fn writeFile(init: std.process.Init, scratch: *std.heap.ArenaAllocator, contents: *Prepared.Contents, path: []const u8, hash: u64) !void {
    const io = init.io;
    const arena = scratch.allocator();
    const start: std.Io.Timestamp = .now(io, .awake);
    const drawables = try arena.alloc(isometric.Drawable, contents.blocks.len);
    for (drawables, contents.blocks) |*drawable, *entry| drawable.* = .{
        .cube = if (entry.block.cube) |*cube| cube else null,
        .shapes = entry.block.shapes,
        .colour = SaveFile.colourOf(&entry.block),
        .turned = entry.block.randomizeRotations,
        .seeThrough = entry.block.seeThrough,
    };
    const plan = try isometric.planSprites(arena, drawables);

    var encoded: std.heap.ArenaAllocator = .init(init.gpa);
    defer encoded.deinit();
    const info = try contents.info(encoded.allocator());
    var partial: storyblk.PartialFile = try .create(io, std.Io.Dir.cwd(), path);
    errdefer partial.discard();
    // Only their lengths matter yet: blocks' sprites aren't known, but their records' sizes are.
    const entryBytes = try encoded.allocator().alloc(u8, Sprites.Sections.entriesLength(plan.count));
    const layout = try encodeSections(encoded.allocator(), contents, entryBytes);

    var layersBuffer: [Sprites.Sections.bufferLength]u8 align(4) = undefined;
    var sprites: Sprites.Sections = .init(io, partial.file, try storyblk.lastOffset(info, &layout), &layersBuffer);
    try isometric.drawSprites(arena, drawables, plan, .deg0, &sprites);
    contents.useSprites(plan.blocks);
    try sprites.flush();
    console.log("sprites: {} drawn in {d:.1} s", .{ sprites.entries.items.len, secondsSince(io, start) });

    const sections = try encodeSections(encoded.allocator(), contents, try sprites.entryBytes(encoded.allocator(), isometric.blockWidth));
    _ = scratch.reset(.free_all);
    try partial.finish(hash, info, &sections, @intCast(sprites.layers.length));
}

/// The game's install folder, as given or in the standard place.
fn findGame(init: std.process.Init, paths: Paths) ?[]const u8 {
    return paths.game orelse Assets.findFolder(init.arena.allocator(), init.io, init.environ_map, .game);
}

fn noGame() noreturn {
    console.fail("could not locate Vintage Story; pass `--game <folder>`", .{});
}

fn hashAssets(io: std.Io, assets: *const Assets) u64 {
    return Prepared.hash(io, assets, spriteFormat) catch |err| console.fail("could not read the mods ({s})", .{@errorName(err)});
}

/// Every section of the file, in the order they're written, with the `sprites` section's bytes
/// `entries`. The other rotations' are reserved, and `sprite_layers`, last, is in the file already.
fn encodeSections(arena: std.mem.Allocator, contents: *const Prepared.Contents, entries: []const u8) ![Prepared.sectionNames.len + Sprites.rotatedSections.len + 2]storyblk.Section {
    var rotated: [Sprites.rotatedSections.len]storyblk.Section = undefined;
    for (&rotated, Sprites.rotatedSections) |*section, name| {
        section.* = .{ .name = name, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = "", .reserved = true };
    }
    return (try contents.encode(arena)) ++
        [1]storyblk.Section{.{ .name = Sprites.entriesSection, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = entries }} ++
        rotated ++
        [1]storyblk.Section{.{ .name = Sprites.layersSection, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = "" }};
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
    for (Prepared.sectionNames, Prepared.sectionLayoutVersions) |name, layout| try checkVersion(&parsed, name, layout, Prepared.generatorVersion, problem);
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
