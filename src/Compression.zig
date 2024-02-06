const std = @import("std");
const util = @import("./util.zig");

pub fn decompressBuffer(allocator: std.mem.Allocator, input: []u8) !?[]u8 {
    const bufStream = std.io.fixedBufferStream(input);
    var decompressor = std.compress.zstd.decompressStream(allocator, bufStream);
    defer decompressor.deinit();
    const reader = decompressor.reader();
    return try reader.readAllAlloc(allocator, 102400);
}

pub fn decompressCombined(
    /// The allocator to use for the output data. This function will not call free. Pass an arena-like allocator to avoid memory leaks.
    allocator: std.mem.Allocator,
    /// The compressed input data (blocksCompressed, liquidsCompressed, etc)
    dataCompressed: []u8,
    /// Buffer to hold decompressed data output
    data: *[][]i32,
    /// The number of palettes in the decompressed data
    paletteCount: *i32,
) !?i32 {
    const length1: i32 = util.readI32(dataCompressed);
    if (length1 == 0) return null;
    var length2: i32 = undefined;
    var output: []i32 = undefined;
    if (length1 < 0) {
        length2 = (length1 * -1) / 4;
        if (length2 == 1) return null;
        output = try allocator.alloc(i32, util.getRoundedUpSize(length2));
        util.byteToInt(dataCompressed[4..], output, length2);
    } else {
        var buffer: []u8 = undefined;
        length2 = decompressAndSize(dataCompressed[4..length1], buffer) / 4;
        if (length2 == 1) return null;
        output = try allocator.alloc(i32, util.getRoundedUpSize(length2));
        util.byteToInt(dataCompressed, output, length2);
    }
    var count: i32 = 0;
    var length3: i32 = output.len;
    while (true) {
        length3 = length3 >> 1;
        if (length3 <= 0) break;
        count += 1;
    }
    if (data == null)
        data = try allocator.alloc([]i32, count);
    const data: []u8 = decompress(dataCompressed[length1 + 4 .. dataCompressed.Length - (length1 + 4)]);
    if (data.Length < count * 1024 * 4)
        return error.InvalidData;
    util.byteToIntArrays(allocator, data, data, count);
    paletteCount = length2;
    return output;
}
