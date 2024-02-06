const std = @import("std");
const util = @import("./util.zig");
const zstd = @import("zstd");

pub const Compression = struct {
    pub fn DecompressCombined(
        allocator: std.mem.Allocator,
        blocksCompressed: []const u8,
        blocks: *[][]i32,
        refCount: *i32,
        newArray: *const fn () std.mem.Allocator.Error![]i32,
    ) ![]i32 {
        var length1 = ArrayConvert.GetInt(blocksCompressed);
        if (length1 == 0) return &.{};
        var length2: i32 = 0;
        var output: []i32 = &.{};
        if (length1 < 0) {
            length1 *= -1;
            length2 = @divTrunc(length1, 4);
            if (length2 == 1) return &.{};
            output = try allocator.alloc(i32, @intCast(ArrayConvert.GetRoundedUpSize(length2)));
            ArrayConvert.ByteToIntOffset(blocksCompressed, 4, output, length2);
        } else {
            var buffer: []u8 = &.{};
            length2 = @divTrunc(try Compression.Compression1.DecompressAndSizeOffset(allocator, blocksCompressed, 4, length1, &buffer), 4);
            if (length2 == 1) return &.{};
            output = try allocator.alloc(i32, @intCast(ArrayConvert.GetRoundedUpSize(length2)));
            ArrayConvert.ByteToInt(buffer, output, length2);
        }
        var count: i32 = 0;
        var length3 = output.len;
        while ((length3 >> 1) > 0) : (length3 = length3 >> 1) count += 1;
        if (blocks.len == 0) blocks.* = try allocator.alloc([]i32, 15);
        for (blocks.*) |*block| block.* = &.{};
        const data = try Compression.Compression1.Decompress(allocator, blocksCompressed, length1 + 4, @as(i32, @intCast(blocksCompressed.len)) - (length1 + 4));
        if (data.len < count * 1024 * 4) return error.InvalidData;
        try ArrayConvert.ByteToIntArrays(data, blocks, count, newArray);
        refCount.* = length2;
        return output;
    }
    pub const Compression1 = struct {
        pub fn DecompressAndSize(compressedData: []const u8, buffer: *[]u8) !i32 {
            const compressedFrame = compressedData;
            const decompressedSize = ZStdWrapper.GetDecompressedSize(compressedFrame);
            buffer.* = GetOrCreateBuffer(decompressedSize);
            return (if (CompressionZSTD.reusableDecompressor) |decompressor| decompressor else b: {
                CompressionZSTD.reusableDecompressor = ZStdWrapper.CreateDecompressor();
                break :b CompressionZSTD.reusableDecompressor;
            }).Decompress(buffer, compressedFrame);
        }
        pub fn DecompressAndSizeOffset(allocator: std.mem.Allocator, compressedData: []const u8, offset: i32, length: i32, buffer: *[]u8) !i32 {
            const compressedFrame = compressedData[@intCast(offset)..@intCast(offset + length)];
            const decompressedSize = ZStdWrapper.GetDecompressedSize(compressedFrame);
            buffer.* = try GetOrCreateBuffer(allocator, decompressedSize);
            return (if (CompressionZSTD.reusableDecompressor) |decompressor| decompressor else b: {
                CompressionZSTD.reusableDecompressor = ZStdWrapper.CreateDecompressor();
                break :b CompressionZSTD.reusableDecompressor.?;
            }).Decompress(buffer.*, compressedFrame);
        }
        pub fn GetOrCreateBuffer(allocator: std.mem.Allocator, size: usize) ![]u8 {
            var buffer = CompressionZSTD.reusableBuffer;
            if (buffer.len == 0) {
                buffer = try allocator.alloc(u8, size);
                CompressionZSTD.reusableBuffer = buffer;
            }
            return buffer;
        }
        pub fn Decompress(allocator: std.mem.Allocator, fi: []const u8, offset: i32, length: i32) ![]u8 {
            var buffer: []u8 = &.{};
            const length1 = try DecompressAndSizeOffset(allocator, fi, offset, length, &buffer);
            return ArrayConvert.ByteToByte(allocator, buffer, length1);
        }
    };
};

pub const CompressionZSTD = struct {
    pub var reusableBuffer: []u8 = &.{};
    pub var reusableDecompressor: ?ZStdDecompressorImpl = null;
};

pub const ZStdDecompressorImpl = struct {
    dCtx: *zstd.ZSTD_DCtx,
    pub fn Decompress(self: ZStdDecompressorImpl, output: []u8, input: []const u8) i32 {
        return @intCast(zstd.ZSTD_decompressDCtx(self.dCtx, output.ptr, output.len, input.ptr, input.len));
    }
};

pub const ZStdWrapper = struct {
    pub fn GetDecompressedSize(compressedFrame: []const u8) usize {
        return zstd.ZSTD_getFrameContentSize(compressedFrame.ptr, compressedFrame.len);
    }
    pub fn CreateDecompressor() ZStdDecompressorImpl {
        return ZStdDecompressorImpl{
            .dCtx = zstd.ZSTD_createDCtx().?,
        };
    }
};

pub const ArrayConvert = struct {
    pub fn GetInt(output: []const u8) i32 {
        return util.readI32(output);
    }
    pub fn GetRoundedUpSize(value: i32) i32 {
        const num1 = value - 1;
        const num2 = if (num1 != 0) num1 else num1 >> 1;
        const num3 = if (num2 != 0) num2 else num2 >> 2;
        const num4 = if (num3 != 0) num3 else num3 >> 4;
        const num5 = if (num4 != 0) num4 else num4 >> 8;
        return (if (num5 != 0) num5 else num5 >> 16) + 1;
    }
    pub fn ByteToByte(allocator: std.mem.Allocator, data: []const u8, length: i32) ![]u8 {
        const numArray = try allocator.alloc(u8, @intCast(length));
        if (length == 0) return numArray;
        const num = @divTrunc(length, 4) * 4;
        var index: usize = 0;
        while (index < num) : (index += 4) {
            numArray[index] = data[index];
            numArray[index + 1] = data[index + 1];
            numArray[index + 2] = data[index + 2];
            numArray[index + 3] = data[index + 3];
        }
        while (index < length) {
            numArray[index] = data[index];
            index += 1;
        }
        return numArray;
    }
    pub fn ByteToInt(data: []const u8, output: []i32, length: i32) void {
        const numPtr = data.ptr;
        for (0..@intCast(length)) |index| {
            output[index] = @as([*]const i32, @alignCast(@ptrCast(numPtr)))[index];
        }
    }
    pub fn ByteToIntOffset(data: []const u8, offset: i32, output: []i32, length: i32) void {
        const numPtr1 = data.ptr;
        const numPtr2: [*]align(1) const i32 = @alignCast(@ptrCast(numPtr1 + @as(usize, @intCast(@divTrunc(offset, 4) * 4))));
        for (0..@intCast(length)) |index| {
            output[index] = numPtr2[index];
        }
    }
    pub fn ByteToIntArrays(data: []const u8, output: *[][]i32, count: i32, newArray: *const fn () std.mem.Allocator.Error![]i32) !void {
        for (0..@intCast(count)) |index| {
            if (output.*[index].len == 0) output.*[index] = try newArray();
        }
        const numPtr1 = data.ptr;
        var numPtr2: [*]const i32 = @alignCast(@ptrCast(numPtr1));
        for (0..@intCast(count)) |index1| {
            const numArray = output.*[index1];
            var index2: usize = 0;
            while (index2 < numArray.len) : (index2 += 4) {
                numArray[index2] = numPtr2[0];
                numArray[index2 + 1] = numPtr2[1];
                numArray[index2 + 2] = numPtr2[2];
                numArray[index2 + 3] = numPtr2[3];
                numPtr2 += 4;
            }
        }
    }
};

pub fn decompressBuffer(allocator: std.mem.Allocator, input: []u8) !?[]u8 {
    const bufStream = std.io.fixedBufferStream(input);
    var decompressor = std.compress.zstd.decompressStream(allocator, bufStream);
    defer decompressor.deinit();
    const reader = decompressor.reader();
    return try reader.readAllAlloc(allocator, 102400);
}

// pub fn decompressCombined(
//     /// The allocator to use for the output data. This function will not call free. Pass an arena-like allocator to avoid memory leaks.
//     allocator: std.mem.Allocator,
//     /// The compressed input data (blocksCompressed, liquidsCompressed, etc)
//     dataCompressed: []u8,
//     /// Buffer to hold decompressed data output
//     data: *[][]i32,
//     /// The number of palettes in the decompressed data
//     paletteCount: *i32,
// ) !?i32 {
//     const length1: i32 = util.readI32(dataCompressed);
//     if (length1 == 0) return null;
//     var length2: i32 = undefined;
//     var output: []i32 = undefined;
//     if (length1 < 0) {
//         length2 = (length1 * -1) / 4;
//         if (length2 == 1) return null;
//         output = try allocator.alloc(i32, util.getRoundedUpSize(length2));
//         util.byteToInt(dataCompressed[4..], output, length2);
//     } else {
//         var buffer: []u8 = undefined;
//         length2 = decompressAndSize(dataCompressed[4..length1], buffer) / 4;
//         if (length2 == 1) return null;
//         output = try allocator.alloc(i32, util.getRoundedUpSize(length2));
//         util.byteToInt(dataCompressed, output, length2);
//     }
//     var count: i32 = 0;
//     var length3: i32 = output.len;
//     while (true) {
//         length3 = length3 >> 1;
//         if (length3 <= 0) break;
//         count += 1;
//     }
//     if (data == null)
//         data = try allocator.alloc([]i32, count);
//     const data: []u8 = decompress(dataCompressed[length1 + 4 .. dataCompressed.Length - (length1 + 4)]);
//     if (data.Length < count * 1024 * 4)
//         return error.InvalidData;
//     util.byteToIntArrays(allocator, data, data, count);
//     paletteCount = length2;
//     return output;
// }
