//! A buffer that lies in a file from `start` on, mapped a window at a time: what's written goes
//! straight where it belongs, memory holds only the window, and the rest is the file's to keep.
const FileBuffer = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

/// How much of the file is mapped at a time, and what its start lies on a multiple of: Windows
/// maps a file from multiples of 64 KiB.
const windowLength = 64 << 20;
const windowAlignment = 1 << 16;

io: Io,
file: Io.File,
start: u64,
capacity: usize,
length: usize = 0,
window: ?Window = null,
/// How long the file is so far: a little past `length`, up to the end of the window.
fileLength: u64 = 0,

/// The part of the file mapped now.
const Window = struct {
    offset: u64,
    memory: []align(std.heap.page_size_min) u8,
    /// `Io.File.MemoryMap` ignores its offset on Windows, always mapping from the file's start, so
    /// there a window is mapped directly, and this is its section.
    map: if (builtin.os.tag == .windows) windows.HANDLE else Io.File.MemoryMap,
};

/// A buffer of at most `capacity` bytes in `file`, which must be open for reading and writing,
/// and empty after `start`.
pub fn init(io: Io, file: Io.File, start: u64, capacity: usize) FileBuffer {
    return .{ .io = io, .file = file, .start = start, .capacity = capacity };
}

/// Maps nothing more. The file can then be changed in other ways, such as cut to length.
pub fn close(self: *FileBuffer) !void {
    var window = self.window orelse return;
    self.window = null;
    if (builtin.os.tag == .windows) {
        _ = windows.ntdll.NtUnmapViewOfSection(windows.current_process, window.memory.ptr);
        windows.CloseHandle(window.map);
    } else {
        defer window.map.destroy(self.io);
        try window.map.write(self.io);
    }
}

/// The next `length` bytes, zeros, for the caller to fill in place, at most a window long and
/// usable until the next call. error.BufferFull past its capacity.
pub fn reserve(self: *FileBuffer, length: usize) ![]u8 {
    std.debug.assert(length + windowAlignment <= windowLength);
    if (length > self.capacity - self.length) return error.BufferFull;
    const at = self.start + self.length;
    const end = at + length;
    const fits = if (self.window) |window| end <= window.offset + window.memory.len else false;
    if (!fits) try self.moveWindow(at);
    const window = self.window.?;
    self.length += length;
    return window.memory[@intCast(at - window.offset)..][0..length];
}

fn moveWindow(self: *FileBuffer, at: u64) !void {
    try self.close();
    const offset = std.mem.alignBackward(u64, at, windowAlignment);
    try self.extend(offset + windowLength);
    if (builtin.os.tag == .windows) {
        self.window = try self.mapWindow(offset);
    } else {
        const map: Io.File.MemoryMap = try .create(self.io, self.file, .{ .len = windowLength, .offset = offset, .populate = false });
        self.window = .{ .offset = offset, .memory = map.memory, .map = map };
    }
}

/// Windows' mapping of a window: as `Io.File.MemoryMap` does it, but from `offset`.
fn mapWindow(self: *FileBuffer, offset: u64) !Window {
    const ntdll = windows.ntdll;
    const page = windows.PAGE.fromProtection(.{ .read = true, .write = true }).?;
    var section = windows.INVALID_HANDLE_VALUE;
    const sectionSize: windows.LARGE_INTEGER = @intCast(offset + windowLength);
    const access: windows.ACCESS_MASK = .{
        .SPECIFIC = .{ .SECTION = .{ .QUERY = true, .MAP_WRITE = true, .MAP_READ = true, .EXTEND_SIZE = true } },
        .STANDARD = .{ .RIGHTS = .REQUIRED },
    };
    switch (ntdll.NtCreateSection(&section, access, null, &sectionSize, page, .{ .COMMIT = true }, self.file.handle)) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    errdefer windows.CloseHandle(section);
    var memory: ?[*]align(std.heap.page_size_min) u8 = null;
    var length: windows.SIZE_T = windowLength;
    var viewOffset: windows.LARGE_INTEGER = @intCast(offset);
    switch (ntdll.NtMapViewOfSection(section, windows.current_process, @ptrCast(&memory), null, 0, &viewOffset, &length, .Unmap, .{}, page)) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    return .{ .offset = offset, .memory = memory.?[0..windowLength], .map = section };
}

/// Makes the file `end` bytes long, with room for them on the disk, so that running out shows
/// here as an error: writing to a mapped page the disk has no room for stops the program.
fn extend(self: *FileBuffer, end: u64) !void {
    if (end <= self.fileLength) return;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const result = linux.fallocate(self.file.handle, 0, @intCast(self.fileLength), @intCast(end - self.fileLength));
        switch (linux.errno(result)) {
            .SUCCESS => {
                self.fileLength = end;
                return;
            },
            .NOSPC => return error.NoSpaceLeft,
            // A file system without it.
            else => {},
        }
    }
    if (builtin.os.tag.isDarwin()) try self.preallocate(end - self.fileLength);
    try self.file.setLength(self.io, end);
    self.fileLength = end;
}

/// macOS' way of finding room for `length` more bytes at the file's end, in one piece if it can,
/// which `fallocate` is on Linux; the file's length is still to be set.
fn preallocate(self: *FileBuffer, length: u64) !void {
    const allocateContiguous = 2;
    const allocateAll = 4;
    const physicalEnd = 3;
    var store: extern struct {
        flags: u32,
        mode: c_int = physicalEnd,
        offset: i64 = 0,
        length: i64,
        allocated: i64 = 0,
    } = .{ .flags = allocateContiguous | allocateAll, .length = @intCast(length) };
    if (std.c.fcntl(self.file.handle, std.c.F.PREALLOCATE, &store) == 0) return;
    store.flags = allocateAll;
    if (std.c.fcntl(self.file.handle, std.c.F.PREALLOCATE, &store) == 0) return;
    switch (std.posix.errno(@as(c_int, -1))) {
        .NOSPC => return error.NoSpaceLeft,
        // A file system without it.
        else => {},
    }
}

test FileBuffer {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "buffer", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "before", 0);

    var buffer: FileBuffer = .init(io, file, 8, 2 * windowLength + 8);
    defer buffer.close() catch {};
    // Filled past a window, so that one piece lies where the next window starts.
    const pieceLength = 1 << 20;
    for (0..windowLength / pieceLength + 2) |_| {
        const piece = try buffer.reserve(pieceLength);
        try std.testing.expectEqual(pieceLength, piece.len);
        try std.testing.expectEqual(0, piece[pieceLength - 1]);
        @memset(piece, 7);
    }
    @memcpy(try buffer.reserve(3), "end");
    try buffer.close();

    var read: [3]u8 = undefined;
    try std.testing.expectEqual(3, try file.readPositionalAll(io, &read, buffer.start + buffer.length - 3));
    try std.testing.expectEqualStrings("end", &read);
    try std.testing.expectEqual(3, try file.readPositionalAll(io, &read, buffer.start + windowLength));
    try std.testing.expectEqual(7, read[0]);
    try std.testing.expectEqual(3, try file.readPositionalAll(io, &read, 0));
    try std.testing.expectEqualStrings("bef", &read);

    // Full, it keeps what it has.
    var small: FileBuffer = .init(io, file, buffer.start + buffer.length, 16);
    defer small.close() catch {};
    small.fileLength = buffer.fileLength;
    _ = try small.reserve(16);
    try std.testing.expectError(error.BufferFull, small.reserve(1));
    try std.testing.expectEqual(16, small.length);
}
