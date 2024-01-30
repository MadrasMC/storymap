const std = @import("std");

const BlockEntity = @This();

const Position = struct {
    x: u32,
    y: u32,
    z: u32,
};

class: []const u8,
position: Position,
blockCode: []const u8,

fn readU32(buf: []const u8) u32 {
    const value = @as(*align(1) const u32, @ptrCast(buf)).*;
    return std.mem.littleToNative(u32, value);
}

pub fn from(buf: []const u8) BlockEntity {
    var cur: usize = 0;

    const classLen = buf[0];
    const class = buf[1 .. 1 + classLen];
    cur = 1 + classLen;

    // ignore "1", "4" for "posx" length, and "posx"
    cur += 1 + 1 + 4;

    const posx = buf[cur .. cur + 4];
    cur += 4;

    // ignore "1", "4" for "posy" length, and "posy"
    cur += 1 + 1 + 4;

    const posy = buf[cur .. cur + 4];
    cur += 4;

    // ignore "1", "4" for "posz" length, and "posz"
    cur += 1 + 1 + 4;

    const posz = buf[cur .. cur + 4];
    cur += 4;

    const position = Position{
        .x = readU32(posx),
        .y = readU32(posy),
        .z = readU32(posz),
    };

    if (!std.mem.eql(u8, buf[cur .. cur + 2], ([_]u8{ 0x05, 0x09 })[0..2])) {
        std.debug.print("expected 0x05 0x09, got {x}", .{buf[cur .. cur + 2]});
        std.process.exit(1);
    }

    // ignore next two bytes (I don't know what this is, but it seems to be always 0x5 followed by 0x09)
    cur += 2;

    if (!std.mem.eql(u8, buf[cur .. cur + 9], "blockCode")) {
        std.debug.print("expected 'blockCode', got {x}", .{buf[cur .. cur + 9]});
        std.process.exit(1);
    }

    cur += 9;

    const blockCodeLen = buf[cur];
    cur += 1;

    const blockCode = buf[cur .. cur + blockCodeLen];

    return .{
        .class = class,
        .position = position,
        .blockCode = blockCode,
    };
}
