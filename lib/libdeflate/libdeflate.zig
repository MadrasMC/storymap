//! Deflate compression into zlib streams, with libdeflate: of a whole buffer at once, or a chunk
//! at a time. A `Compressor` is set up once, for one level, and allocates nothing while
//! compressing.
const std = @import("std");
const c = @import("header");

/// Added by `deflate_compress.c`'s patch, so not in `libdeflate.h`.
extern fn libdeflate_deflate_compress_chunk(compressor: *c.libdeflate_compressor, in: ?*const anyopaque, in_nbytes: usize, out: ?*anyopaque, out_nbytes_avail: usize, is_final: c_int) usize;

/// The highest level: 0 stores the data uncompressed, 1 is the fastest that compresses, and 10
/// to 12 search for the smallest output, slowly.
pub const maxLevel = 12;

/// A zlib stream's first two bytes, for deflate with a 32 KiB window; they name the fastest
/// level, which is only a hint to whoever reads it.
pub const zlibHeader = [2]u8{ 0x78, 0x01 };

/// `adler`, a running Adler-32 that starts at 1, with `data` added: a zlib stream ends with that
/// of all its data, big-endian.
pub fn adler32(adler: u32, data: []const u8) u32 {
    return c.libdeflate_adler32(adler, data.ptr, data.len);
}

/// `crc`, a running CRC-32 (zlib's and PNG's) that starts at 0, with `data` added.
pub fn crc32(crc: u32, data: []const u8) u32 {
    return c.libdeflate_crc32(crc, data.ptr, data.len);
}

test crc32 {
    var data: [5000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(3);
    prng.random().bytes(&data);
    // Lengths around the vector widths, and a running CRC over two parts.
    for ([_]usize{ 0, 1, 15, 16, 17, 63, 64, 65, 255, 256, 4999, 5000 }) |length| {
        try std.testing.expectEqual(std.hash.Crc32.hash(data[0..length]), crc32(0, data[0..length]));
        try std.testing.expectEqual(std.hash.Crc32.hash(data[0..length]), crc32(crc32(0, data[0 .. length / 3]), data[length / 3 .. length]));
    }
}

pub const Options = struct {
    /// From 0 to `maxLevel`.
    level: u4 = 1,
};

pub const Compressor = struct {
    handle: *c.libdeflate_compressor,

    /// libdeflate allocates its working memory with `malloc` here; error.OutOfMemory if it can't.
    pub fn init(options: Options) error{OutOfMemory}!Compressor {
        std.debug.assert(options.level <= maxLevel);
        return .{ .handle = c.libdeflate_alloc_compressor(options.level) orelse return error.OutOfMemory };
    }

    pub fn deinit(self: Compressor) void {
        c.libdeflate_free_compressor(self.handle);
    }

    /// The most a zlib stream of `bytes` bytes of data takes.
    pub fn zlibBound(self: Compressor, bytes: usize) usize {
        return c.libdeflate_zlib_compress_bound(self.handle, bytes);
    }

    /// Compresses `data` into a zlib stream at the start of `out`, and returns its length.
    /// error.NoSpace if it doesn't fit, which an `out` of `zlibBound(data.len)` bytes rules out.
    pub fn compress(self: Compressor, out: []u8, data: []const u8) error{NoSpace}!usize {
        const length = c.libdeflate_zlib_compress(self.handle, data.ptr, data.len, out.ptr, out.len);
        return if (length == 0) error.NoSpace else length;
    }

    /// The most `compressChunk` writes for `bytes` bytes of data.
    pub fn chunkBound(self: Compressor, bytes: usize) usize {
        return c.libdeflate_deflate_compress_bound(self.handle, bytes) + 5;
    }

    /// Compresses `data` as the next chunk of a deflate stream, at the start of `out`, and returns
    /// its length. Unless it's the `last`, the stream goes on: no block is final, and the chunk
    /// ends on a byte boundary so the next one follows it. Each chunk is compressed without the
    /// history of the ones before it. A zlib stream is `zlibHeader`, the chunks, and `adler32` of
    /// all their data. error.NoSpace if it doesn't fit, which an `out` of `chunkBound(data.len)`
    /// bytes rules out.
    pub fn compressChunk(self: Compressor, out: []u8, data: []const u8, last: bool) error{NoSpace}!usize {
        const length = libdeflate_deflate_compress_chunk(self.handle, data.ptr, data.len, out.ptr, out.len, @intFromBool(last));
        return if (length == 0) error.NoSpace else length;
    }
};

test Compressor {
    const allocator = std.testing.allocator;
    // Runs of bytes and noise, so every level has matches to find and literals to code.
    const data = try allocator.alloc(u8, 300_000);
    defer allocator.free(data);
    var prng: std.Random.DefaultPrng = .init(1);
    for (data, 0..) |*byte, i| byte.* = if ((i / 1000) % 3 == 0) prng.random().int(u8) else @intCast(i / 1000 % 251);

    for (0..maxLevel + 1) |level| {
        const compressor: Compressor = try .init(.{ .level = @intCast(level) });
        defer compressor.deinit();
        const out = try allocator.alloc(u8, compressor.zlibBound(data.len));
        defer allocator.free(out);
        const length = try compressor.compress(out, data);
        if (level > 0) try std.testing.expect(length < data.len / 2);

        var input: std.Io.Reader = .fixed(out[0..length]);
        var history: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &history);
        const back = try decompress.reader.allocRemaining(allocator, .unlimited);
        defer allocator.free(back);
        try std.testing.expectEqualSlices(u8, data, back);
    }

    const compressor: Compressor = try .init(.{});
    defer compressor.deinit();
    var small: [16]u8 = undefined;
    try std.testing.expectError(error.NoSpace, compressor.compress(&small, data));
    try std.testing.expectError(error.NoSpace, compressor.compressChunk(&small, data, false));
}

test "Compressor.compressChunk" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 200_000);
    defer allocator.free(data);
    var prng: std.Random.DefaultPrng = .init(2);
    for (data, 0..) |*byte, i| byte.* = if ((i / 700) % 3 == 0) prng.random().int(u8) else @intCast(i / 700 % 251);
    const out = try allocator.alloc(u8, 2 * data.len + 4096);
    defer allocator.free(out);

    // From 1 byte, which libdeflate stores, up; varying each chunk's length moves where its last
    // block ends in its last byte, which the next chunk must follow.
    for (0..maxLevel + 1) |level| {
        const compressor: Compressor = try .init(.{ .level = @intCast(level) });
        defer compressor.deinit();
        for ([_]usize{ 1, 7, 55, 1000, 65536, 70001 }) |size| {
            for ([_]usize{ 0, 1, 5 }) |jitter| {
                const length = @min(data.len, size * 12 + jitter * 977);
                @memcpy(out[0..2], &zlibHeader);
                var end: usize = 2;
                var adler: u32 = 1;
                var at: usize = 0;
                var turn: usize = 0;
                while (at < length) : (turn += 1) {
                    const chunk = data[at..][0..@min(size + turn % 4 * jitter, length - at)];
                    at += chunk.len;
                    adler = adler32(adler, chunk);
                    try std.testing.expect(compressor.chunkBound(chunk.len) <= out.len - end);
                    end += try compressor.compressChunk(out[end..][0..compressor.chunkBound(chunk.len)], chunk, at == length);
                }
                std.mem.writeInt(u32, out[end..][0..4], adler, .big);
                try expectStream(out[0 .. end + 4], data[0..length]);
            }
        }
    }
}

/// Checks that `stream` inflates to `data`, and that nothing follows its end.
fn expectStream(stream: []const u8, data: []const u8) !void {
    const allocator = std.testing.allocator;
    var input: std.Io.Reader = .fixed(stream);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &history);
    const back = try decompress.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u8, data, back);
    try std.testing.expectEqual(0, input.bufferedLen());
}
