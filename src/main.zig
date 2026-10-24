//! Storymap's entry point: runs the commands from `cli`, and reports a command line that
//! doesn't fit them.
const std = @import("std");
const build_options = @import("build_options");
const console = @import("console");
const cli = @import("cli");
const args = @import("args");

const render = cli.render;
const prepare = cli.prepare;
const bench = cli.bench;

pub const std_options: std.Options = .{ .logFn = console.log };

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

fn printVersion(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("{s}\n", .{program.header});
    try stdout.interface.flush();
}
