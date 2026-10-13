//! Decodes a chunk's block or liquid layer (fields 1 and 16): a palette, then zstd-compressed
//! bit planes. Layout: docs/save-format/README.md §4. Originally ported from the game's C#.
//!
//! Every length in the data is checked, so truncated or corrupt data is an error, not a crash.
const std = @import("std");
const util = @import("./util.zig");
const zstd = @import("zstd");

pub const Error = error{ InvalidData, OutOfMemory };

/// 15 bit planes at most, so at most 2^15 palette slots.
const maxPlanes = 15;
const maxPalette = 1 << maxPlanes;
/// One plane is 32,768 bits: 1,024 i32s.
const planeWords = 1024;

pub const Layer = struct {
    /// Bit planes: `planes[b]` holds bit `b` of every block's palette index. See `Chunk.getBlock`.
    planes: [][]i32,
    /// Block IDs, rounded up to a power of two with the extra slots set to 0 (air).
    palette: []i32,

    pub fn deinit(self: Layer, allocator: std.mem.Allocator) void {
        for (self.planes) |plane| allocator.free(plane);
        allocator.free(self.planes);
        allocator.free(self.palette);
    }
};

/// The decoded layer, or null if it holds nothing (no palette, or only air).
pub fn decodeLayer(allocator: std.mem.Allocator, bytes: []const u8) Error!?Layer {
    if (bytes.len < 4) return error.InvalidData;
    // Negative: the palette is stored raw, that many bytes. Positive: zstd, that many bytes.
    const length = std.mem.readInt(i32, bytes[0..4], .little);
    if (length == 0) return null;
    const paletteLen: usize = @abs(length);
    if (paletteLen > bytes.len - 4) return error.InvalidData;
    const paletteBytes = bytes[4..][0..paletteLen];
    const planeBytes = bytes[4 + paletteLen ..];

    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    const rawPalette = if (length < 0) paletteBytes else try decompressor.decompress(allocator, paletteBytes, maxPalette * 4);
    defer if (length > 0) allocator.free(rawPalette);
    const count = rawPalette.len / 4;
    if (count <= 1) return null;
    if (count > maxPalette) return error.InvalidData;
    const palette = try readPalette(allocator, rawPalette, count);
    errdefer allocator.free(palette);
    const bits: usize = std.math.log2_int(usize, palette.len);

    const planeData = try decompressor.decompress(allocator, planeBytes, maxPlanes * planeWords * 4);
    defer allocator.free(planeData);
    if (planeData.len < bits * planeWords * 4) return error.InvalidData;

    const planes = try allocator.alloc([]i32, bits);
    var filled: usize = 0;
    errdefer {
        for (planes[0..filled]) |plane| allocator.free(plane);
        allocator.free(planes);
    }
    for (planes, 0..) |*plane, b| {
        plane.* = try allocator.alloc(i32, planeWords);
        filled += 1;
        // readInt rather than a pointer cast: the buffer has no alignment guarantee.
        for (plane.*, 0..) |*word, w| word.* = std.mem.readInt(i32, planeData[(b * planeWords + w) * 4 ..][0..4], .little);
    }
    return .{ .planes = planes, .palette = palette };
}

pub const ArrayConvert = struct {
    pub fn GetRoundedUpSize(value: usize) usize {
        const num1 = value - 1;
        const num2 = num1 | num1 >> 1;
        const num3 = num2 | num2 >> 2;
        const num4 = num3 | num3 >> 4;
        const num5 = num4 | num4 >> 8;
        return (num5 | num5 >> 16) + 1;
    }
};

/// Reads `count` little-endian palette entries into an array rounded up to a power of two.
/// The unused tail is zeroed (air), so stray bit-plane indices can't read garbage.
fn readPalette(allocator: std.mem.Allocator, bytes: []const u8, count: usize) ![]i32 {
    const palette = try allocator.alloc(i32, ArrayConvert.GetRoundedUpSize(count));
    for (palette[0..count], 0..) |*entry, i| entry.* = util.readI32(bytes[i * 4 ..]);
    @memset(palette[count..], 0);
    return palette;
}

/// A zstd decompression context whose memory comes from a Zig allocator.
const Decompressor = struct {
    /// zstd keeps this pointer as its allocation context, so it needs a stable address.
    allocatorPtr: *const std.mem.Allocator,
    dctx: *zstd.ZSTD_DCtx,

    fn init(allocator: std.mem.Allocator) Error!Decompressor {
        const allocatorPtr = try allocator.create(std.mem.Allocator);
        errdefer allocator.destroy(allocatorPtr);
        allocatorPtr.* = allocator;
        const dctx = zstd.ZSTD_createDCtx_advanced(.{
            .@"opaque" = allocatorPtr,
            .customAlloc = ZstdAllocator.alloc,
            .customFree = ZstdAllocator.free,
        }) orelse return error.OutOfMemory;
        return .{ .allocatorPtr = allocatorPtr, .dctx = dctx };
    }

    fn deinit(self: Decompressor) void {
        _ = zstd.ZSTD_freeDCtx(self.dctx);
        const allocator = self.allocatorPtr.*;
        allocator.destroy(self.allocatorPtr);
    }

    /// Decompresses one frame whose header states its size, refusing anything over `maxSize`.
    fn decompress(self: Decompressor, allocator: std.mem.Allocator, frame: []const u8, maxSize: usize) Error![]u8 {
        // Unknown and invalid sizes are reported as the two largest values, so the limit covers them.
        const size = zstd.ZSTD_getFrameContentSize(frame.ptr, frame.len);
        if (size > maxSize) return error.InvalidData;
        const out = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(out);
        const written = zstd.ZSTD_decompressDCtx(self.dctx, out.ptr, out.len, frame.ptr, frame.len);
        if (zstd.ZSTD_isError(written) != 0 or written != out.len) return error.InvalidData;
        return out;
    }
};

const ZstdAllocator = struct {
    fn alloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const ally: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        const slice = ally.alignedAlloc(u8, .@"16", size + 16) catch return null;
        @as(*usize, @ptrCast(slice.ptr)).* = slice.len;
        return slice.ptr + 16;
    }
    fn free(ctx: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        const ally: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        const base: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(ptr.?)) - 16);
        const slice = base[0..@as(*const usize, @ptrCast(base)).*];
        ally.free(slice);
    }
};

test "readPalette zero-pads to a power of two" {
    const bytes = [_]u8{ 0, 0, 0, 0, 5, 0, 0, 0, 7, 0, 0, 0 };
    const palette = try readPalette(std.testing.allocator, &bytes, 3);
    defer std.testing.allocator.free(palette);
    try std.testing.expectEqualSlices(i32, &.{ 0, 5, 7, 0 }, palette);
}

test "the one-block chunk from the 1.19 sample" {
    // Field 1 of chunk (15995, 4, 15999): raw palette [0, 164], then a 27-byte zstd frame
    // of one plane with a single bit set, word 242 bit 5.
    const bytes = [_]u8{
        0xf8, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xa4, 0x00, 0x00, 0x00, 0x28, 0xb5, 0x2f, 0xfd,
        0x60, 0x00, 0x0f, 0x8d, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x02, 0x00,
        0x32, 0x04, 0xfe, 0x08, 0x5e, 0x01, 0x22,
    };
    const layer = (try decodeLayer(std.testing.allocator, &bytes)).?;
    defer layer.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(i32, &.{ 0, 164 }, layer.palette);
    try std.testing.expectEqual(1, layer.planes.len);
    for (layer.planes[0], 0..) |word, w| try std.testing.expectEqual(if (w == 242) @as(i32, 1 << 5) else 0, word);
}

test "truncated and corrupt layers are errors, without leaks" {
    const cases = [_][]const u8{
        &.{ 0xf8, 0xff }, // shorter than the length
        &.{ 0xf8, 0xff, 0xff, 0xff, 0, 0, 0, 0 }, // raw palette of 8 bytes, only 4 there
        &.{ 0x00, 0x00, 0x00, 0x80 }, // the most negative length, which can't be negated in an i32
        &.{ 0xf8, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1, 0, 0, 0 }, // palette but no plane frame
        &.{ 0xf8, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1, 0, 0, 0, 0x28, 0xb5, 0x2f, 0xfd, 0x60 }, // cut-off frame
        &.{ 0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4 }, // "compressed" palette that isn't zstd
    };
    for (cases) |bytes| try std.testing.expectError(error.InvalidData, decodeLayer(std.testing.allocator, bytes));
}
