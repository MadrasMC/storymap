# args

Command-line parsing and subcommand routing for Zig 0.17, with usage and help generated from what each command declares. Everything is declared at compile time, and asking for an option or positional a command doesn't take doesn't compile.

It reads arguments and writes help, nothing more: printing a problem and exiting are left to the program.

## Example

```zig
const std = @import("std");
const args = @import("args");

const copySpec: args.Spec = .{
    .options = &.{
        .{ .name = "verbose", .short = 'v', .description = "List each file copied." },
        .{ .name = "mode", .value = "mode", .description = "fast or careful." },
    },
    .positionals = &.{
        .{ .name = "source", .description = "What to copy." },
        .{ .name = "target", .optional = true, .description = "Where to copy it." },
    },
    .description = "Copies a file.",
};

const program: args.Program = .{ .name = "copy", .header = "copy 1.0" };

const commands = .{
    args.Command(null, copySpec, copy),
    args.Action(.{ .name = "version", .description = "Show the version." }, printVersion),
};

fn copy(_: std.process.Init, parsed: args.Parsed(copySpec)) !void {
    const source = parsed.positional("source").?;
    const target = parsed.positional("target") orelse ".";
    const mode = parsed.value("mode") orelse "fast";
    if (parsed.flag("verbose")) std.debug.print("{s} -> {s} ({s})\n", .{ source, target, mode });
}

fn printVersion(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try stdout.interface.print("{s}\n", .{program.header});
}

pub fn main(init: std.process.Init) !void {
    var problem: args.Problem = .{};
    const given = try args.ofProcess(init.arena.allocator(), init.minimal.args);
    args.dispatch(program, commands, init.io, init, given, &problem) catch |err| switch (err) {
        error.InvalidArguments => {
            std.debug.print("copy: {f}\n\n{s}", .{ problem, problem.usage });
            std.process.exit(2);
        },
        else => return err,
    };
}
```

`copy --help` prints:

```
copy 1.0

usage: copy <source> [target] [options]
       copy --version

Copies a file.

options:
-h, --help         Show this help.
    --version      Show the version.
-v, --verbose      List each file copied.
    --mode <mode>  fast or careful.
<source>           What to copy.
[target]           Where to copy it.
```

## Syntax

| form | meaning |
| --- | --- |
| `--name` | an option that takes no value |
| `--name value`, `--name=value` | an option and its value |
| `-n` | an option by its one-letter name |
| `--` | ends the options: what follows is positional, even if it starts with a dash |

Options can be given anywhere among the positionals. Positionals are given in order, so only the last ones can be optional; a required one after an optional one doesn't compile.

## Routing

`dispatch` picks what to run from the first argument:

1. a `Command` whose name it is, given the rest of the arguments;
2. otherwise, an `Action` whose option is among the arguments (before any `--`), if it's the only argument;
3. otherwise, the default command (the `Command` named `null`), given all the arguments.

Every command takes `-h, --help`, which prints its help on stdout instead of running it. The default command's usage and help are the program's: they list every command and action.

## API

| name | contents |
| --- | --- |
| `Program` | `name`, for the usage lines; `header`, a line printed above every help |
| `Spec` | what a command takes: `options`, `positionals` and a `description` for its help, paragraphs separated by a blank line |
| `Option` | `name`, `short` (a letter), `value` (the value's name in help, or null for none), `description` |
| `Positional` | `name`, `optional`, `description` |
| `Command(name, spec, run)` | a command; `run(context, parsed)` gets the program's context and a `Parsed(spec)` |
| `Action(option, run)` | an option given on its own, such as `--version`; `run(context)` |
| `Parsed(spec)` | a command's arguments: `flag(name)`, `value(name)`, `positional(name)` |
| `dispatch(program, commands, io, context, args, problem)` | runs the command or action given |
| `parse(spec, args, problem)` | reads one command's arguments, without routing |
| `ofProcess(arena, process)` | the process's arguments, without the program's name |
| `Problem` | what's wrong, as `kind` and `argument`; the command's usage lines, as `usage`; a message, with `{f}` |

## Problems

| kind | message |
| --- | --- |
| `missingArguments` | `no arguments given` |
| `unknownCommand` | ``unknown command `x` `` |
| `unknownOption` | ``unknown option `--x` `` |
| `unexpectedValue` | `` `--x` doesn't take a value`` |
| `missingValue` | `` `--x` needs a value`` |
| `extraArgument` | ``unexpected argument `x` `` |
| `missingPositional` | `` `<x>` is missing`` |

`missingArguments` is for a command line with no arguments at all where some are needed, so a program can print only the usage there.
