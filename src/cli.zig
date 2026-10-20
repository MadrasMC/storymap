//! Reading Storymap's command lines with zig-clap: a command's arguments parsed against its
//! parameters, with problems reported in Storymap's own words, and its help.
//!
//! clap puts positionals beyond a command's last into that last one, overwriting it, so a
//! command declares its last positional as taking many (`<folder>...`) and `parse` refuses
//! more than one; help shows it as taking one.
const std = @import("std");
const clap = @import("clap");
const console = @import("console.zig");

pub const Params = []const clap.Param(clap.Help);

/// The arguments `args` for a command with `params`, values read by `parsers`, allocated with
/// `arena`. Arguments that don't fit stop the program, with what's wrong and `usage`.
pub fn parse(
    comptime params: Params,
    comptime parsers: anytype,
    arena: std.mem.Allocator,
    args: []const []const u8,
    usage: []const u8,
) clap.ResultEx(clap.Help, params, parsers) {
    var iter: clap.args.SliceIterator = .{ .args = args };
    var diag: clap.Diagnostic = .{};
    const parsed = clap.parseEx(clap.Help, params, parsers, &iter, .{ .diagnostic = &diag, .allocator = arena }) catch |err| {
        report(diag, err);
        std.debug.print("\n{s}", .{usage});
        console.exit(2);
    };
    // A positional taking many is a command's last, there to catch any beyond it.
    inline for (parsed.positionals) |values| {
        if (@typeInfo(@TypeOf(values)) == .pointer and values.len > 1) {
            std.debug.print("storymap: there's nothing to do with {s}\n\n{s}", .{ values[1], usage });
            console.exit(2);
        }
    }
    return parsed;
}

/// The first of a positional's values, or null without one.
pub fn first(values: []const []const u8) ?[]const u8 {
    return if (values.len > 0) values[0] else null;
}

fn report(diag: clap.Diagnostic, err: anyerror) void {
    const name = diag.name.longest();
    const prefix = name.kind.prefix();
    switch (err) {
        error.DoesntTakeValue => std.debug.print("storymap: {s}{s} doesn't take a value\n", .{ prefix, name.name }),
        error.MissingValue => std.debug.print("storymap: {s}{s} needs a value\n", .{ prefix, name.name }),
        error.InvalidArgument => if (name.kind == .positional)
            std.debug.print("storymap: there's nothing to do with {s}\n", .{diag.arg})
        else
            std.debug.print("storymap: there's no option {s}{s}\n", .{ prefix, name.name }),
        else => std.debug.print("storymap: can't read the arguments ({s})\n", .{@errorName(err)}),
    }
}

/// Prints `usage`, then each of `params` with its description, on stdout. Positionals are
/// shown taking one value, as they do.
pub fn printHelp(io: std.Io, comptime params: Params, usage: []const u8) !void {
    const shown = comptime shown: {
        var list = params[0..params.len].*;
        for (&list) |*param| {
            if (param.names.longest().kind == .positional) param.takes_value = .one;
        }
        break :shown list;
    };
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print("{s}\noptions:\n", .{usage});
    try clap.help(&stdout.interface, clap.Help, &shown, .{
        .indent = 0,
        .description_on_new_line = false,
        .description_indent = 2,
        .spacing_between_parameters = 0,
        .max_width = 100,
    });
    try stdout.interface.flush();
}
