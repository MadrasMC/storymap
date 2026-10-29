//! `storymap prepare`: prepares what the map needs from the game's and mods' assets into the
//! blocks folder, and draws the isometric view's sprites of the blocks beside them. A render
//! does the same the first time it needs it (`blocks`).
const std = @import("std");
const Assets = @import("vs").Assets;
const Prepared = @import("vs").Prepared;
const SaveFile = @import("vs").SaveFile;
const isometric = @import("renderer").isometric;
const Sprites = isometric.Sprites;
const console = @import("console");
const args = @import("args");

pub const gameOption: args.Option = .{ .name = "game", .value = "folder", .description = "The game's install folder, if it isn't in the standard place." };
pub const dataOption: args.Option = .{ .name = "data", .value = "folder", .description = "The game's data folder, if it isn't in the standard place." };

pub const spec: args.Spec = .{
    .options = &.{ gameOption, dataOption },
    .positionals = &.{.{ .name = "folder", .optional = true, .description = "The blocks folder: blocks by default." }},
    .description = "Prepares what the map needs from the game's and mods' assets into the blocks folder, even if it was prepared before.",
};

/// Where the game, its mods and the prepared blocks are.
pub const Folders = struct {
    game: ?[]const u8 = null,
    data: ?[]const u8 = null,
    blocks: []const u8 = Prepared.defaultFolder,
};

pub fn run(init: std.process.Init, parsed: args.Parsed(spec)) !void {
    const folders: Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.positional("folder") orelse Prepared.defaultFolder,
    };
    var prepared = blocks(init, folders, true) orelse unreachable;
    prepared.deinit(init.io);
}

/// The prepared blocks, and the isometric view's sprites of them, mapped from their file.
pub const Blocks = struct {
    prepared: Prepared,
    sprites: Sprites,
    file: std.Io.File,
    map: std.Io.File.MemoryMap,

    pub fn deinit(self: *Blocks, io: std.Io) void {
        self.map.destroy(io);
        self.file.close(io);
        self.prepared.deinit();
    }
};

/// The blocks for the installed game and mods, prepared now if they weren't yet or `force` is
/// set. Without the game, the newest set prepared before, or else null; `force` then stops the
/// program.
pub fn blocks(init: std.process.Init, folders: Folders, force: bool) ?Blocks {
    const io = init.io;
    const arena = init.arena.allocator();

    const gamePath = folders.game orelse Assets.findFolder(arena, io, init.environ_map, .game) orelse {
        if (force) console.fail("could not locate Vintage Story; pass `--game <folder>`", .{});
        var blocksDir = std.Io.Dir.cwd().openDir(io, folders.blocks, .{ .iterate = true }) catch return noBlocks();
        defer blocksDir.close(io);
        const newest = (Prepared.newest(arena, io, blocksDir) catch null) orelse return noBlocks();
        var folder = blocksDir.openDir(io, newest, .{}) catch return noBlocks();
        defer folder.close(io);
        const prepared = Prepared.load(init.gpa, io, folder, .{ .drawing = false }) catch return noBlocks();
        console.log("blocks: prepared earlier for Vintage Story {s} (game not found)", .{prepared.gameVersion});
        return withSprites(init, prepared, folder, newest, false);
    };

    var assets = openAssets(init, gamePath, folders.data);
    defer assets.close(io);
    var keyBuffer: [16]u8 = undefined;
    const key = Prepared.key(&keyBuffer, io, &assets) catch |err| console.fail("could not read the mods ({s})", .{@errorName(err)});
    const folderPath = std.fs.path.join(arena, &.{ folders.blocks, key }) catch console.fail("out of memory", .{});
    var folder = std.Io.Dir.cwd().createDirPathOpen(io, folderPath, .{}) catch |err|
        console.fail("{s}: could not create ({s})", .{ folderPath, @errorName(err) });
    defer folder.close(io);

    const mods = assets.sources.items.len - 1;
    const modText = if (mods == 1) "mod" else "mods";
    const preparing = force or !Prepared.exists(io, folder);
    if (preparing) {
        const start: std.Io.Timestamp = .now(io, .awake);
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const count = Prepared.prepare(scratch.allocator(), io, &assets, folder) catch |err|
            console.fail("{s}: could not prepare the blocks ({s})", .{ folderPath, @errorName(err) });
        const seconds = @as(f64, @floatFromInt(start.untilNow(io, .awake).toMilliseconds())) / 1000;
        console.log("blocks: {} prepared from Vintage Story {s} and {} {s} in {d:.1} s ({s})", .{
            count, assets.version orelse "(unknown version)", mods, modText, seconds, folderPath,
        });
    } else {
        console.log("blocks: Vintage Story {s} and {} {s}, prepared earlier", .{ assets.version orelse "(unknown version)", mods, modText });
    }
    const prepared = Prepared.load(init.gpa, io, folder, .{ .drawing = false }) catch |err| console.fail("{s}: could not read the prepared blocks ({s})", .{ folderPath, @errorName(err) });
    return withSprites(init, prepared, folder, folderPath, preparing);
}

/// `prepared` with its sprites, from `folder`, drawn first if `draw` is set or the file isn't
/// there or is of another version (`Sprites.version`). A render needs only the sprites, so
/// `prepared` can leave out what drawing them needs.
fn withSprites(init: std.process.Init, prepared: Prepared, folder: std.Io.Dir, folderPath: []const u8, draw: bool) Blocks {
    const io = init.io;
    if (!draw) if (mapSprites(io, folder)) |mapped| {
        var out = mapped;
        out.prepared = prepared;
        return out;
    } else |_| {};
    const start: std.Io.Timestamp = .now(io, .awake);
    const count = drawSprites(init, folder) catch |err|
        console.fail("{s}: could not draw the blocks' sprites ({s})", .{ folderPath, @errorName(err) });
    const seconds = @as(f64, @floatFromInt(start.untilNow(io, .awake).toMilliseconds())) / 1000;
    console.log("sprites: {} drawn in {d:.1} s", .{ count, seconds });
    var mapped = mapSprites(io, folder) catch |err|
        console.fail("{s}: could not read the blocks' sprites ({s})", .{ folderPath, @errorName(err) });
    mapped.prepared = prepared;
    return mapped;
}

/// Draws the sprites of every block prepared in `folder` into it, written beside their name
/// first so the file is never left half written. Returns how many there are.
fn drawSprites(init: std.process.Init, folder: std.Io.Dir) !usize {
    const io = init.io;
    var prepared = try Prepared.load(init.gpa, io, folder, .{});
    defer prepared.deinit();
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const drawables = try arena.alloc(isometric.Drawable, prepared.blocks.count());
    var each = prepared.blocks.valueIterator();
    while (each.next()) |block| drawables[block.index] = .{
        .cube = if (block.cube) |*cube| cube else null,
        .shapes = block.shapes,
        .colour = SaveFile.colourOf(block),
        .turned = block.randomizeRotations,
    };
    const partial = Sprites.fileName ++ ".partial";
    const file = try folder.createFile(io, partial, .{});
    const count = count: {
        defer file.close(io);
        var buffer: [1 << 16]u8 = undefined;
        var writer = file.writer(io, &buffer);
        const count = try isometric.drawSprites(arena, drawables, &writer.interface);
        try writer.interface.flush();
        break :count count;
    };
    try folder.rename(partial, folder, Sprites.fileName, io);
    return count;
}

/// `pictures.bin` in `folder`, mapped, without its prepared blocks yet.
fn mapSprites(io: std.Io, folder: std.Io.Dir) !Blocks {
    const file = try folder.openFile(io, Sprites.fileName, .{});
    errdefer file.close(io);
    const size = (try file.stat(io)).size;
    if (size == 0 or size > std.math.maxInt(usize)) return error.NotSprites;
    var map: std.Io.File.MemoryMap = try .create(io, file, .{ .len = @intCast(size), .protection = .{ .read = true }, .populate = false });
    errdefer map.destroy(io);
    return .{ .prepared = undefined, .sprites = try Sprites.parse(map.memory), .file = file, .map = map };
}

fn noBlocks() ?Blocks {
    console.warn("could not locate Vintage Story; drawing the map without block colours; pass `--game <folder>`", .{});
    return null;
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
