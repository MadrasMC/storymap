const std = @import("std");
const extract = @import("vs/extract.zig");
const Save = @import("vs/Save.zig");
const bench = @import("bench.zig");
const topdown = @import("renderer/topdown.zig");
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

    var out = std.Io.Dir.cwd().createDirPathOpen(init.io, outPath, .{}) catch |err| {
        std.debug.print("storymap: can't create {s} ({s})\n", .{ outPath, @errorName(err) });
        std.process.exit(1);
    };
    defer out.close(init.io);
    const save = try Save.open(allocator, init.io, dbPath);
    defer save.close(allocator);
    try topdown.render(Save, allocator, init.io, &save, .{ .folder = out }, .{ .theme = theme });
}

fn exitWithUsage() noreturn {
    std.debug.print(usage, .{});
    std.process.exit(2);
}

// Every file with tests, so `zig build test` runs them all.
test {
    _ = @import("sqlite.zig");
    _ = @import("ProtoBuf.zig");
    _ = @import("vs/Compression.zig");
    _ = @import("vs/Chunk.zig");
    _ = @import("vs/MapChunk.zig");
    _ = @import("vs/GameData.zig");
    _ = @import("vs/TreeAttribute.zig");
    _ = @import("vs/BlockEntity.zig");
    _ = @import("vs/extract.zig");
    _ = @import("vs/Save.zig");
    _ = @import("bench.zig");
    _ = @import("renderer/topdown.zig");
    _ = @import("columns.zig");
    _ = @import("tiles.zig");
    _ = @import("viewer.zig");
}
