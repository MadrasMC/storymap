//! `storymap prepare`: prepares what the map needs from the game's and mods' assets, and draws
//! the isometric view's sprites of the blocks, into the prepared blocks file
//! (docs/storyblk/spec.md). A render does the same when the file wasn't prepared from the game
//! and mods it runs with (`blocks`).
const std = @import("std");
const Assets = @import("vs").Assets;
const Prepared = @import("vs").Prepared;
const SaveFile = @import("vs").SaveFile;
const mc = @import("mc");
const isometric = @import("renderer").isometric;
const Sprites = isometric.Sprites;
const storyblk = @import("storyblk");
const console = @import("console");
const args = @import("args");

pub const gameOption: args.Option = .{ .name = "game", .value = "game", .description = "The game's install folder or Minecraft's client jar; or the game: " ++ Prepared.game ++ ", " ++ mc.game ++ " or " ++ mc.game ++ "-<version>, from a folder of that name here if there is one, or else the standard place." };
pub const dataOption: args.Option = .{ .name = "data", .value = "folder", .description = "The game's data folder, if it isn't in the standard place." };

pub const spec: args.Spec = .{
    .options = &.{
        gameOption,
        dataOption,
        .{ .name = "yes", .short = 'y', .description = "Without --game, prepare both games if both are found, without asking." },
    },
    .positionals = &.{.{ .name = "file", .optional = true, .description = "The prepared blocks file: " ++ Prepared.defaultPath ++ " or " ++ mc.Prepared.defaultPath ++ " by default, by the game." }},
    .description = "Prepares what the map needs from the game's and mods' assets into the prepared blocks file, even if it was prepared before.",
};

/// Where the game, its mods and the prepared blocks are; the blocks, where they're given.
pub const Paths = struct {
    game: ?[]const u8 = null,
    data: ?[]const u8 = null,
    blocks: ?[]const u8 = null,
};

pub fn run(init: std.process.Init, parsed: args.Parsed(spec)) !void {
    const paths: Paths = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.positional("file"),
    };
    if (paths.game != null) return prepareGame(init, paths, findGame(init, paths) orelse noGame());

    const found = [2]?Game{ standardVintageStory(init), standardMinecraft(init) };
    if (found[0] == null and found[1] == null)
        console.fail("could not locate Vintage Story or Minecraft; pass `--game <game>`", .{});
    if (found[0] == null or found[1] == null) return prepareGame(init, paths, (found[0] orelse found[1]).?);
    if (paths.blocks) |path|
        console.fail("{s}: found both Vintage Story and Minecraft; pass `--game " ++ Prepared.game ++ "` or `--game " ++ mc.game ++ "` to say which this file is for", .{path});
    // The answers for each game, by `found`, then for both.
    const answers = [_][]const []const u8{ &.{ "v", Prepared.game }, &.{ "m", mc.game }, &.{ "b", "both", "y", "yes" } };
    const both = 2;
    const chosen: usize = if (parsed.flag("yes")) both else choice: {
        if (!console.canAsk(init.io))
            console.fail("found both Vintage Story and Minecraft, and no terminal to ask which; pass `--game " ++ Prepared.game ++ "`, `--game " ++ mc.game ++ "`, or `--yes` to prepare both", .{});
        console.warn("found both Vintage Story and Minecraft; pass `--yes` to prepare both", .{});
        break :choice console.choose(init.io, "prepare Vintage Story, Minecraft or both?", .{}, &answers) orelse console.exit(1);
    };
    if (chosen == both and parsed.flag("yes")) console.warn("found both Vintage Story and Minecraft; preparing both", .{});
    for (found, 0..) |game, i| if (chosen == both or chosen == i) prepareGame(init, paths, game.?);
}

fn prepareGame(init: std.process.Init, paths: Paths, game: Game) void {
    switch (game) {
        .vintagestory => |folder| {
            var assets = openAssets(init, folder, paths.data);
            defer assets.close(init.io);
            prepareFile(init, &assets, paths.blocks orelse Prepared.defaultPath, hashAssets(init.io, &assets));
        },
        .minecraft => |jarPath| prepareMinecraft(init, jarPath, paths.blocks orelse mc.Prepared.defaultPath),
    }
}

/// The highest release in the launcher's game folder, if there's one.
fn standardMinecraft(init: std.process.Init) ?Game {
    const arena = init.arena.allocator();
    const folder = mc.Jar.standardFolder(arena, init.io, init.environ_map) orelse return null;
    const jar = mc.Jar.inGameFolder(arena, init.io, folder, null) catch return null;
    return .{ .minecraft = jar orelse return null };
}

/// Prepares Minecraft's block states from its client jar, writes their sprites to the partial
/// file as they're drawn, and finishes the file at `path`. A problem stops the program.
fn prepareMinecraft(init: std.process.Init, jarPath: []const u8, path: []const u8) void {
    const io = init.io;
    checkReplaceable(init, path);
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var jar = mc.Jar.open(arena, io, jarPath) catch |err| switch (err) {
        error.NotAClientJar => console.fail("{s}: not a Minecraft client jar (no block assets)", .{jarPath}),
        else => console.fail("{s}: could not read ({s})", .{ jarPath, @errorName(err) }),
    };
    defer jar.close(io);
    const hash = mc.Prepared.hash(io, &jar, spriteFormat) catch |err| console.fail("{s}: could not read ({s})", .{ jarPath, @errorName(err) });
    const start: std.Io.Timestamp = .now(io, .awake);
    var problems: mc.Blocks.Problems = .{};
    var contents = mc.Prepared.prepare(arena, io, &jar, &problems) catch |err|
        console.fail("{s}: could not prepare the blocks ({s})", .{ path, @errorName(err) });
    for (problems.blockStates.items) |file| console.warn("{s}: could not read; its block is left out", .{file});
    for (problems.models.keys()) |model| console.warn("{s}: could not read; left out of the blocks that use it", .{model});
    for (problems.biomes.items) |file| console.warn("{s}: could not read; its biome is drawn as plains", .{file});
    console.log("blocks: {} block states prepared from Minecraft {s} in {d:.1} s ({s})", .{
        contents.states.len, versionText(jar.version), secondsSince(io, start), path,
    });
    const drawables = arena.alloc(isometric.Drawable, contents.states.len) catch console.fail("{s}: out of memory", .{path});
    for (drawables, contents.states) |*drawable, *state| drawable.* = .{
        .cube = if (state.cube) |*cube| cube else null,
        .shapes = state.shapes,
        .colour = if (state.colour) |i| contents.textures[i].average else @splat(0x80),
        .seeThrough = state.seeThrough,
    };
    writeFile(mc.Prepared.Contents, init, &scratch, &contents, drawables, path, hash) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not write ({s})", .{ path, @errorName(err) }),
    };
}

/// Stops the program if `path` is there and isn't a prepared blocks file.
fn checkReplaceable(init: std.process.Init, path: []const u8) void {
    storyblk.checkReplaceable(init.io, std.Io.Dir.cwd(), path) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not read ({s})", .{ path, @errorName(err) }),
    };
}

/// The prepared blocks, as a game's reader loads them (`Loaded`, its `Prepared`), and the
/// isometric view's sprites of them, mapped from their file.
pub fn Blocks(comptime Loaded: type) type {
    return struct {
        prepared: Loaded,
        sprites: Sprites,
        file: std.Io.File,
        map: std.Io.File.MemoryMap,

        pub fn deinit(self: *@This(), io: std.Io) void {
            self.prepared.deinit();
            self.map.destroy(io);
            self.file.close(io);
        }
    };
}

const spriteFormat: storyblk.SpriteFormat = .{
    .generatorVersion = Sprites.generatorVersion,
    .layoutVersion = Sprites.layoutVersion,
    .blockWidth = isometric.blockWidth,
};

/// The blocks for the installed game and mods, from the prepared blocks file, prepared into it
/// first if it wasn't prepared from them or `force` is set. Without the game, the file as it is,
/// if this Storymap made it the way it would now, or else null; `force` then stops the program.
pub fn blocks(init: std.process.Init, paths: Paths, force: bool) ?Blocks(Prepared) {
    const io = init.io;
    const path = paths.blocks orelse Prepared.defaultPath;

    const game = findGame(init, paths);
    if (game) |found| if (found == .minecraft) console.fail("`--game {s}`: a Vintage Story save needs Vintage Story", .{paths.game.?});
    const gamePath = if (game) |found| found.vintagestory else {
        if (force) noGame();
        const found = openWithoutGame(Prepared, init, path, "Vintage Story", "<folder>") orelse return null;
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
        const found = open(Prepared, init, path, &problem) catch break :reason "the file could not be opened";
        const mods = assets.sources.items.len - 1;
        console.log("blocks: Vintage Story {s} and {} {s}, prepared earlier ({s})", .{ versionText(assets.version orelse ""), mods, modText(mods), path });
        return found;
    };

    console.log("blocks: preparing: {s} ({s})", .{ reason, path });
    prepareFile(init, &assets, path, hash);
    var problem: Problem = .none;
    return open(Prepared, init, path, &problem) catch |err| console.fail("{s}: could not read the prepared blocks ({s})", .{ path, @errorName(err) });
}

/// Minecraft's blocks for a world last saved by Minecraft `version`, from the prepared blocks
/// file, prepared into it first if it wasn't prepared from the client jar or `force` is set.
/// The jar is the one `--game` names, the world's version for `--game minecraft`, and without
/// `--game`, the world's version in the launcher's game folder. Without the jar, the file as it
/// is, if this Storymap made it the way it would now, or else null; `force` then stops the
/// program.
pub fn minecraftBlocks(init: std.process.Init, paths: Paths, version: []const u8, force: bool) ?Blocks(mc.Prepared) {
    const io = init.io;
    const arena = init.arena.allocator();
    const path = paths.blocks orelse mc.Prepared.defaultPath;
    const wanted: ?[]const u8 = if (version.len > 0) version else null;
    const found: ?[]const u8 = if (paths.game) |given| jar: {
        if (std.mem.eql(u8, given, mc.game)) {
            break :jar findMinecraft(init, given, wanted) catch null orelse
                console.fail("`--game {s}`: could not locate Minecraft {s}, the world's version; pass `--game minecraft-<version>` or `--game <jar>`", .{ given, versionText(version) });
        }
        const game = findGame(init, paths) orelse console.fail("`--game {s}`: a Minecraft world needs Minecraft", .{given});
        if (game != .minecraft) console.fail("`--game {s}`: a Minecraft world needs Minecraft", .{given});
        break :jar game.minecraft;
    } else standard: {
        const folder = mc.Jar.standardFolder(arena, io, init.environ_map) orelse break :standard null;
        break :standard mc.Jar.inGameFolder(arena, io, folder, wanted) catch null;
    };
    const jarPath = found orelse {
        if (force) console.fail("could not locate Minecraft {s}, the world's version; pass `--game <jar>`", .{versionText(version)});
        const opened = openWithoutGame(mc.Prepared, init, path, "Minecraft", "<jar>") orelse return null;
        console.log("blocks: Minecraft {s}, prepared earlier ({s}; game not found)", .{ versionText(opened.prepared.gameVersion), path });
        return opened;
    };

    const hash = hash: {
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        var jar = mc.Jar.open(scratch.allocator(), io, jarPath) catch |err| switch (err) {
            error.NotAClientJar => console.fail("{s}: not a Minecraft client jar (no block assets)", .{jarPath}),
            else => console.fail("{s}: could not read ({s})", .{ jarPath, @errorName(err) }),
        };
        defer jar.close(io);
        break :hash mc.Prepared.hash(io, &jar, spriteFormat) catch |err| console.fail("{s}: could not read ({s})", .{ jarPath, @errorName(err) });
    };
    const reason = reason: {
        if (force) break :reason "`--prepare`";
        const existing = hashOf(init, path) orelse break :reason "no readable file";
        if (existing != hash) break :reason "the game or Storymap changed";
        var problem: Problem = .none;
        const opened = open(mc.Prepared, init, path, &problem) catch break :reason "the file could not be opened";
        console.log("blocks: Minecraft {s}, prepared earlier ({s})", .{ versionText(opened.prepared.gameVersion), path });
        return opened;
    };

    console.log("blocks: preparing: {s} ({s})", .{ reason, path });
    prepareMinecraft(init, jarPath, path);
    var problem: Problem = .none;
    return open(mc.Prepared, init, path, &problem) catch |err| console.fail("{s}: could not read the prepared blocks ({s})", .{ path, @errorName(err) });
}

/// The prepared blocks file at `path` as it is, for a render without the game to prepare it
/// from (`game`, passed as `--game <hint>`); null, with a warning, for one that can't be read or
/// wasn't made the way this Storymap would.
fn openWithoutGame(comptime Loaded: type, init: std.process.Init, path: []const u8, comptime game: []const u8, comptime hint: []const u8) ?Blocks(Loaded) {
    var problem: Problem = .none;
    return open(Loaded, init, path, &problem) catch |err| {
        switch (problem) {
            .none => switch (err) {
                error.FileNotFound => console.warn("could not locate " ++ game ++ "; drawing the map without block colours; pass `--game " ++ hint ++ "`", .{}),
                error.NotPreparedBlocks => console.warn("{s}: not a prepared blocks file; drawing the map without block colours", .{path}),
                else => console.warn("{s}: could not read the prepared blocks ({s}); drawing the map without block colours", .{ path, @errorName(err) }),
            },
            .game => |other| console.warn("{s}: prepared for {s}, not " ++ game ++ "; drawing the map without block colours", .{ path, other }),
            .generatorVersion => |other| console.warn("{s}: prepared by another Storymap (its {s} section is version {}, this one makes {}); drawing the map without block colours; pass `--game " ++ hint ++ "` to prepare it again", .{ path, other.section, other.file, other.this }),
            .blockWidth => |width| console.warn("{s}: sprites {} pixels wide, this Storymap's are {}; drawing the map without block colours; pass `--game " ++ hint ++ "` to prepare it again", .{ path, width, isometric.blockWidth }),
        }
        return null;
    };
}

/// Prepares the blocks from `assets`, writes their sprites to the partial file as they're drawn,
/// and finishes the file at `path`. All it held is freed before it returns. A problem stops the
/// program.
fn prepareFile(init: std.process.Init, assets: *const Assets, path: []const u8, hash: u64) void {
    const io = init.io;
    const mods = assets.sources.items.len - 1;
    const version = versionText(assets.version orelse "");
    checkReplaceable(init, path);
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    const start: std.Io.Timestamp = .now(io, .awake);
    var contents = Prepared.prepare(init.gpa, scratch.allocator(), io, assets) catch |err|
        console.fail("{s}: could not prepare the blocks ({s})", .{ path, @errorName(err) });
    console.log("blocks: {} prepared from Vintage Story {s} and {} {s} in {d:.1} s ({s})", .{
        contents.blocks.len, version, mods, modText(mods), secondsSince(io, start), path,
    });
    const drawables = scratch.allocator().alloc(isometric.Drawable, contents.blocks.len) catch console.fail("{s}: out of memory", .{path});
    for (drawables, contents.blocks) |*drawable, *entry| drawable.* = .{
        .cube = if (entry.block.cube) |*cube| cube else null,
        .shapes = entry.block.shapes,
        .colour = SaveFile.colourOf(&entry.block),
        .turned = entry.block.randomizeRotations,
        .seeThrough = entry.block.seeThrough,
    };
    writeFile(Prepared.Contents, init, &scratch, &contents, drawables, path, hash) catch |err| switch (err) {
        error.NotPreparedBlocks => console.fail("{s}: not a prepared blocks file; not replacing it", .{path}),
        else => console.fail("{s}: could not write ({s})", .{ path, @errorName(err) }),
    };
}

/// Writes the file: the sprites of `drawables` as they're drawn, one block state each, then the
/// sections before them, whose lengths were known all along, once what they're made from can be
/// freed. `Contents` is a game's: Vintage Story's or Minecraft's `Prepared.Contents`.
fn writeFile(comptime Contents: type, init: std.process.Init, scratch: *std.heap.ArenaAllocator, contents: *Contents, drawables: []const isometric.Drawable, path: []const u8, hash: u64) !void {
    const io = init.io;
    const arena = scratch.allocator();
    const start: std.Io.Timestamp = .now(io, .awake);
    const plan = try isometric.planSprites(arena, drawables);

    var encoded: std.heap.ArenaAllocator = .init(init.gpa);
    defer encoded.deinit();
    const info = try contents.info(encoded.allocator());
    var partial: storyblk.PartialFile = try .create(io, std.Io.Dir.cwd(), path);
    errdefer partial.discard();
    const entries = try encoded.allocator().alignedAlloc(u8, .@"4", Sprites.Sections.entriesLength(plan.count));
    // Only their lengths matter yet: blocks' sprites aren't known, but their records' sizes are.
    const layout = try encodeSections(encoded.allocator(), contents, entries);

    var layersBuffer: [Sprites.Sections.bufferLength]u8 align(4) = undefined;
    var sprites: Sprites.Sections = .init(io, partial.file, try storyblk.lastOffset(info, &layout), &layersBuffer, entries, isometric.blockWidth);
    {
        // From `gpa`, freed once drawn: in an arena, this would size a block far beyond what's used.
        defer sprites.offsets.deinit(init.gpa);
        try sprites.ensureCapacity(init.gpa);
        try isometric.drawSprites(arena, drawables, plan, &sprites);
        contents.useSprites(plan.blocks);
        try sprites.flush();
        console.log("sprites: {} drawn in {d:.1} s, {} unique", .{ sprites.count, secondsSince(io, start), sprites.offsets.count() });
    }

    const sections = try encodeSections(encoded.allocator(), contents, entries);
    _ = scratch.reset(.free_all);
    try partial.finish(hash, info, &sections, @intCast(sprites.layers.length));
}

/// A game's install, as `--game` names it.
const Game = union(enum) {
    /// The install folder.
    vintagestory: []const u8,
    /// The client jar.
    minecraft: []const u8,
};

/// The game `--game` names: a Vintage Story install folder, Minecraft's client jar or its game
/// folder, or a game's name, for a folder of that name here if there is one, or else the
/// standard place. Without `--game`, Vintage Story in the standard place. A Minecraft that isn't
/// found stops the program.
fn findGame(init: std.process.Init, paths: Paths) ?Game {
    const io = init.io;
    const arena = init.arena.allocator();
    const given = paths.game orelse return standardVintageStory(init);
    if (std.mem.eql(u8, given, mc.game) or std.mem.startsWith(u8, given, mc.game ++ "-")) {
        const version: ?[]const u8 = if (given.len > mc.game.len) given[mc.game.len + 1 ..] else null;
        return .{ .minecraft = findMinecraft(init, given, version) catch null orelse noMinecraft(given) };
    }
    if (std.mem.eql(u8, given, Prepared.game) and !isFolder(io, given)) return standardVintageStory(init);
    if (std.ascii.endsWithIgnoreCase(given, ".jar")) return .{ .minecraft = given };
    if (mc.Jar.isGameFolder(io, given))
        return .{ .minecraft = mc.Jar.inGameFolder(arena, io, given, null) catch null orelse noMinecraft(given) };
    return .{ .vintagestory = given };
}

fn standardVintageStory(init: std.process.Init) ?Game {
    const folder = Assets.findFolder(init.arena.allocator(), init.io, init.environ_map, .game) orelse return null;
    return .{ .vintagestory = folder };
}

/// The jar for `--game minecraft` or `minecraft-<version>` (`name`): from a folder of that name
/// here, a game folder for `minecraft` and a version's folder for `minecraft-<version>`, or else
/// from the launcher's game folder; without a version, its highest release.
fn findMinecraft(init: std.process.Init, name: []const u8, version: ?[]const u8) !?[]const u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    if (isFolder(io, name)) {
        if (version) |wanted| return mc.Jar.inVersionFolder(arena, io, name, wanted);
        return mc.Jar.inGameFolder(arena, io, name, null);
    }
    const folder = mc.Jar.standardFolder(arena, io, init.environ_map) orelse return null;
    return mc.Jar.inGameFolder(arena, io, folder, version);
}

fn noMinecraft(given: []const u8) noreturn {
    console.fail("`--game {s}`: could not locate Minecraft's client jar; pass `--game <jar>`", .{given});
}

pub fn isFolder(io: std.Io, path: []const u8) bool {
    var folder = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    folder.close(io);
    return true;
}

fn noGame() noreturn {
    console.fail("could not locate Vintage Story; pass `--game <folder>`", .{});
}

fn hashAssets(io: std.Io, assets: *const Assets) u64 {
    return Prepared.hash(io, assets, spriteFormat) catch |err| console.fail("could not read the mods ({s})", .{@errorName(err)});
}

/// Every section of the file, in the order they're written, with the `sprites` section's bytes
/// `entries`. `sprite_layers`, last, is in the file already.
fn encodeSections(arena: std.mem.Allocator, contents: anytype, entries: []const u8) ![std.meta.Child(@TypeOf(contents)).sectionCount + 2]storyblk.Section {
    return (try contents.encode(arena)) ++ [2]storyblk.Section{
        .{ .name = Sprites.entriesSection, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = entries },
        .{ .name = Sprites.layersSection, .layoutVersion = Sprites.layoutVersion, .generatorVersion = Sprites.generatorVersion, .bytes = "" },
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
    /// Prepared for this game instead (`info.game`).
    game: []const u8,
    /// A section made by other code than this Storymap's (spec §7).
    generatorVersion: struct { section: []const u8, file: u16, this: u16 },
    /// Sprites drawn for a cube's square this many pixels wide.
    blockWidth: u16,
};

/// The prepared blocks file at `path`, mapped and loaded as a game's reader loads them
/// (`Loaded`, its `Prepared`). One made for another game, or other than the way this Storymap
/// makes it now, is error.OtherVersion, and `problem` says how.
fn open(comptime Loaded: type, init: std.process.Init, path: []const u8, problem: *Problem) !Blocks(Loaded) {
    const io = init.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const size = (try file.stat(io)).size;
    if (size == 0 or size > std.math.maxInt(usize)) return error.NotPreparedBlocks;
    var map: std.Io.File.MemoryMap = try .create(io, file, .{ .len = @intCast(size), .protection = .{ .read = true }, .populate = false });
    errdefer map.destroy(io);
    const parsed = try storyblk.parse(init.arena.allocator(), map.memory);
    if (!std.mem.eql(u8, parsed.info.game, Loaded.game)) {
        // Its name is in the file, which is closed before `problem` is read.
        problem.* = .{ .game = try init.arena.allocator().dupe(u8, parsed.info.game) };
        return error.OtherVersion;
    }
    for (storyblk.Tables.names, storyblk.Tables.layoutVersions) |name, layout| try checkVersion(&parsed, name, layout, Loaded.generatorVersion, problem);
    for ([_][]const u8{ Sprites.entriesSection, Sprites.layersSection }) |name| try checkVersion(&parsed, name, Sprites.layoutVersion, Sprites.generatorVersion, problem);
    // Each section starts on a multiple of 8 in the mapped file.
    const entries = try parsed.section(Sprites.entriesSection, Sprites.layoutVersion);
    const layers = try parsed.section(Sprites.layersSection, Sprites.layoutVersion);
    const sprites = try Sprites.parse(@alignCast(entries.bytes), @alignCast(layers.bytes));
    if (sprites.blockWidth != isometric.blockWidth) {
        problem.* = .{ .blockWidth = sprites.blockWidth };
        return error.OtherVersion;
    }
    const prepared = try Loaded.load(init.gpa, &parsed, sprites.count);
    return .{ .prepared = prepared, .sprites = sprites, .file = file, .map = map };
}

fn checkVersion(file: *const storyblk.File, name: []const u8, layoutVersion: u8, generatorVersion: u16, problem: *Problem) !void {
    const section = try file.section(name, layoutVersion);
    if (section.generatorVersion == generatorVersion) return;
    problem.* = .{ .generatorVersion = .{ .section = name, .file = section.generatorVersion, .this = generatorVersion } };
    return error.OtherVersion;
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
