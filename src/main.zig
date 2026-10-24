//! Storymap's entry point: runs the commands from `cli`, and reports a command line that
//! doesn't fit them.
const std = @import("std");
const build_options = @import("build_options");
const console = @import("console");
const cli = @import("cli");
const args = @import("args");

const render = cli.render;
const prepare = cli.prepare;

pub const std_options: std.Options = .{ .logFn = console.logFn };

const program: args.Program = .{ .name = "storymap", .header = "storymap " ++ build_options.version };

const commands = .{
    args.Command(null, render.spec, render.run),
    args.Command("prepare", prepare.spec, prepare.run),
    args.Action(.{ .name = "version", .description = "Show Storymap's version." }, printVersion),
};

pub fn main(init: std.process.Init) !void {
    console.useUtf8();
    defer console.restore();

    var problem: args.Problem = .{};
    const given = try args.ofProcess(init.arena.allocator(), init.minimal.args);
    args.dispatch(program, commands, init.io, init, given, &problem) catch |err| switch (err) {
        error.InvalidArguments => {
            if (problem.kind != .missingArguments) console.err("{f}\n", .{problem});
            console.log("{s}", .{std.mem.trimEnd(u8, problem.usage, "\n")});
            console.exit(2);
        },
        else => return err,
    };
}

fn printVersion(init: std.process.Init) !void {
    try console.print(init.io, "{s}\n", .{program.header});
}
