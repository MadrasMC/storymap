//! Storymap's entry point: its commands, each in `cli/`, and what to do when the command line
//! doesn't fit them.
const std = @import("std");
const build_options = @import("build_options");
const console = @import("console.zig");
const render = @import("cli/render.zig");
const prepare = @import("cli/prepare.zig");
const bench = @import("cli/bench.zig");
const args = @import("args");

const program: args.Program = .{ .name = "storymap", .header = "storymap " ++ build_options.version };

const commands = .{
    args.Command(null, render.spec, render.run),
    args.Command("prepare", prepare.spec, prepare.run),
    args.Command("bench", bench.spec, bench.run),
    args.Action(.{ .name = "version", .description = "Show Storymap's version." }, printVersion),
};

pub fn main(init: std.process.Init) !void {
    console.useUtf8();
    defer console.restore();

    var problem: args.Problem = .{};
    const given = try args.ofProcess(init.arena.allocator(), init.minimal.args);
    args.dispatch(program, commands, init.io, init, given, &problem) catch |err| switch (err) {
        error.InvalidArguments => {
            if (problem.kind != .missingArguments) std.debug.print("storymap: {f}\n\n", .{problem});
            std.debug.print("{s}", .{problem.usage});
            console.exit(2);
        },
        else => return err,
    };
}

/// `storymap --version`.
fn printVersion(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("{s}\n", .{program.header});
    try stdout.interface.flush();
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
    _ = @import("vs/Assets.zig");
    _ = @import("vs/Json.zig");
    _ = @import("vs/Wildcard.zig");
    _ = @import("vs/BlockTypes.zig");
    _ = @import("vs/Prepared.zig");
    _ = @import("vs/TextureColours.zig");
    _ = @import("vs/Tint.zig");
    _ = @import("vs/Save.zig");
    _ = @import("cli/render.zig");
    _ = @import("cli/prepare.zig");
    _ = @import("cli/bench.zig");
    _ = @import("renderer/topdown.zig");
    _ = @import("renderer/Style.zig");
    _ = @import("columns.zig");
    _ = @import("console.zig");
    _ = @import("tiles.zig");
    _ = @import("viewer.zig");
}
