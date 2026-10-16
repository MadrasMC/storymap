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

const usage =
    \\usage: storymap <save.vcdbs> [output folder]
    \\       storymap extract-assets <output folder> [--game <folder>] [--data <folder>]
    \\       storymap bench <save.vcdbs> [runs]
    \\
    \\Renders a top-down map of a Vintage Story save as tiles in the output folder,
    \\or in out when no folder is given: <folder>/topdown/0/<x>/<y>.png.
    \\Run extract-assets without arguments for its options.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "extract-assets")) return extract.run(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "bench")) return bench.run(init, args[2..]);
    if (args.len < 2 or args.len > 3) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
    const dbPath = args[1];
    const outPath = if (args.len == 3) args[2] else "out";

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
    try topdown.render(allocator, init.io, dbPath, .{ .folder = out }, null);
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
}
