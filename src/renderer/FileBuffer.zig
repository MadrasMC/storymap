//! A buffer that lies in a file from `start` on, written out a piece at a time: what goes in is
//! filled in place in a small buffer the caller gives it, so memory holds only that piece.
const FileBuffer = @This();

const std = @import("std");
const Io = std.Io;

io: Io,
file: Io.File,
start: u64,
capacity: usize,
length: usize = 0,
buffer: []align(4) u8,
/// How much of `buffer` is waiting to be written.
held: usize = 0,

/// A buffer of at most `capacity` bytes in `file`, which must be open for writing.
pub fn init(io: Io, file: Io.File, start: u64, capacity: usize, buffer: []align(4) u8) FileBuffer {
    return .{ .io = io, .file = file, .start = start, .capacity = capacity, .buffer = buffer };
}

/// Writes out what's held.
pub fn flush(self: *FileBuffer) !void {
    try self.file.writePositionalAll(self.io, self.buffer[0..self.held], self.start + self.length - self.held);
    self.held = 0;
}

/// The next `length` bytes, zeros, for the caller to fill in place, at most `buffer` long and
/// usable until the next call. error.BufferFull past its capacity.
pub fn reserve(self: *FileBuffer, length: usize) ![]u8 {
    std.debug.assert(length <= self.buffer.len);
    if (length > self.capacity - self.length) return error.BufferFull;
    if (length > self.buffer.len - self.held) try self.flush();
    const room = self.buffer[self.held..][0..length];
    @memset(room, 0);
    self.held += length;
    self.length += length;
    return room;
}

test FileBuffer {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "buffer", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "before", 0);

    var bytes: [1 << 12]u8 align(4) = undefined;
    var buffer: FileBuffer = .init(io, file, 8, 4 * bytes.len, &bytes);
    // Filled past the buffer, so that it's written out on the way.
    const pieceLength = 1 << 8;
    for (0..2 * bytes.len / pieceLength + 2) |_| {
        const piece = try buffer.reserve(pieceLength);
        try std.testing.expectEqual(0, piece[pieceLength - 1]);
        @memset(piece, 7);
    }
    @memcpy(try buffer.reserve(3), "end");
    try buffer.flush();

    var read: [3]u8 = undefined;
    try std.testing.expectEqual(3, try file.readPositionalAll(io, &read, buffer.start + buffer.length - 3));
    try std.testing.expectEqualStrings("end", &read);
    try std.testing.expectEqual(3, try file.readPositionalAll(io, &read, buffer.start + bytes.len));
    try std.testing.expectEqual(7, read[0]);
    try std.testing.expectEqual(3, try file.readPositionalAll(io, &read, 0));
    try std.testing.expectEqualStrings("bef", &read);

    // Full, it keeps what it has.
    var small: FileBuffer = .init(io, file, buffer.start + buffer.length, 16, &bytes);
    _ = try small.reserve(16);
    try std.testing.expectError(error.BufferFull, small.reserve(1));
    try std.testing.expectEqual(16, small.length);
}
