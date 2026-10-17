const std = @import("std");
const DB = @import("sqlite.zig");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");
const extract = @import("extract.zig");
const bench = @import("bench.zig");
const topdown = @import("renderer/topdown.zig");
const GameData = @import("GameData.zig");
const viewer = @import("viewer.zig");

const usage =
    \\usage: storymap <save.vcdbs> [output folder] [--theme <theme>]
    \\       storymap extract-assets <output folder> [--game <folder>] [--data <folder>]
    \\       storymap bench <save.vcdbs> [runs]
    \\
    \\Renders a top-down map of a Vintage Story save as tiles in the output folder,
    \\or in out when no folder is given, with index.html beside them to view it.
    \\--theme draws the page around the map: printed (the default), plain, or the
    \\folder of a theme of your own (see docs/themes.md).
    \\Run extract-assets without arguments for its options.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "extract-assets")) return extract.run(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "bench")) return bench.run(init, args[2..]);

    // The save and the output folder in order, and --theme anywhere among them.
    var paths: [2][]const u8 = undefined;
    var pathCount: usize = 0;
    var themeName: []const u8 = "printed";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--theme")) {
            i += 1;
            if (i == args.len) exitWithUsage();
            themeName = args[i];
        } else {
            if (pathCount == paths.len) exitWithUsage();
            paths[pathCount] = args[i];
            pathCount += 1;
        }
    }
    if (pathCount == 0) exitWithUsage();
    const dbPath = paths[0];
    const outPath = if (pathCount == 2) paths[1] else "out";

    const theme = viewer.loadTheme(init.arena.allocator(), init.io, themeName) catch |err| {
        switch (err) {
            error.ThemeStyleEndsItsElement => std.debug.print("storymap: {s}/theme.css can't contain </style: it would end the theme's style in the page early\n", .{themeName}),
            error.ThemeScriptEndsItsElement => std.debug.print("storymap: {s}/theme.js can't contain </script: it would end the theme's script in the page early\n", .{themeName}),
            else => std.debug.print("storymap: there's no theme {s}: it isn't printed or plain, or a folder with theme.css and theme.js ({s})\n", .{ themeName, @errorName(err) }),
        }
        std.process.exit(1);
    };

    // The immutable open ignores the save's -wal file. A non-empty one holds changes the
    // game hasn't written into the save yet, because it's still running or it crashed.
    const walPath = try std.mem.concat(allocator, u8, &.{ dbPath, "-wal" });
    defer allocator.free(walPath);
    if (std.Io.Dir.cwd().statFile(init.io, walPath, .{})) |wal| {
        if (wal.size > 0) std.debug.print("storymap: {s} has unsaved changes (is the game running?); they won't be on the map\n", .{dbPath});
    } else |_| {}

    var out = std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err| {
        std.debug.print("storymap: can't create {s} ({s})\n", .{ outPath, @errorName(err) });
        std.process.exit(1);
    };
    defer out.close(init.io);
    try topdown.render(allocator, init.io, dbPath, .{ .folder = out }, .{ .theme = theme });
}

fn exitWithUsage() noreturn {
    std.debug.print(usage, .{});
    std.process.exit(2);
}

test {
    _ = GameData;
    _ = @import("MapChunk.zig");
    _ = ProtoBuf;
    _ = VS;
    _ = Chunk;
    _ = DB;
    _ = extract;
    _ = bench;
    _ = topdown;
    _ = @import("tiles.zig");
    _ = @import("viewer.zig");
}
