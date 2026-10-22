//! Decodes a chunk's block or liquid layer (fields 1 and 16): a palette, then zstd-compressed
//! bit planes. Layout, and how it was verified: docs/save-format/README.md §4.
//!
//! Every length in the data is checked, so truncated or corrupt data is an error, not a crash.
//! Nothing here allocates: a `Layer` is fixed-size and a `Decompressor` is set up once.
const std = @import("std");
const zstd = @import("zstd");

pub const Error = error{InvalidData};

pub const maxPlanes = 15;
pub const maxPalette = 1 << maxPlanes;
/// One bit for each of a chunk's 32,768 blocks: 1,024 words.
pub const planeWords = 1024;

pub const Layer = struct {
    /// How many planes are in use; 0 for an empty layer, whose palette[0] is 0 (air).
    bits: u4 = 0,
    /// Block IDs. The first 2^bits are valid; slots past the stored entries are 0 (air).
    palette: [maxPalette]i32 = undefined,
    /// Bit planes: `planes[b]` holds bit `b` of every block's palette index.
    planes: [maxPlanes][planeWords]u32 = undefined,

    /// The block ID at chunk-local index `(y * 32 + z) * 32 + x`. 0 is air.
    pub fn get(self: *const Layer, index3d: usize) i32 {
        var index: usize = 0;
        for (self.planes[0..self.bits], 0..) |*plane, b| {
            const bit: usize = (plane[index3d / 32] >> @intCast(index3d % 32)) & 1;
            index |= bit << @intCast(b);
        }
        return self.palette[index];
    }

    pub fn clear(self: *Layer) void {
        self.bits = 0;
        self.palette[0] = 0;
    }

    /// On error the layer is empty.
    pub fn decode(self: *Layer, decompressor: Decompressor, bytes: []const u8) Error!void {
        self.clear();
        errdefer self.clear();
        if (bytes.len < 4) return error.InvalidData;
        // Negative: the palette is stored raw, that many bytes. Positive: zstd, that many bytes.
        const length = std.mem.readInt(i32, bytes[0..4], .little);
        if (length == 0) return;
        const paletteLen: usize = @abs(length);
        if (paletteLen > bytes.len - 4) return error.InvalidData;
        const paletteBytes = bytes[4..][0..paletteLen];
        const planeBytes = bytes[4 + paletteLen ..];

        // The palette goes straight into its array; its byte size is also the size limit.
        const paletteOut = std.mem.sliceAsBytes(&self.palette);
        const rawPalette = if (length < 0) raw: {
            if (paletteLen > paletteOut.len) return error.InvalidData;
            @memcpy(paletteOut[0..paletteLen], paletteBytes);
            break :raw paletteOut[0..paletteLen];
        } else try decompressor.decompress(paletteOut, paletteBytes);
        const count = rawPalette.len / 4;
        if (count <= 1) return self.clear();
        for (self.palette[0..count]) |*entry| entry.* = std.mem.littleToNative(i32, entry.*);
        const slots = std.math.ceilPowerOfTwoAssert(usize, count);
        @memset(self.palette[count..slots], 0);
        const bits = std.math.log2_int(usize, slots);

        const planeData = try decompressor.decompress(std.mem.sliceAsBytes(&self.planes), planeBytes);
        if (planeData.len < @as(usize, bits) * planeWords * 4) return error.InvalidData;
        for (self.planes[0..bits]) |*plane| {
            for (plane) |*word| word.* = std.mem.littleToNative(u32, word.*);
        }
        self.bits = @intCast(bits);
    }
};

/// A zstd decompression context in a buffer allocated once.
pub const Decompressor = struct {
    workspace: []align(8) u8,
    dctx: *zstd.ZSTD_DCtx,

    pub fn init(allocator: std.mem.Allocator) !Decompressor {
        const workspace = try allocator.alignedAlloc(u8, .@"8", zstd.ZSTD_estimateDCtxSize());
        errdefer allocator.free(workspace);
        const dctx = zstd.ZSTD_initStaticDCtx(workspace.ptr, workspace.len) orelse return error.ZstdSetupFailed;
        return .{ .workspace = workspace, .dctx = dctx };
    }

    pub fn deinit(self: Decompressor, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
    }

    /// Refuses a frame whose stated size doesn't fit in `out`.
    fn decompress(self: Decompressor, out: []u8, frame: []const u8) Error![]u8 {
        // Unknown and invalid sizes are reported as the two largest values, so the limit covers them.
        const size = zstd.ZSTD_getFrameContentSize(frame.ptr, frame.len);
        if (size > out.len) return error.InvalidData;
        const written = zstd.ZSTD_decompressDCtx(self.dctx, out.ptr, @intCast(size), frame.ptr, frame.len);
        if (zstd.ZSTD_isError(written) != 0 or written != size) return error.InvalidData;
        return out[0..written];
    }
};

test "the one-block chunk from the 1.19 sample" {
    // Field 1 of chunk (15995, 4, 15999): raw palette [0, 164], then a 27-byte zstd frame
    // of one plane with a single bit set, word 242 bit 5.
    const bytes = [_]u8{
        0xf8, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xa4, 0x00, 0x00, 0x00, 0x28, 0xb5, 0x2f, 0xfd,
        0x60, 0x00, 0x0f, 0x8d, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x02, 0x00,
        0x32, 0x04, 0xfe, 0x08, 0x5e, 0x01, 0x22,
    };
    const decompressor: Decompressor = try .init(std.testing.allocator);
    defer decompressor.deinit(std.testing.allocator);
    const layer = try std.testing.allocator.create(Layer);
    defer std.testing.allocator.destroy(layer);
    try layer.decode(decompressor, &bytes);
    try std.testing.expectEqual(1, layer.bits);
    try std.testing.expectEqualSlices(i32, &.{ 0, 164 }, layer.palette[0..2]);
    for (layer.planes[0], 0..) |word, w| try std.testing.expectEqual(if (w == 242) @as(u32, 1 << 5) else 0, word);
    // Block (5, 7, 18) is n = 7,749: word 242, bit 5.
    try std.testing.expectEqual(164, layer.get(7749));
    try std.testing.expectEqual(0, layer.get(0));
}

test "a palette that isn't a power of two is padded with air" {
    // Raw palette [0, 5, 7]: 3 entries, so 4 slots and 2 planes. Then 2 planes of zeros.
    const decompressor: Decompressor = try .init(std.testing.allocator);
    defer decompressor.deinit(std.testing.allocator);
    const layer = try std.testing.allocator.create(Layer);
    defer std.testing.allocator.destroy(layer);
    // Leftovers from an earlier chunk must not show through the padding.
    @memset(&layer.palette, 99);
    var bytes: [16]u8 = undefined;
    const frame = try compressZeros(&bytes, 2 * planeWords * 4);
    var field: [512]u8 = undefined;
    @memcpy(field[0..16], &[_]u8{ 0xf4, 0xff, 0xff, 0xff, 0, 0, 0, 0, 5, 0, 0, 0, 7, 0, 0, 0 });
    @memcpy(field[16..][0..frame.len], frame);
    try layer.decode(decompressor, field[0 .. 16 + frame.len]);
    try std.testing.expectEqual(2, layer.bits);
    try std.testing.expectEqualSlices(i32, &.{ 0, 5, 7, 0 }, layer.palette[0..4]);
}

/// A zstd frame of `len` zero bytes, for tests. The vendored zstd only has the decompressor,
/// so the frame is built by hand as a single RLE block.
fn compressZeros(out: []u8, len: usize) ![]const u8 {
    // Magic, frame header (single segment, 2-byte content size), one RLE block holding 0x00.
    const content: u16 = @intCast(len - 256);
    const header = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x60, @truncate(content), @truncate(content >> 8) };
    const block: u24 = (@as(u24, @intCast(len)) << 3) | (1 << 1) | 1; // last block, type RLE
    @memcpy(out[0..7], &header);
    std.mem.writeInt(u24, out[7..10], block, .little);
    out[10] = 0;
    return out[0..11];
}

test "truncated and corrupt layers are errors and leave the layer empty" {
    const cases = [_][]const u8{
        &.{ 0xf8, 0xff }, // shorter than the length
        &.{ 0xf8, 0xff, 0xff, 0xff, 0, 0, 0, 0 }, // raw palette of 8 bytes, only 4 there
        &.{ 0x00, 0x00, 0x00, 0x80 }, // the most negative length, which can't be negated in an i32
        &.{ 0xf8, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1, 0, 0, 0 }, // palette but no plane frame
        &.{ 0xf8, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1, 0, 0, 0, 0x28, 0xb5, 0x2f, 0xfd, 0x60 }, // cut-off frame
        &.{ 0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4 }, // "compressed" palette that isn't zstd
    };
    const decompressor: Decompressor = try .init(std.testing.allocator);
    defer decompressor.deinit(std.testing.allocator);
    const layer = try std.testing.allocator.create(Layer);
    defer std.testing.allocator.destroy(layer);
    for (cases) |bytes| {
        try std.testing.expectError(error.InvalidData, layer.decode(decompressor, bytes));
        try std.testing.expectEqual(0, layer.bits);
        try std.testing.expectEqual(0, layer.get(1234));
    }
}
