const std = @import("std");

const Entity = @This();

buf: []const u8,
cur: usize = 0,

const Pair = struct {
    key: []const u8,
    value: ?[]const u8,

    pub fn debugPrint(self: Pair) void {
        std.debug.print("\nkey: {s}", .{self.key});
        if (self.value) |v| std.debug.print(", value: {s}", .{v});
    }
};

pub fn next(self: *Entity) ?Pair {
    if (self.cur >= self.buf.len) return null;

    const len = self.buf[self.cur];
    self.cur += 1;

    const key = self.buf[self.cur .. self.cur + len];
    self.cur += len;

    const isTerminated = self.buf[self.cur] == 0x1;

    if (isTerminated) {
        self.cur += 1;
        return Pair{ .key = key, .value = null };
    }

    const valueStart = self.cur;

    while (self.buf[self.cur] != 0x1) {
        self.cur += 1;
        if (self.cur == self.buf.len) return Pair{ .key = key, .value = null };
    }

    const value = self.buf[valueStart..self.cur];
    self.cur += 1; // skip the terminator

    return Pair{ .key = key, .value = value };
}
