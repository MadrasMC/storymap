//! `storymap prepare`: prepares what the map needs from the game's and mods' assets into the
//! blocks folder. A render does the same the first time it needs it (`blocks`).
const std = @import("std");
const Assets = @import("vs").Assets;
const Prepared = @import("vs").Prepared;
const console = @import("console");
const args = @import("args");

pub const gameOption: args.Option = .{ .name = "game", .value = "folder", .description = "The game's install folder, if it isn't in the standard place." };
pub const dataOption: args.Option = .{ .name = "data", .value = "folder", .description = "The game's data folder, if it isn't in the standard place." };

/// What `storymap prepare` takes.
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

/// Prepares the blocks, even if they were prepared before.
pub fn run(init: std.process.Init, parsed: args.Parsed(spec)) !void {
    const folders: Folders = .{
        .game = parsed.value("game"),
        .data = parsed.value("data"),
        .blocks = parsed.positional("folder") orelse Prepared.defaultFolder,
    };
    var prepared = blocks(init, folders, true) orelse unreachable;
    prepared.deinit();
}

/// The prepared blocks for the installed game and mods, prepared now if they weren't yet or
/// `force` is set. Without the game, the newest set prepared before, or else null; `force`
/// then stops the program.
pub fn blocks(init: std.process.Init, folders: Folders, force: bool) ?Prepared {
    const io = init.io;
    const arena = init.arena.allocator();

    const gamePath = folders.game orelse Assets.findFolder(arena, io, init.environ_map, .game) orelse {
        if (force) console.fail("couldn't find Vintage Story; pass its install folder with --game\n", .{});
        var blocksDir = std.Io.Dir.cwd().openDir(io, folders.blocks, .{ .iterate = true }) catch return noBlocks();
        defer blocksDir.close(io);
        const newest = (Prepared.newest(arena, io, blocksDir) catch null) orelse return noBlocks();
        var folder = blocksDir.openDir(io, newest, .{}) catch return noBlocks();
        defer folder.close(io);
        const prepared = Prepared.load(init.gpa, io, folder) catch return noBlocks();
        std.debug.print("blocks: prepared earlier for Vintage Story {s}; the game wasn't found\n", .{prepared.gameVersion});
        return prepared;
    };

    var assets = openAssets(init, gamePath, folders.data);
    defer assets.close(io);
    var keyBuffer: [16]u8 = undefined;
    const key = Prepared.key(&keyBuffer, io, &assets) catch |err| console.fail("can't read the mods ({s})\n", .{@errorName(err)});
    const folderPath = std.fs.path.join(arena, &.{ folders.blocks, key }) catch console.fail("out of memory\n", .{});
    var folder = std.Io.Dir.cwd().createDirPathOpen(io, folderPath, .{}) catch |err|
        console.fail("can't create {s} ({s})\n", .{ folderPath, @errorName(err) });
    defer folder.close(io);

    const mods = assets.sources.items.len - 1;
    const modText = if (mods == 1) "mod" else "mods";
    if (force or !Prepared.exists(io, folder)) {
        const start: std.Io.Timestamp = .now(io, .awake);
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const count = Prepared.prepare(scratch.allocator(), io, &assets, folder) catch |err|
            console.fail("can't prepare the blocks into {s} ({s})\n", .{ folderPath, @errorName(err) });
        const seconds = @as(f64, @floatFromInt(start.untilNow(io, .awake).toMilliseconds())) / 1000;
        std.debug.print("blocks: prepared {} from Vintage Story {s} and {} {s} in {d:.1} s, into {s}\n", .{
            count, assets.version orelse "(unknown version)", mods, modText, seconds, folderPath,
        });
    } else {
        std.debug.print("blocks: Vintage Story {s} and {} {s}, prepared earlier\n", .{ assets.version orelse "(unknown version)", mods, modText });
    }
    return Prepared.load(init.gpa, io, folder) catch |err| console.fail("can't read the blocks prepared in {s} ({s})\n", .{ folderPath, @errorName(err) });
}

fn noBlocks() ?Prepared {
    std.debug.print("storymap: couldn't find Vintage Story, so its blocks aren't known; pass its install folder with --game\n", .{});
    return null;
}

/// The game's assets and mods, from the folders given or else the standard ones. A folder
/// that can't be read stops the program.
fn openAssets(init: std.process.Init, game: []const u8, dataPath: ?[]const u8) Assets {
    const io = init.io;
    const data = dataPath orelse Assets.findFolder(init.arena.allocator(), io, init.environ_map, .data);
    var gameDir = std.Io.Dir.cwd().openDir(io, game, .{}) catch |err| console.fail("can't open the game folder {s} ({s})\n", .{ game, @errorName(err) });
    defer gameDir.close(io);
    var dataDir: ?std.Io.Dir = if (data) |path| std.Io.Dir.cwd().openDir(io, path, .{}) catch |err|
        console.fail("can't open the data folder {s} ({s})\n", .{ path, @errorName(err) }) else null;
    defer if (dataDir) |*dir| dir.close(io);
    return Assets.open(init.gpa, io, gameDir, dataDir) catch |err| switch (err) {
        error.NoAssetsFolder => console.fail("{s} has no assets folder; is it a Vintage Story install?\n", .{game}),
        else => console.fail("can't read the assets in {s} ({s})\n", .{ game, @errorName(err) }),
    };
}
