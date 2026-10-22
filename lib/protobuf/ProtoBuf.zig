//! A minimal reader for the Protobuf wire format, without a schema:
//! https://protobuf.dev/programming-guides/encoding/
//!
//! Every read is bounds-checked, so truncated or corrupt data is an error, not a crash.
const ProtoBuf = @This();

const std = @import("std");

buf: []const u8,
cur: usize = 0,

pub const Error = error{
    /// The data ends in the middle of a field.
    EndOfData,
    /// A varint longer than 10 bytes, the most a 64-bit value needs.
    InvalidVarint,
    /// Wire types 3 and 4 (deprecated groups), or 6 and 7, which don't exist.
    UnsupportedWireType,
};

pub const Message = struct {
    field_number: u61,
    data: union(enum) {
        VARINT: u64,
        LEN: []const u8,
        I64: u64,
        I32: u32,
    },
    pub fn debugPrint(msg: Message) void {
        switch (msg.data) {
            .VARINT => |value| std.debug.print(
                "{}:{s} {}\n",
                .{ msg.field_number, @tagName(msg.data), value },
            ),
            inline .I64, .I32 => |value| std.debug.print(
                "{}:{s} 0x{x}\n",
                .{ msg.field_number, @tagName(msg.data), value },
            ),
            .LEN => |value| {
                var hasNonAscii = false;
                for (value) |c| if (c > 127) {
                    hasNonAscii = true;
                };
                if (hasNonAscii) {
                    std.debug.print(
                        "{}:{s} ({}) {x}\n",
                        .{ msg.field_number, @tagName(msg.data), value.len, value },
                    );
                } else {
                    std.debug.print(
                        "{}:{s} ({}) \"{s}\"\n",
                        .{ msg.field_number, @tagName(msg.data), value.len, value },
                    );
                }
            },
        }
    }
};

/// The next field, or null at the end of the data.
pub fn next(self: *ProtoBuf) Error!?Message {
    if (self.cur == self.buf.len) return null;
    const tag = try self.parseVarInt();
    // The low 3 bits are the wire type, the rest is the field number.
    const field_number: u61 = @intCast(tag >> 3);
    return .{
        .field_number = field_number,
        .data = switch (tag & 0b111) {
            0 => .{ .VARINT = try self.parseVarInt() },
            1 => .{ .I64 = std.mem.readInt(u64, (try self.take(8))[0..8], .little) },
            2 => blk: {
                const len = try self.parseVarInt();
                // Checked before narrowing, so a huge length can't overflow `usize`.
                if (len > self.buf.len - self.cur) return error.EndOfData;
                break :blk .{ .LEN = try self.take(@intCast(len)) };
            },
            5 => .{ .I32 = std.mem.readInt(u32, (try self.take(4))[0..4], .little) },
            else => return error.UnsupportedWireType,
        },
    };
}

pub fn parseVarInt(self: *ProtoBuf) Error!u64 {
    var result: u64 = 0;
    for (0..10) |i| {
        const byte = (try self.take(1))[0];
        result |= @as(u64, byte & 0x7f) << @intCast(7 * i);
        if (byte & 0x80 == 0) return result;
    }
    return error.InvalidVarint;
}

/// The only place that touches `buf` directly.
fn take(self: *ProtoBuf, len: usize) Error![]const u8 {
    if (self.buf.len - self.cur < len) return error.EndOfData;
    defer self.cur += len;
    return self.buf[self.cur..][0..len];
}

test "117" {
    var parser = ProtoBuf{ .buf = &.{117} };
    try std.testing.expect(try parser.parseVarInt() == 117);
}

test "every wire type" {
    // field 1 varint 300, field 2 bytes "hi", field 3 fixed64, field 4 fixed32.
    var parser: ProtoBuf = .{ .buf = &.{
        0x08, 0xac, 0x02, 0x12, 0x02, 'h', 'i', 0x19, 1, 0, 0, 0, 0, 0, 0, 0,
        0x25, 2,    0,    0,    0,
    } };
    try std.testing.expectEqual(300, (try parser.next()).?.data.VARINT);
    try std.testing.expectEqualStrings("hi", (try parser.next()).?.data.LEN);
    try std.testing.expectEqual(1, (try parser.next()).?.data.I64);
    const last = (try parser.next()).?;
    try std.testing.expectEqual(4, last.field_number);
    try std.testing.expectEqual(2, last.data.I32);
    try std.testing.expectEqual(null, try parser.next());
}

test "truncated and corrupt data are errors" {
    const cases = .{
        // bytes field claiming 5 bytes with 2 left
        .{ &[_]u8{ 0x12, 0x05, 'h', 'i' }, error.EndOfData },
        // varint whose continuation bit runs off the end
        .{ &[_]u8{ 0x08, 0x80 }, error.EndOfData },
        // tag cut off mid-varint
        .{ &[_]u8{0x80}, error.EndOfData },
        // fixed64 and fixed32 with too few bytes
        .{ &[_]u8{ 0x09, 1, 2, 3 }, error.EndOfData },
        .{ &[_]u8{ 0x0d, 1, 2 }, error.EndOfData },
        // a length so large it doesn't fit in memory
        .{ &[_]u8{ 0x12, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, error.EndOfData },
        // 11-byte varint
        .{ &[_]u8{ 0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 }, error.InvalidVarint },
        // wire types 3 (group) and 7 (doesn't exist)
        .{ &[_]u8{0x0b}, error.UnsupportedWireType },
        .{ &[_]u8{0x0f}, error.UnsupportedWireType },
    };
    inline for (cases) |case| {
        var parser: ProtoBuf = .{ .buf = case[0] };
        try std.testing.expectError(case[1], parser.next());
    }
}
