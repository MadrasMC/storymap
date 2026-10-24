//! Storymap's messages, and the Windows console they're written to.
//!
//! Messages go through `std.log` and come out of `logFn`, which the program installs, so the
//! test runner can hold them back from a test's output (`std.testing.log_level`).
//!
//! While Storymap runs, the Windows console is switched to UTF-8, and back as it exits. Its
//! default code page is an old DOS one, which garbles UTF-8 such as "km²" or a world name.
//! Elsewhere this does nothing.
const std = @import("std");
const builtin = @import("builtin");

const utf8 = 65001;

/// The code page to put back, if it was changed.
var previous: ?c_uint = null;

extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) c_uint;
extern "kernel32" fn SetConsoleOutputCP(codePage: c_uint) callconv(.winapi) c_int;

pub fn useUtf8() void {
    if (builtin.os.tag == .windows) {
        // 0 when the program has no console.
        const current = GetConsoleOutputCP();
        if (current == 0 or current == utf8) return;
        if (SetConsoleOutputCP(utf8) != 0) previous = current;
    }
}

pub fn restore() void {
    if (builtin.os.tag == .windows) {
        if (previous) |codePage| _ = SetConsoleOutputCP(codePage);
        previous = null;
    }
}

/// Use this rather than `std.process.exit`, so the console is restored.
pub fn exit(status: u8) noreturn {
    restore();
    std.process.exit(status);
}

/// Writes to stdout as is, for a command's results.
pub fn print(io: std.Io, comptime format: []const u8, values: anytype) std.Io.Writer.Error!void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print(format, values);
    try stdout.interface.flush();
}

/// What the program did, such as the tiles it drew.
pub fn log(comptime format: []const u8, values: anytype) void {
    std.log.info(format, values);
}

/// Something skipped or missing from the map, as the program carries on.
pub fn warn(comptime format: []const u8, values: anytype) void {
    std.log.warn(format, values);
}

/// The test runner fails a test that logs an error.
pub fn err(comptime format: []const u8, values: anytype) void {
    std.log.err(format, values);
}

pub fn fail(comptime format: []const u8, values: anytype) noreturn {
    err(format, values);
    exit(1);
}

/// The program's `std_options.logFn`: one line on stderr for each message, with warnings and
/// errors marked as Storymap's.
pub fn logFn(comptime level: std.log.Level, comptime _: @EnumLiteral(), comptime format: []const u8, values: anytype) void {
    const prefix = switch (level) {
        .err, .warn => "storymap: ",
        .info, .debug => "",
    };
    std.debug.print(prefix ++ format ++ "\n", values);
}
