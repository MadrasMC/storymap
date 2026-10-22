//! Switches the Windows console to UTF-8 while Storymap runs, and back as it exits. Its default
//! code page is an old DOS one, which garbles UTF-8 such as "km²" or a world name. Elsewhere
//! this does nothing.
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

pub fn fail(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print("storymap: " ++ format, values);
    exit(1);
}
