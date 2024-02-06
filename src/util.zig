const std = @import("std");

pub inline fn readU32(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

pub inline fn readI32(buf: []const u8) i32 {
    return std.mem.readInt(i32, buf[0..4], .little);
}

pub inline fn byteToInt(data: []const u8, output: []i32, length: i32) void {
    for (0..length) |index| output[index] = readI32(data[index * 4 ..]);
}

// it is unknown what this does
pub fn getRoundedUpSize(value: i32) i32 {
    const num1: i32 = value - 1;
    const num2: i32 = num1 | num1 >> 1;
    const num3: i32 = num2 | num2 >> 2;
    const num4: i32 = num3 | num3 >> 4;
    const num5: i32 = num4 | num4 >> 8;
    return (num5 | num5 >> 16) + 1;
}

pub fn byteToIntArrays(allocator: std.mem.Allocator, data: []const u8, output: [][]i32, count: i32) void {
    for (0..count) |i| {
        if (output[i] == null) output[i] = allocator.alloc(i32, 32 * 32);
        var numArray = output[i];
        for (0..numArray.len) |j| {
            numArray[j] = readI32(data[j * 4 ..]);
        }
    }
}

