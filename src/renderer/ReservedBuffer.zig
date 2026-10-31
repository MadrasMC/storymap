//! A buffer that never moves. It reserves address space for the most it can ever hold, which
//! costs no memory, and takes memory only as it fills, so what's in it is never copied and the
//! rest costs nothing.
const ReservedBuffer = @This();

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const posix = std.posix;

/// How much Windows, which counts memory against its limit when it's committed rather than when
/// it's touched, is asked for at a time.
const commitStep = 16 << 20;

memory: []align(std.heap.page_size_min) u8,
length: usize = 0,
/// The bytes of `memory` usable so far on Windows; elsewhere the system sees to it.
committed: usize = 0,

/// A buffer of at most `capacity` bytes, rounded up to whole pages.
pub fn init(capacity: usize) error{OutOfMemory}!ReservedBuffer {
    const length = std.mem.alignForward(usize, capacity, std.heap.pageSize());
    if (builtin.os.tag == .windows) {
        var base: ?*anyopaque = null;
        var size: windows.SIZE_T = length;
        const status = ntdll.NtAllocateVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&base), 0, &size, .{ .RESERVE = true }, .{ .NOACCESS = true });
        if (status != .SUCCESS) return error.OutOfMemory;
        const start: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(base));
        return .{ .memory = start[0..length] };
    }
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (@hasField(posix.MAP, "NORESERVE")) flags.NORESERVE = true;
    const memory = posix.mmap(null, length, .{ .READ = true, .WRITE = true }, flags, -1, 0) catch return error.OutOfMemory;
    return .{ .memory = memory, .committed = length };
}

pub fn deinit(self: *ReservedBuffer) void {
    if (builtin.os.tag == .windows) {
        var base: ?*anyopaque = self.memory.ptr;
        var size: windows.SIZE_T = 0;
        _ = ntdll.NtFreeVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&base), &size, .{ .RELEASE = true });
    } else {
        posix.munmap(self.memory);
    }
    self.* = undefined;
}

/// error.BufferFull past its capacity.
pub fn append(self: *ReservedBuffer, bytes: []const u8) error{ OutOfMemory, BufferFull }!void {
    if (bytes.len > self.memory.len - self.length) return error.BufferFull;
    const end = self.length + bytes.len;
    if (builtin.os.tag == .windows and end > self.committed) try self.commit(end);
    @memcpy(self.memory[self.length..end], bytes);
    self.length = end;
}

/// Makes the first `end` bytes usable, and some more, so few appends have to.
fn commit(self: *ReservedBuffer, end: usize) error{OutOfMemory}!void {
    const wanted = @min(std.mem.alignForward(usize, end, commitStep), self.memory.len);
    var base: ?*anyopaque = self.memory.ptr + self.committed;
    var size: windows.SIZE_T = wanted - self.committed;
    const status = ntdll.NtAllocateVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&base), 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true });
    if (status != .SUCCESS) return error.OutOfMemory;
    self.committed = wanted;
}

pub fn written(self: *const ReservedBuffer) []align(std.heap.page_size_min) const u8 {
    return self.memory[0..self.length];
}

test ReservedBuffer {
    // Reserving far more than the test ever touches, past a commit step, without it moving.
    var buffer: ReservedBuffer = try .init(1 << 32);
    defer buffer.deinit();
    const start = buffer.memory.ptr;
    const piece: [1 << 20]u8 = @splat(7);
    for (0..commitStep / piece.len + 2) |_| try buffer.append(&piece);
    try buffer.append("end");
    try std.testing.expectEqual(commitStep + 2 * piece.len + 3, buffer.written().len);
    try std.testing.expectEqual(start, buffer.written().ptr);
    try std.testing.expectEqual(7, buffer.written()[commitStep]);
    try std.testing.expectEqualStrings("end", buffer.written()[buffer.length - 3 ..]);

    // Full, it keeps what it has.
    var small: ReservedBuffer = try .init(1);
    defer small.deinit();
    const whole = try std.testing.allocator.alloc(u8, small.memory.len);
    defer std.testing.allocator.free(whole);
    @memset(whole, 1);
    try small.append(whole);
    try std.testing.expectError(error.BufferFull, small.append("x"));
    try std.testing.expectEqual(whole.len, small.written().len);
}
