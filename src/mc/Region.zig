//! A region file (`r.<x>.<z>.mca`): 32 × 32 chunks, each compressed on its own. A table of where
//! each chunk lies, then a table of when it was saved, 4,096 bytes each, then the chunks, on
//! whole sectors of 4,096 bytes.
const Region = @This();

const std = @import("std");
const lz4 = @import("lz4");
const Io = std.Io;
const flate = std.compress.flate;

/// The chunks along a side of a region.
pub const side = 32;

const sectorLength = 4096;
const headerLength = 2 * sectorLength;

/// The whole file.
bytes: []const u8,

pub const Error = error{
    /// A chunk that lies outside the file, or whose length doesn't fit its sectors.
    InvalidRegion,
    /// A custom compression, or a chunk too large for the region, kept in a file of its own.
    UnsupportedCompression,
    /// A chunk that doesn't decompress. `std` doesn't compare its checksum, so a damaged chunk
    /// may decompress, and show up as invalid NBT instead.
    InvalidChunk,
    /// A chunk larger than the buffer it's read into.
    ChunkTooLarge,
};

/// Which one a world uses is `region-file-compression` in its server's settings, and chunks saved
/// before that changed keep theirs.
const Compression = enum(u8) { gzip = 1, zlib = 2, none = 3, lz4 = 4 };

/// The chunk at (`x`, `z`) in the region, from 0 to `side`, decompressed into `buffer`; null
/// where the region has none.
pub fn chunk(self: Region, buffer: []u8, x: usize, z: usize) Error!?[]u8 {
    std.debug.assert(x < side and z < side);
    if (self.bytes.len < headerLength) return error.InvalidRegion;
    const at = (z * side + x) * 4;
    const location = std.mem.readInt(u32, self.bytes[at..][0..4], .big);
    if (location == 0) return null;
    const start = @as(usize, location >> 8) * sectorLength;
    const sectors = @as(usize, location & 0xFF) * sectorLength;
    if (start < headerLength or start > self.bytes.len or sectors > self.bytes.len - start or sectors < 5) return error.InvalidRegion;
    const stored = self.bytes[start..][0..sectors];
    const length = std.mem.readInt(u32, stored[0..4], .big);
    if (length < 1 or length > sectors - 4) return error.InvalidRegion;
    const compression = std.enums.fromInt(Compression, stored[4]) orelse return error.UnsupportedCompression;
    return try decompress(buffer, stored[5..][0 .. length - 1], compression);
}

fn decompress(buffer: []u8, compressed: []const u8, compression: Compression) Error![]u8 {
    const container: flate.Container = switch (compression) {
        .none => {
            if (compressed.len > buffer.len) return error.ChunkTooLarge;
            @memcpy(buffer[0..compressed.len], compressed);
            return buffer[0..compressed.len];
        },
        .lz4 => {
            const length = lz4.decompressStream(buffer, compressed) catch |err| return switch (err) {
                error.InvalidData => error.InvalidChunk,
                error.OutputTooLong => error.ChunkTooLarge,
            };
            return buffer[0..length];
        },
        .gzip => .gzip,
        .zlib => .zlib,
    };
    var input: Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&input, container, &window);
    var output: Io.Writer = .fixed(buffer);
    const length = inflate.reader.streamRemaining(&output) catch |err| switch (err) {
        error.WriteFailed => return error.ChunkTooLarge,
        error.ReadFailed => return error.InvalidChunk,
    };
    return buffer[0..length];
}

/// A region of one chunk at (`x`, `z`), 2 sectors after the tables.
fn testRegion(file: *[3 * sectorLength + headerLength]u8, x: usize, z: usize, stored: []const u8, compression: u8) void {
    @memset(file, 0);
    const location: u32 = (2 << 8) | 3;
    std.mem.writeInt(u32, file[(z * side + x) * 4 ..][0..4], location, .big);
    std.mem.writeInt(u32, file[headerLength..][0..4], @intCast(stored.len + 1), .big);
    file[headerLength + 4] = compression;
    @memcpy(file[headerLength + 5 ..][0..stored.len], stored);
}

test chunk {
    var file: [3 * sectorLength + headerLength]u8 = undefined;
    var buffer: [64]u8 = undefined;

    testRegion(&file, 3, 1, "plain", 3);
    const region: Region = .{ .bytes = &file };
    try std.testing.expectEqualStrings("plain", (try region.chunk(&buffer, 3, 1)).?);
    try std.testing.expectEqual(null, try region.chunk(&buffer, 1, 3));

    // zlib, in one stored block: its header, the block's lengths, and a checksum.
    const text = "a chunk";
    var zlib: [2 + 5 + text.len + 4]u8 = undefined;
    @memcpy(zlib[0..2], &[_]u8{ 0x78, 0x01 });
    zlib[2] = 1;
    std.mem.writeInt(u16, zlib[3..5], text.len, .little);
    std.mem.writeInt(u16, zlib[5..7], ~@as(u16, text.len), .little);
    @memcpy(zlib[7..][0..text.len], text);
    std.mem.writeInt(u32, zlib[7 + text.len ..][0..4], std.hash.Adler32.hash(text), .big);
    testRegion(&file, 0, 0, &zlib, 2);
    try std.testing.expectEqualStrings(text, (try region.chunk(&buffer, 0, 0)).?);

    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.ChunkTooLarge, region.chunk(&tiny, 0, 0));
    // A block of a type that doesn't exist.
    zlib[2] = 7;
    testRegion(&file, 0, 0, &zlib, 2);
    try std.testing.expectError(error.InvalidChunk, region.chunk(&buffer, 0, 0));

    // LZ4, in one block of 5 literals, then the block that ends the stream.
    const header = "LZ4Block".* ++ [_]u8{0x20} ++ [_]u8{ 6, 0, 0, 0 } ++ [_]u8{ 5, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 0 };
    const zeros: [12]u8 = @splat(0);
    const end = "LZ4Block".* ++ [_]u8{0x10} ++ zeros;
    testRegion(&file, 0, 0, &(header ++ [_]u8{0x50} ++ "fast!".* ++ end), 4);
    try std.testing.expectEqualStrings("fast!", (try region.chunk(&buffer, 0, 0)).?);
    try std.testing.expectError(error.ChunkTooLarge, region.chunk(&tiny, 0, 0));
    testRegion(&file, 0, 0, "not a stream", 4);
    try std.testing.expectError(error.InvalidChunk, region.chunk(&buffer, 0, 0));

    testRegion(&file, 0, 0, "x", 127);
    try std.testing.expectError(error.UnsupportedCompression, region.chunk(&buffer, 0, 0));
    testRegion(&file, 0, 0, "x", 0x82);
    try std.testing.expectError(error.UnsupportedCompression, region.chunk(&buffer, 0, 0));

    // A chunk whose sectors go past the end of the file, and one longer than its sectors.
    std.mem.writeInt(u32, file[0..4], (6 << 8) | 1, .big);
    try std.testing.expectError(error.InvalidRegion, region.chunk(&buffer, 0, 0));
    testRegion(&file, 0, 0, "x", 3);
    std.mem.writeInt(u32, file[headerLength..][0..4], 3 * sectorLength, .big);
    try std.testing.expectError(error.InvalidRegion, region.chunk(&buffer, 0, 0));
    try std.testing.expectError(error.InvalidRegion, (Region{ .bytes = file[0..100] }).chunk(&buffer, 0, 0));
}
