//! Deflate compression into zlib streams, with libdeflate. A `Compressor` is set up once, for one
//! level, and allocates nothing while compressing.
const std = @import("std");
const c = @import("header");

/// The highest level: 0 stores the data uncompressed, 1 is the fastest that compresses, and 10
/// to 12 search for the smallest output, slowly.
pub const maxLevel = 12;

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
}
