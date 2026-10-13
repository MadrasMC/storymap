const std = @import("std");

const WireType = enum(u3) {
    VARINT,
    I64,
    LEN,
    SGROUP,
    EGROUP,
    I32,
};

const Tag = packed struct(u64) {
    wire_type: WireType,
    field_number: u61,
};

buf: []const u8,
cur: usize = 0,

const ProtoBuf = @This();

pub fn parseVarInt(self: *ProtoBuf) u64 {
    var i: usize = 0;
    var result: u64 = 0;
    while (i < 10) : (i += 1) {
        const x = self.buf[self.cur + i];
        result += @as(u64, x & 0b1111111) << @intCast(7 * i);
        if (x & (1 << 7) == 0) break;
    }
    self.cur += i + 1;
    return result;
}

test "117" {
    var parser = ProtoBuf{ .buf = &.{117} };
    try std.testing.expect(parser.parseVarInt() == 117);
}

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

pub fn next(self: *ProtoBuf) ?Message {
    if (self.cur == self.buf.len) return null;

    const tag: Tag = @bitCast(self.parseVarInt());
    switch (tag.wire_type) {
        .VARINT => {
            const value = self.parseVarInt();
            return .{ .field_number = tag.field_number, .data = .{ .VARINT = value } };
        },
        .LEN => {
            const len = self.parseVarInt();
            const value = self.buf[self.cur .. self.cur + len];
            self.cur += len;
            return .{ .field_number = tag.field_number, .data = .{ .LEN = value } };
        },
        // Fixed-width values (double, float, fixed32/64); `gamedata` has a few.
        .I64 => {
            const value = std.mem.readInt(u64, self.buf[self.cur..][0..8], .little);
            self.cur += 8;
            return .{ .field_number = tag.field_number, .data = .{ .I64 = value } };
        },
        .I32 => {
            const value = std.mem.readInt(u32, self.buf[self.cur..][0..4], .little);
            self.cur += 4;
            return .{ .field_number = tag.field_number, .data = .{ .I32 = value } };
        },
        .SGROUP, .EGROUP => {
            var buf: [32]u8 = undefined;
            @panic(std.fmt.bufPrint(
                &buf,
                "Deprecated wire type: {s}\n",
                .{@tagName(tag.wire_type)},
            ) catch unreachable);
        },
    }
}
