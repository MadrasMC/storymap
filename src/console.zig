//! The console's output code page on Windows. Windows consoles read what programs print in
//! their output code page, by default an old DOS one, so UTF-8 such as "km²", a path or a world
//! name comes out garbled. Storymap switches the console to UTF-8 while it runs and puts the
//! old code page back as it exits. Elsewhere this does nothing.
const std = @import("std");
const builtin = @import("builtin");

const utf8 = 65001;

/// The code page to put back, if it was changed.
var previous: ?c_uint = null;

extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) c_uint;
extern "kernel32" fn SetConsoleOutputCP(codePage: c_uint) callconv(.winapi) c_int;

/// Switches the console to UTF-8, if there is one and it isn't already.
pub fn useUtf8() void {
    if (builtin.os.tag == .windows) {
        // 0 when the program has no console.
        const current = GetConsoleOutputCP();
        if (current == 0 or current == utf8) return;
        if (SetConsoleOutputCP(utf8) != 0) previous = current;
    }
}

/// Puts back the code page `useUtf8` replaced.
pub fn restore() void {
    if (builtin.os.tag == .windows) {
        if (previous) |codePage| _ = SetConsoleOutputCP(codePage);
        previous = null;
    }
}

/// Exits with `status`, restoring the console first. Use this rather than `std.process.exit`.
pub fn exit(status: u8) noreturn {
    restore();
    std.process.exit(status);
}
