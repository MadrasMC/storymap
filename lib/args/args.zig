//! Command-line arguments. A program has commands (`Command`), picked by its first argument and
//! run by `dispatch`, and actions (`Action`), options given on their own such as `--version`.
//! Options are `--name`, `--name value`, `--name=value` or `-n`, in any order among the
//! positionals; `--` ends them. Every command takes `-h, --help`.
//!
//! It only reads arguments and writes help: what to do about a problem is up to the program.
const std = @import("std");

const helpOption: Option = .{ .name = "help", .short = 'h', .description = "Show this help." };

fn optionsOf(comptime spec: Spec) []const Option {
    for (spec.options) |option| {
        if (std.mem.eql(u8, option.name, "help")) @compileError("every command takes --help already");
    }
    const all = [_]Option{helpOption} ++ spec.options[0..spec.options.len].*;
    return &all;
}

/// A command for `dispatch`, named by the program's first argument, or the default command if
/// `commandName` is null. It runs as `commandRun(context, parsed)`, with `Parsed(commandSpec)`.
pub fn Command(comptime commandName: ?[]const u8, comptime commandSpec: Spec, comptime commandRun: anytype) type {
    return struct {
        pub const name = commandName;
        pub const spec = commandSpec;
        pub const run = commandRun;
    };
}

/// An action for `dispatch`: an option that takes no value, given as the only argument. It runs
/// as `actionRun(context)`. The default command's help lists it among its options.
pub fn Action(comptime actionOption: Option, comptime actionRun: anytype) type {
    if (actionOption.value != null) @compileError("an action's option --" ++ actionOption.name ++ " can't take a value");
    if (std.mem.eql(u8, actionOption.name, "help")) @compileError("every command takes --help already");
    return struct {
        pub const option = actionOption;
        pub const run = actionRun;
    };
}

fn isAction(comptime entry: type) bool {
    return @hasDecl(entry, "option");
}

fn actionOptions(comptime commands: anytype) []const Option {
    comptime {
        var options: []const Option = &.{};
        for (commands) |entry| {
            if (isAction(entry)) options = options ++ &[_]Option{entry.option};
        }
        return options;
    }
}

fn isOption(comptime option: Option, arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--" ++ option.name)) return true;
    const short = option.short orelse return false;
    return arg.len == 2 and arg[0] == '-' and arg[1] == short;
}

pub const Program = struct {
    /// What it's run as, for the usage lines.
    name: []const u8,
    /// A line above every command's help, such as its name and version; none if empty.
    header: []const u8 = "",
};

/// Runs the command the first of `args` names, with the rest; else an action given on its own;
/// else the default command with all of `args`. `commands` is a tuple of `Command`s and
/// `Action`s; `args` leaves out the program's name. With `--help`, prints the command's help on
/// stdout instead. On error.InvalidArguments, `problem` says what's wrong.
pub fn dispatch(comptime program: Program, comptime commands: anytype, io: std.Io, context: anytype, args: []const []const u8, problem: *Problem) !void {
    comptime {
        var defaults = 0;
        for (commands) |entry| {
            if (!isAction(entry) and entry.name == null) defaults += 1;
        }
        if (defaults > 1) @compileError("a program has one default command at most");
        for (commands) |entry| {
            if (isAction(entry) or entry.name != null) continue;
            for (entry.spec.options) |option| {
                for (actionOptions(commands)) |action| {
                    if (std.mem.eql(u8, option.name, action.name)) @compileError("--" ++ option.name ++ " is an action, so the default command can't take it too");
                }
            }
        }
    }
    if (args.len > 0) inline for (commands) |entry| {
        if (comptime isAction(entry)) continue;
        if (entry.name) |name| {
            if (std.mem.eql(u8, args[0], name)) return runCommand(program, commands, entry, io, context, args[1..], problem);
        }
    };
    inline for (commands) |entry| {
        if (comptime !isAction(entry)) continue;
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--")) break;
            if (!isOption(entry.option, arg)) continue;
            if (args.len > 1) {
                problem.* = .{ .kind = .extraArgument, .argument = args[if (i == 0) 1 else 0], .usage = comptime usage(program, commands) };
                return error.InvalidArguments;
            }
            return entry.run(context);
        }
    }
    inline for (commands) |entry| {
        if (comptime isAction(entry)) continue;
        if (entry.name == null) return runCommand(program, commands, entry, io, context, args, problem);
    }
    problem.* = .{
        .kind = if (args.len > 0) .unknownCommand else .missingArguments,
        .argument = if (args.len > 0) args[0] else "",
        .usage = comptime usage(program, commands),
    };
    return error.InvalidArguments;
}

fn runCommand(comptime program: Program, comptime commands: anytype, comptime command: type, io: std.Io, context: anytype, args: []const []const u8, problem: *Problem) !void {
    const lines = comptime usageOf(program, commands, command);
    problem.usage = lines;
    const parsed = try parse(command.spec, args, problem);
    if (parsed.flag("help")) {
        // The default command's help is the program's, so it lists the actions too.
        const spec = comptime if (command.name == null) Spec{
            .options = actionOptions(commands) ++ command.spec.options,
            .positionals = command.spec.positionals,
            .description = command.spec.description,
        } else command.spec;
        return printHelp(io, program.header, lines, spec);
    }
    return command.run(context, parsed);
}

/// The default command's usage is the whole program's, as it's run by the program's name alone.
fn usageOf(comptime program: Program, comptime commands: anytype, comptime command: type) []const u8 {
    return if (command.name == null) usage(program, commands) else usage(program, .{command});
}

/// The usage lines of `commands`: one for each command, `program [name] <required> [optional]
/// [options]`, then one for each action, such as `program --version`.
fn usage(comptime program: Program, comptime commands: anytype) []const u8 {
    comptime {
        var lines: []const []const u8 = &.{};
        for (commands) |entry| {
            if (isAction(entry)) continue;
            var line: []const u8 = program.name ++ if (entry.name) |name| " " ++ name else "";
            for (entry.spec.positionals) |p| line = line ++ " " ++ positionalName(p);
            lines = lines ++ &[_][]const u8{line ++ if (entry.spec.options.len > 0) " [options]" else ""};
        }
        for (actionOptions(commands)) |option| lines = lines ++ &[_][]const u8{program.name ++ " --" ++ option.name};
        var text: []const u8 = "";
        for (lines, 0..) |line, i| text = text ++ (if (i == 0) "usage: " else "       ") ++ line ++ "\n";
        return text;
    }
}

fn positionalName(comptime p: Positional) []const u8 {
    return if (p.optional) "[" ++ p.name ++ "]" else "<" ++ p.name ++ ">";
}

/// The program's arguments, without its name.
pub fn ofProcess(arena: std.mem.Allocator, process: std.process.Args) ![]const []const u8 {
    const all = try process.toSlice(arena);
    if (all.len == 0) return &.{};
    const args = try arena.alloc([]const u8, all.len - 1);
    for (args, all[1..]) |*arg, given| arg.* = given;
    return args;
}

pub const Option = struct {
    /// Its name without the dashes: "verbose" for `--verbose`.
    name: []const u8,
    short: ?u8 = null,
    /// What its value is, shown in help as `<value>`; null for an option that takes none.
    value: ?[]const u8 = null,
    description: []const u8,
};

pub const Positional = struct {
    name: []const u8,
    /// Whether it can be left out. Positionals are given in order, so once one is optional,
    /// the rest must be too.
    optional: bool = false,
    description: []const u8,
};

/// What a command takes.
pub const Spec = struct {
    options: []const Option = &.{},
    positionals: []const Positional = &.{},
    /// What the command does, for its help: paragraphs separated by a blank line.
    description: []const u8 = "",
};

/// A command's arguments as given, read by name. Asking for a name the command doesn't take
/// doesn't compile.
pub fn Parsed(comptime spec: Spec) type {
    comptime {
        var optional = false;
        for (spec.positionals) |p| {
            if (optional and !p.optional) @compileError("<" ++ p.name ++ "> comes after an optional positional, so it must be optional too");
            optional = p.optional;
        }
    }
    const options = comptime optionsOf(spec);
    return struct {
        const Self = @This();

        /// Each option's value as given, "" for one that takes none; null if it wasn't given.
        options: [options.len]?[]const u8 = @splat(null),
        positionals: [spec.positionals.len]?[]const u8 = @splat(null),

        /// Whether an option that takes no value was given.
        pub fn flag(self: Self, comptime name: []const u8) bool {
            const i = comptime optionIndex(name);
            if (options[i].value != null) @compileError("--" ++ name ++ " takes a value");
            return self.options[i] != null;
        }

        pub fn value(self: Self, comptime name: []const u8) ?[]const u8 {
            const i = comptime optionIndex(name);
            if (options[i].value == null) @compileError("--" ++ name ++ " takes no value");
            return self.options[i];
        }

        pub fn positional(self: Self, comptime name: []const u8) ?[]const u8 {
            inline for (spec.positionals, 0..) |p, i| {
                if (comptime std.mem.eql(u8, p.name, name)) return self.positionals[i];
            }
            @compileError("no positional " ++ name);
        }

        fn optionIndex(comptime name: []const u8) usize {
            for (options, 0..) |option, i| {
                if (std.mem.eql(u8, option.name, name)) return i;
            }
            @compileError("no option --" ++ name);
        }
    };
}

pub const Problem = struct {
    kind: Kind = .unknownOption,
    /// The argument or name it's about.
    argument: []const u8 = "",
    /// The usage lines of the command it's about, or the whole program's if no command was found.
    usage: []const u8 = "",

    pub const Kind = enum {
        /// No arguments at all, where some are needed.
        missingArguments,
        unknownCommand,
        unknownOption,
        unexpectedValue,
        missingValue,
        extraArgument,
        missingPositional,
    };

    /// The problem as a message, e.g. "unknown option --verbos", for `{f}`.
    pub fn format(self: Problem, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .missingArguments => try writer.writeAll("no arguments given"),
            .unknownCommand => try writer.print("unknown command {s}", .{self.argument}),
            .unknownOption => try writer.print("unknown option {s}", .{self.argument}),
            .unexpectedValue => try writer.print("--{s} doesn't take a value", .{self.argument}),
            .missingValue => try writer.print("--{s} needs a value", .{self.argument}),
            .extraArgument => try writer.print("unexpected argument {s}", .{self.argument}),
            .missingPositional => try writer.print("<{s}> is missing", .{self.argument}),
        }
    }
};

/// `args` leaves out the program's name.
pub fn parse(comptime spec: Spec, args: []const []const u8, problem: *Problem) error{InvalidArguments}!Parsed(spec) {
    const options = comptime optionsOf(spec);
    var parsed: Parsed(spec) = .{};
    var count: usize = 0;
    var optionsEnded = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!optionsEnded and std.mem.eql(u8, arg, "--")) {
            optionsEnded = true;
            continue;
        }
        if (optionsEnded or arg.len < 2 or arg[0] != '-') {
            if (count == spec.positionals.len) return fail(problem, .extraArgument, arg);
            parsed.positionals[count] = arg;
            count += 1;
            continue;
        }

        var given: ?[]const u8 = null;
        const index = if (std.mem.startsWith(u8, arg, "--")) index: {
            var name = arg[2..];
            if (std.mem.indexOfScalar(u8, name, '=')) |equals| {
                given = name[equals + 1 ..];
                name = name[0..equals];
            }
            for (options, 0..) |option, j| {
                if (std.mem.eql(u8, option.name, name)) break :index j;
            }
            return fail(problem, .unknownOption, arg);
        } else index: {
            if (arg.len == 2) for (options, 0..) |option, j| {
                if (option.short == arg[1]) break :index j;
            };
            return fail(problem, .unknownOption, arg);
        };

        const option = options[index];
        if (option.value == null) {
            if (given != null) return fail(problem, .unexpectedValue, option.name);
            parsed.options[index] = "";
        } else {
            parsed.options[index] = given orelse value: {
                if (i + 1 == args.len) return fail(problem, .missingValue, option.name);
                i += 1;
                break :value args[i];
            };
        }
    }
    // With --help, the command won't run, so it needs nothing else.
    if (parsed.flag("help")) return parsed;
    for (spec.positionals, parsed.positionals) |p, given| {
        if (!p.optional and given == null) return fail(problem, if (args.len == 0) .missingArguments else .missingPositional, p.name);
    }
    return parsed;
}

fn fail(problem: *Problem, kind: Problem.Kind, argument: []const u8) error{InvalidArguments} {
    problem.kind = kind;
    problem.argument = argument;
    return error.InvalidArguments;
}

fn writeHelp(writer: *std.Io.Writer, comptime header: []const u8, comptime lines: []const u8, comptime spec: Spec) !void {
    const options = comptime optionsOf(spec);
    const names = comptime names: {
        var list: [options.len + spec.positionals.len][]const u8 = undefined;
        for (options, 0..) |option, i| {
            const short = if (option.short) |s| "-" ++ [_]u8{s} ++ ", " else "    ";
            list[i] = short ++ "--" ++ option.name ++ if (option.value) |v| " <" ++ v ++ ">" else "";
        }
        for (spec.positionals, options.len..) |p, i| list[i] = positionalName(p);
        break :names list;
    };
    const descriptions = comptime descriptions: {
        var list: [names.len][]const u8 = undefined;
        for (options, 0..) |option, i| list[i] = option.description;
        for (spec.positionals, options.len..) |p, i| list[i] = p.description;
        break :descriptions list;
    };
    var column: usize = 0;
    for (names) |name| column = @max(column, name.len + 2);

    if (header.len > 0) try writer.print("{s}\n\n", .{header});
    try writer.print("{s}\n", .{lines});
    if (spec.description.len > 0) {
        var paragraphs = std.mem.splitSequence(u8, spec.description, "\n\n");
        while (paragraphs.next()) |paragraph| {
            try writeWrapped(writer, paragraph, 0, helpWidth);
            try writer.writeByte('\n');
        }
    }
    try writer.writeAll("options:\n");
    for (names, descriptions) |name, description| {
        try writer.writeAll(name);
        try writer.splatByteAll(' ', column - name.len);
        try writeWrapped(writer, description, column, helpWidth);
    }
}

const helpWidth = 100;

/// Line breaks in `text` count as spaces.
fn writeWrapped(writer: *std.Io.Writer, text: []const u8, indent: usize, width: usize) !void {
    var at = indent;
    var words = std.mem.tokenizeAny(u8, text, " \n");
    var first = true;
    while (words.next()) |word| {
        if (!first and at + 1 + word.len > width) {
            try writer.writeByte('\n');
            try writer.splatByteAll(' ', indent);
            at = indent;
        } else if (!first) {
            try writer.writeByte(' ');
            at += 1;
        }
        try writer.writeAll(word);
        at += word.len;
        first = false;
    }
    try writer.writeByte('\n');
}

fn printHelp(io: std.Io, comptime header: []const u8, comptime lines: []const u8, comptime spec: Spec) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writeHelp(&stdout.interface, header, lines, spec);
    try stdout.interface.flush();
}

const testProgram: Program = .{ .name = "copy", .header = "copy 1.0" };

const versionOption: Option = .{ .name = "version", .description = "Show the version." };

const testSpec: Spec = .{
    .options = &.{
        .{ .name = "mode", .value = "mode", .description = "How to copy: fast (the default), or careful, which checks every file against its source afterwards." },
        .{ .name = "verbose", .description = "List each file copied." },
    },
    .positionals = &.{
        .{ .name = "source", .description = "What to copy." },
        .{ .name = "target", .optional = true, .description = "Where to copy it." },
    },
    .description = "Copies a file.",
};

test parse {
    var problem: Problem = .{};
    const all = try parse(testSpec, &.{ "--mode", "careful", "notes.txt", "--verbose", "backup" }, &problem);
    try std.testing.expectEqualStrings("careful", all.value("mode").?);
    try std.testing.expect(all.flag("verbose"));
    try std.testing.expect(!all.flag("help"));
    try std.testing.expectEqualStrings("notes.txt", all.positional("source").?);
    try std.testing.expectEqualStrings("backup", all.positional("target").?);

    const some = try parse(testSpec, &.{ "-h", "--mode=fast", "--", "-odd.txt" }, &problem);
    try std.testing.expect(some.flag("help"));
    try std.testing.expectEqualStrings("fast", some.value("mode").?);
    try std.testing.expectEqualStrings("-odd.txt", some.positional("source").?);
    try std.testing.expectEqual(null, some.positional("target"));

    // --help on its own, without the source.
    try std.testing.expect((try parse(testSpec, &.{"--help"}, &problem)).flag("help"));

    const cases = [_]struct { args: []const []const u8, kind: Problem.Kind, argument: []const u8 }{
        .{ .args = &.{ "a", "--verbos" }, .kind = .unknownOption, .argument = "--verbos" },
        .{ .args = &.{ "a", "-x" }, .kind = .unknownOption, .argument = "-x" },
        .{ .args = &.{ "a", "--verbose=yes" }, .kind = .unexpectedValue, .argument = "verbose" },
        .{ .args = &.{ "a", "--mode" }, .kind = .missingValue, .argument = "mode" },
        .{ .args = &.{ "a", "b", "c" }, .kind = .extraArgument, .argument = "c" },
        .{ .args = &.{"--verbose"}, .kind = .missingPositional, .argument = "source" },
        .{ .args = &.{}, .kind = .missingArguments, .argument = "source" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidArguments, parse(testSpec, case.args, &problem));
        try std.testing.expectEqual(case.kind, problem.kind);
        try std.testing.expectEqualStrings(case.argument, problem.argument);
    }
}

test writeHelp {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeHelp(&writer, testProgram.header, "usage: copy <source> [target] [options]\n", testSpec);
    try std.testing.expectEqualStrings(
        \\copy 1.0
        \\
        \\usage: copy <source> [target] [options]
        \\
        \\Copies a file.
        \\
        \\options:
        \\-h, --help         Show this help.
        \\    --mode <mode>  How to copy: fast (the default), or careful, which checks every file against its
        \\                   source afterwards.
        \\    --verbose      List each file copied.
        \\<source>           What to copy.
        \\[target]           Where to copy it.
        \\
    , writer.buffered());
}

test dispatch {
    const Ran = struct {
        command: []const u8 = "",
        source: []const u8 = "",

        fn copy(ran: *@This(), parsed: Parsed(testSpec)) !void {
            ran.* = .{ .command = "copy", .source = parsed.positional("source").? };
        }

        fn list(ran: *@This(), parsed: Parsed(testSpec)) !void {
            ran.* = .{ .command = "list", .source = parsed.positional("source").? };
        }

        fn version(ran: *@This()) !void {
            ran.* = .{ .command = "version" };
        }
    };
    const commands = .{
        Command(null, testSpec, Ran.copy),
        Command("list", testSpec, Ran.list),
        Action(versionOption, Ran.version),
    };
    const io = std.testing.io;
    var ran: Ran = .{};
    var problem: Problem = .{};

    try dispatch(testProgram, commands, io, &ran, &.{"notes.txt"}, &problem);
    try std.testing.expectEqualStrings("copy", ran.command);
    try std.testing.expectEqualStrings("notes.txt", ran.source);

    try dispatch(testProgram, commands, io, &ran, &.{ "list", "notes" }, &problem);
    try std.testing.expectEqualStrings("list", ran.command);
    try std.testing.expectEqualStrings("notes", ran.source);

    try dispatch(testProgram, commands, io, &ran, &.{"--version"}, &problem);
    try std.testing.expectEqualStrings("version", ran.command);

    // An action takes nothing else, and isn't a command's option.
    const cases = [_]struct { args: []const []const u8, kind: Problem.Kind, argument: []const u8 }{
        .{ .args = &.{ "--version", "notes" }, .kind = .extraArgument, .argument = "notes" },
        .{ .args = &.{ "notes", "--version" }, .kind = .extraArgument, .argument = "notes" },
        .{ .args = &.{ "list", "notes", "--version" }, .kind = .unknownOption, .argument = "--version" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidArguments, dispatch(testProgram, commands, io, &ran, case.args, &problem));
        try std.testing.expectEqual(case.kind, problem.kind);
        try std.testing.expectEqualStrings(case.argument, problem.argument);
    }

    // A problem keeps the usage of the command it's about; the default command's is the program's.
    try std.testing.expectError(error.InvalidArguments, dispatch(testProgram, commands, io, &ran, &.{ "list", "--verbos" }, &problem));
    try std.testing.expectEqual(.unknownOption, problem.kind);
    try std.testing.expectEqualStrings("usage: copy list <source> [target] [options]\n", problem.usage);
    try std.testing.expectError(error.InvalidArguments, dispatch(testProgram, commands, io, &ran, &.{"--verbos"}, &problem));
    try std.testing.expectEqualStrings(comptime usage(testProgram, commands), problem.usage);

    const named = .{Command("list", testSpec, Ran.list)};
    try std.testing.expectError(error.InvalidArguments, dispatch(testProgram, named, io, &ran, &.{"lsit"}, &problem));
    try std.testing.expectEqual(.unknownCommand, problem.kind);
    try std.testing.expectEqualStrings("lsit", problem.argument);
}

test usage {
    const commands = .{
        Command(null, .{ .positionals = testSpec.positionals }, {}),
        Command("list", testSpec, {}),
        Action(versionOption, {}),
    };
    try std.testing.expectEqualStrings(
        \\usage: copy <source> [target]
        \\       copy list <source> [target] [options]
        \\       copy --version
        \\
    , comptime usage(testProgram, commands));
}

test "Problem.format" {
    var problem: Problem = .{};
    try std.testing.expectError(error.InvalidArguments, parse(testSpec, &.{ "a", "--verbos" }, &problem));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("unknown option --verbos", try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
}
