//! A PNG encoder for 8-bit RGBA images that allocates nothing while encoding: an `Encoder` sets
//! up its buffers once, for the largest image it will take.
const std = @import("std");
const flate = std.compress.flate;
const Writer = std.Io.Writer;
const PixelDeflate = @import("PixelDeflate.zig");

pub const Options = struct {
    compressor: Compressor = .flate,
    /// For `flate`, deflate's trade between speed and size.
    level: flate.Compress.Options = .level_4,
    /// For `pixels`, where it looks for matches.
    pixels: PixelDeflate.Options = .{},
};

/// How the filtered rows are compressed.
pub const Compressor = enum {
    /// `std.compress.flate`, at `Options.level`.
    flate,
    /// Matches only where a pixel starts, one guess each, as fpng does (`PixelDeflate`).
    pixels,
};

pub const Encoder = struct {
    width: u32,
    height: u32,
    options: Options,
    /// The PNG being written: big enough for `width` × `height` pixels stored uncompressed.
    out: []u8,
    /// Deflate's history.
    window: []u8,
    /// The row being filtered and the one above it, each after 4 zero bytes, the pixel left of
    /// its first: `filter` reads a pixel's neighbours from them without checking for edges.
    padded: [2][]u8,
    /// The image `filter` last filtered, row by row, each with its filter type first, and its
    /// size in pixels.
    filtered: []u8,
    filteredWidth: u32 = 0,
    filteredHeight: u32 = 0,
    deflate: *flate.Compress,
    /// For the `pixels` compressor.
    pixelDeflate: ?PixelDeflate,

    /// An encoder for images of up to `width` × `height` pixels.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, options: Options) !Encoder {
        const rowBytes = 1 + @as(usize, width) * 4;
        const raw = rowBytes * height;
        // Deflate's stored blocks add 5 bytes per 65,535; the PNG and zlib wrapping, 57 more.
        const out = try allocator.alloc(u8, raw + (raw / 65535 + 1) * 5 + 64);
        errdefer allocator.free(out);
        const window = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(window);
        // The two padded rows, one allocation.
        const paddedBytes = 4 + @as(usize, width) * 4;
        const padded = try allocator.alloc(u8, 2 * paddedBytes);
        errdefer allocator.free(padded);
        const filtered = try allocator.alloc(u8, raw);
        errdefer allocator.free(filtered);
        const deflate = try allocator.create(flate.Compress);
        errdefer allocator.destroy(deflate);
        const pixelDeflate: ?PixelDeflate = if (options.compressor == .pixels) try .init(allocator, raw, options.pixels) else null;
        return .{
            .width = width,
            .height = height,
            .options = options,
            .out = out,
            .window = window,
            .padded = .{ padded[0..paddedBytes], padded[paddedBytes..] },
            .filtered = filtered,
            .deflate = deflate,
            .pixelDeflate = pixelDeflate,
        };
    }

    pub fn deinit(self: Encoder, allocator: std.mem.Allocator) void {
        if (self.pixelDeflate) |compressor| compressor.deinit(allocator);
        allocator.destroy(self.deflate);
        allocator.free(self.filtered);
        allocator.free(self.padded[0].ptr[0 .. 2 * self.padded[0].len]);
        allocator.free(self.window);
        allocator.free(self.out);
    }

    /// The PNG of `pixels`, `width` × `height` of them row by row, each red, green, blue and
    /// alpha bytes. Valid until the next `encode` or `compress`. It's `filter`, then `compress`,
    /// for timing the two apart.
    pub fn encode(self: *Encoder, pixels: []const u8, width: u32, height: u32) ![]const u8 {
        self.filter(pixels, width, height);
        return self.compress();
    }

    /// Filters each row of `pixels`, as `encode` takes them, for `compress`.
    pub fn filter(self: *Encoder, pixels: []const u8, width: u32, height: u32) void {
        std.debug.assert(width <= self.width and height <= self.height and pixels.len == @as(usize, width) * height * 4);
        const rowBytes = @as(usize, width) * 4;
        var row = self.padded[0][0 .. 4 + rowBytes];
        var above = self.padded[1][0 .. 4 + rowBytes];
        // The row above the first is all zero, and so is the pixel left of every row.
        @memset(above, 0);
        @memset(row[0..4], 0);
        for (0..height) |y| {
            @memcpy(row[4..], pixels[y * rowBytes ..][0..rowBytes]);
            filterRow(row, above, self.filtered[y * (1 + rowBytes) ..][0 .. 1 + rowBytes]);
            std.mem.swap([]u8, &row, &above);
        }
        self.filteredWidth = width;
        self.filteredHeight = height;
    }

    /// The PNG of the image `filter` last filtered. Valid until the next `encode` or `compress`.
    pub fn compress(self: *Encoder) ![]const u8 {
        const width = self.filteredWidth;
        const height = self.filteredHeight;
        var end = writeHeader(self.out[0..headerBytes], width, height);

        // The image data's length and type are filled in once it's compressed.
        const data = end + 8;
        const rowBytes = 1 + @as(usize, width) * 4;
        const filtered = self.filtered[0 .. height * rowBytes];
        const length = switch (self.options.compressor) {
            .flate => length: {
                var output: std.Io.Writer = .fixed(self.out[data .. self.out.len - 12 - 4]);
                self.deflate.* = try .init(&output, self.window, .zlib, self.options.level);
                try self.deflate.writer.writeAll(filtered);
                try self.deflate.finish();
                break :length output.end;
            },
            .pixels => self.pixelDeflate.?.compress(filtered, rowBytes, self.out[data .. self.out.len - 12 - 4]),
        };
        std.mem.writeInt(u32, self.out[end..][0..4], @intCast(length), .big);
        @memcpy(self.out[end + 4 ..][0..4], "IDAT");
        std.mem.writeInt(u32, self.out[data + length ..][0..4], std.hash.Crc32.hash(self.out[end + 4 .. data + length]), .big);
        end = data + length + 4;
        end += writeChunk(self.out[end..], "IEND", "");
        return self.out[0..end];
    }
};

/// Encodes a PNG into a writer a row at a time, so an image of any height takes no more memory
/// than two of its rows, deflate's history and one chunk of image data. It allocates nothing
/// while encoding, and can encode one image after another. Filtering and `Options.level` are as
/// `Encoder`'s; `Compressor.pixels` takes a whole image, so it isn't offered.
pub const RowEncoder = struct {
    width: u32,
    level: flate.Compress.Options,
    /// The row being filtered and the one above it, as `Encoder.padded`, taking turns in
    /// `paddedRows`.
    padded: [2][]u8,
    paddedRows: []u8,
    /// The row last filtered, with its filter type first.
    filtered: []u8,
    /// Deflate's history.
    window: []u8,
    deflate: *flate.Compress,
    chunks: Chunks,
    rowWidth: u32 = 0,
    rowsLeft: u32 = 0,

    /// How much image data goes in a chunk.
    const chunkBytes = 1 << 16;

    /// A writer that sends what's written to `out` as `IDAT` chunks, one each time it fills.
    const Chunks = struct {
        out: *Writer,
        writer: Writer,

        const vtable: Writer.VTable = .{ .drain = drain };

        fn writeChunkOut(self: *Chunks) Writer.Error!void {
            const data = self.writer.buffered();
            if (data.len == 0) return;
            var prefix: [8]u8 = undefined;
            std.mem.writeInt(u32, prefix[0..4], @intCast(data.len), .big);
            @memcpy(prefix[4..8], "IDAT");
            var crc: std.hash.Crc32 = .init();
            crc.update(prefix[4..8]);
            crc.update(data);
            try self.out.writeAll(&prefix);
            try self.out.writeAll(data);
            try self.out.writeInt(u32, crc.final(), .big);
            self.writer.end = 0;
        }

        /// Sends what's buffered as a chunk, and takes the first of `data` into the buffer.
        fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
            const self: *Chunks = @fieldParentPtr("writer", w);
            try self.writeChunkOut();
            for (data[0 .. data.len - 1]) |bytes| {
                if (bytes.len > 0) return w.write(bytes);
            }
            const pattern = data[data.len - 1];
            return if (splat == 0 or pattern.len == 0) 0 else w.write(pattern);
        }
    };

    /// An encoder for images of up to `width` pixels wide, of any height. It must stay where it
    /// is while encoding.
    pub fn init(allocator: std.mem.Allocator, width: u32, level: flate.Compress.Options) !RowEncoder {
        const paddedBytes = 4 + @as(usize, width) * 4;
        const padded = try allocator.alloc(u8, 2 * paddedBytes);
        errdefer allocator.free(padded);
        const filtered = try allocator.alloc(u8, 1 + @as(usize, width) * 4);
        errdefer allocator.free(filtered);
        const window = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(window);
        const deflate = try allocator.create(flate.Compress);
        errdefer allocator.destroy(deflate);
        const chunk = try allocator.alloc(u8, chunkBytes);
        return .{
            .width = width,
            .level = level,
            .padded = .{ padded[0..paddedBytes], padded[paddedBytes..] },
            .paddedRows = padded,
            .filtered = filtered,
            .window = window,
            .deflate = deflate,
            .chunks = .{ .out = undefined, .writer = .{ .vtable = &Chunks.vtable, .buffer = chunk } },
        };
    }

    pub fn deinit(self: RowEncoder, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks.writer.buffer);
        allocator.destroy(self.deflate);
        allocator.free(self.window);
        allocator.free(self.filtered);
        allocator.free(self.paddedRows);
    }

    /// Starts an image of `width` × `height` pixels in `out`, which `writeRow` and `finish` go on
    /// writing to.
    pub fn begin(self: *RowEncoder, out: *Writer, width: u32, height: u32) Writer.Error!void {
        std.debug.assert(width <= self.width);
        self.rowWidth = width;
        self.rowsLeft = height;
        // The row above the first is all zero, and so is the pixel left of every row.
        @memset(self.padded[0][0..4], 0);
        @memset(self.padded[1][0 .. 4 + @as(usize, width) * 4], 0);
        var header: [headerBytes]u8 = undefined;
        try out.writeAll(header[0..writeHeader(&header, width, height)]);
        self.chunks.out = out;
        self.chunks.writer.end = 0;
        self.deflate.* = try .init(&self.chunks.writer, self.window, .zlib, self.level);
    }

    /// Adds the next row, `width` pixels of red, green, blue and alpha bytes.
    pub fn writeRow(self: *RowEncoder, row: []const u8) Writer.Error!void {
        const rowBytes = @as(usize, self.rowWidth) * 4;
        std.debug.assert(row.len == rowBytes and self.rowsLeft > 0);
        const current = self.padded[0][0 .. 4 + rowBytes];
        const above = self.padded[1][0 .. 4 + rowBytes];
        @memcpy(current[4..], row);
        const filtered = self.filtered[0 .. 1 + rowBytes];
        filterRow(current, above, filtered);
        try self.deflate.writer.writeAll(filtered);
        std.mem.swap([]u8, &self.padded[0], &self.padded[1]);
        @memset(self.padded[0][0..4], 0);
        self.rowsLeft -= 1;
    }

    /// Ends the image, all of whose rows have been added. Flushing `out` is left to the caller.
    pub fn finish(self: *RowEncoder) Writer.Error!void {
        std.debug.assert(self.rowsLeft == 0);
        try self.deflate.finish();
        try self.chunks.writer.flush();
        var end: [12]u8 = undefined;
        _ = writeChunk(&end, "IEND", "");
        try self.chunks.out.writeAll(&end);
    }
};

/// Bytes a filter works on at once.
const lanes = std.simd.suggestVectorLength(u8) orelse 16;
const Bytes = @Vector(lanes, u8);
/// Vectors summed per lane before the sums move to `usize`: each adds at most 128, so 256 of
/// them fit a `u16`.
const vectorsPerSum = 256;

/// Writes `row` into `out` filtered by the PNG filter whose bytes, as signed numbers, add up to
/// the least, the usual guess at which compresses best, after its filter type. `row` and `above`
/// are the row and the one above it, each after 4 zero bytes, the pixel left of its first.
fn filterRow(row: []const u8, above: []const u8, out: []u8) void {
    const length = row.len - 4;
    var sums: [5]usize = @splat(0);
    var i: usize = 0;
    while (i + lanes <= length) {
        var laneSums: [5]@Vector(lanes, u16) = @splat(@splat(0));
        var vectors: usize = 0;
        while (vectors < vectorsPerSum and i + lanes <= length) : ({
            vectors += 1;
            i += lanes;
        }) {
            const filtered = filtersAt(row, above, i);
            inline for (&laneSums, filtered) |*sum, bytes| sum.* += @abs(@as(@Vector(lanes, i8), @bitCast(bytes)));
        }
        for (&sums, laneSums) |*sum, laneSum| sum.* += @reduce(.Add, @as(@Vector(lanes, u32), laneSum));
    }
    for (i..length) |j| {
        inline for (&sums, 0..) |*sum, kind| sum.* += @abs(@as(i8, @bitCast(filterByte(kind, row, above, j))));
    }
    // The first with the least, as ties go to the simpler filter.
    var best: u8 = 0;
    for (sums, 0..) |sum, kind| {
        if (sum < sums[best]) best = @intCast(kind);
    }
    out[0] = best;
    switch (best) {
        inline 0...4 => |kind| writeFiltered(kind, row, above, out[1..]),
        else => unreachable,
    }
}

/// Writes `row` filtered by filter `kind` into `out`.
fn writeFiltered(comptime kind: u8, row: []const u8, above: []const u8, out: []u8) void {
    const length = row.len - 4;
    var i: usize = 0;
    while (i + lanes <= length) : (i += lanes) out[i..][0..lanes].* = filtersAt(row, above, i)[kind];
    for (i..length) |j| out[j] = filterByte(kind, row, above, j);
}

/// The `lanes` bytes from byte `i` of the row as each of the five PNG filters gives them.
fn filtersAt(row: []const u8, above: []const u8, i: usize) [5]Bytes {
    const x: Bytes = row[4 + i ..][0..lanes].*;
    const a: Bytes = row[i..][0..lanes].*;
    const b: Bytes = above[4 + i ..][0..lanes].*;
    const c: Bytes = above[i..][0..lanes].*;
    // The average rounded down, without overflowing a byte.
    const average = (a & b) +% ((a ^ b) >> @splat(1));
    return .{ x, x -% a, x -% b, x -% average, x -% paethVector(a, b, c) };
}

/// `paeth` on each lane.
fn paethVector(a: Bytes, b: Bytes, c: Bytes) Bytes {
    const Wide = @Vector(lanes, i16);
    const wa: Wide = a;
    const wb: Wide = b;
    const wc: Wide = c;
    // The distances from a + b - c to a, b and c.
    const pa = @abs(wb - wc);
    const pb = @abs(wa - wc);
    const pc = @abs(wa + wb - wc - wc);
    const none: @Vector(lanes, bool) = @splat(false);
    const useA = @select(bool, pa <= pb, pa <= pc, none);
    return @select(u8, useA, a, @select(u8, pb <= pc, b, c));
}

/// Byte `i` of the row filtered by filter `kind`.
fn filterByte(comptime kind: u8, row: []const u8, above: []const u8, i: usize) u8 {
    const x = row[4 + i];
    const a = row[i];
    const b = above[4 + i];
    const c = above[i];
    const predicted: u8 = switch (kind) {
        0 => 0,
        1 => a,
        2 => b,
        3 => @intCast((@as(u16, a) + b) / 2),
        else => paeth(a, b, c),
    };
    return x -% predicted;
}

/// Of `a` (left), `b` (above) and `c` (above left), the one closest to a + b - c.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}

/// The bytes of a PNG's signature and `IHDR` chunk.
const headerBytes = 8 + 12 + 13;

/// Writes a PNG's signature and `IHDR` chunk at the start of `out`, and returns their length.
fn writeHeader(out: *[headerBytes]u8, width: u32, height: u32) usize {
    @memcpy(out[0..8], "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    // 8 bits per channel, RGBA, deflate, adaptive filtering, no interlacing.
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    return 8 + writeChunk(out[8..], "IHDR", &header);
}

/// Writes a chunk of `kind` holding `data` at the start of `out`, and returns its length.
fn writeChunk(out: []u8, comptime kind: *const [4]u8, data: []const u8) usize {
    std.mem.writeInt(u32, out[0..4], @intCast(data.len), .big);
    @memcpy(out[4..8], kind);
    @memcpy(out[8..][0..data.len], data);
    std.mem.writeInt(u32, out[8 + data.len ..][0..4], std.hash.Crc32.hash(out[4 .. 8 + data.len]), .big);
    return 12 + data.len;
}

test {
    _ = PixelDeflate;
}

test Encoder {
    for ([_]Compressor{ .flate, .pixels }) |compressor| try expectPng(compressor);
}

/// Encodes a small image, and checks it unfilters back to the pixels.
fn expectPng(compressor: Compressor) !void {
    var encoder: Encoder = try .init(std.testing.allocator, 4, 3, .{ .compressor = compressor });
    defer encoder.deinit(std.testing.allocator);
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @intCast(i * 7 % 256);
    const png = try encoder.encode(&pixels, 4, 3);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqualStrings("IHDR", png[12..16]);
    try std.testing.expectEqualStrings("IEND", png[png.len - 8 .. png.len - 4]);

    try expectPixels(png, &pixels, 4, 3);
}

/// Checks that `png`'s chunks are whole, and that its image data, in as many chunks as it has,
/// decompresses to filtered rows that unfilter to `pixels`.
fn expectPixels(png: []const u8, pixels: []const u8, width: usize, height: usize) !void {
    const allocator = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var at: usize = 8;
    var ended = false;
    while (at < png.len) {
        const length = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        const crc = std.mem.readInt(u32, png[at + 8 + length ..][0..4], .big);
        try std.testing.expectEqual(std.hash.Crc32.hash(png[at + 4 .. at + 8 + length]), crc);
        if (std.mem.eql(u8, kind, "IDAT")) try data.appendSlice(allocator, png[at + 8 ..][0..length]);
        ended = std.mem.eql(u8, kind, "IEND");
        at += 12 + length;
    }
    try std.testing.expect(ended);

    var input: std.Io.Reader = .fixed(data.items);
    var buffer: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &buffer);
    const rowBytes = width * 4;
    const rows = try allocator.alloc(u8, height * (1 + rowBytes));
    defer allocator.free(rows);
    try decompress.reader.readSliceAll(rows);
    const line = try allocator.alloc(u8, rowBytes);
    defer allocator.free(line);
    const previous = try allocator.alloc(u8, rowBytes);
    defer allocator.free(previous);
    @memset(previous, 0);
    for (0..height) |y| {
        const row = rows[y * (1 + rowBytes) ..][0 .. 1 + rowBytes];
        for (0..rowBytes) |i| {
            const a: u8 = if (i >= 4) line[i - 4] else 0;
            const b = previous[i];
            const c: u8 = if (i >= 4) previous[i - 4] else 0;
            const predicted: u8 = switch (row[0]) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                else => paeth(a, b, c),
            };
            line[i] = row[1 + i] +% predicted;
        }
        try std.testing.expectEqualSlices(u8, pixels[y * rowBytes ..][0..rowBytes], line);
        @memcpy(previous, line);
    }
}

test RowEncoder {
    const allocator = std.testing.allocator;
    var encoder: RowEncoder = try .init(allocator, 300, .level_4);
    defer encoder.deinit(allocator);
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();

    // Noise doesn't compress, so this takes many chunks; then a narrower image from the same
    // encoder, which starts afresh.
    for ([_][2]u32{ .{ 300, 200 }, .{ 7, 5 }, .{ 300, 1 } }) |size| {
        const width = size[0];
        const height = size[1];
        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        defer allocator.free(pixels);
        random.bytes(pixels);
        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        try encoder.begin(&out.writer, width, height);
        for (0..height) |y| try encoder.writeRow(pixels[y * width * 4 ..][0 .. width * 4]);
        try encoder.finish();
        const png = out.written();
        try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
        try expectPixels(png, pixels, width, height);
        if (height == 200) try std.testing.expect(std.mem.count(u8, png, "IDAT") >= 3);
    }

    // The same pixels as `Encoder` gives, whatever the rows are split into.
    const width = 16;
    const height = 9;
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @intCast(i * 3 % 251);
    var whole: Encoder = try .init(allocator, width, height, .{ .level = .level_4 });
    defer whole.deinit(allocator);
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    try encoder.begin(&out.writer, width, height);
    for (0..height) |y| try encoder.writeRow(pixels[y * width * 4 ..][0 .. width * 4]);
    try encoder.finish();
    try std.testing.expectEqualSlices(u8, try whole.encode(&pixels, width, height), out.written());
}

test filterRow {
    // Rows wide enough for the vectors and a few bytes over, flat in parts and noisy in others,
    // filtered as each filter is written out byte by byte: the same filter, and the same bytes.
    const width = 2 * lanes + 3;
    const height = 6;
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = if ((i / 64) % 2 == 0) @intCast(i % 7) else random.int(u8);
    var encoder: Encoder = try .init(std.testing.allocator, width, height, .{});
    defer encoder.deinit(std.testing.allocator);
    encoder.filter(&pixels, width, height);

    const rowBytes = width * 4;
    var previous: [rowBytes]u8 = @splat(0);
    for (0..height) |y| {
        const row = pixels[y * rowBytes ..][0..rowBytes];
        var expected: [5][1 + rowBytes]u8 = undefined;
        var sums: [5]usize = @splat(0);
        for (&expected, &sums, 0..) |*out, *sum, kind| {
            out[0] = @intCast(kind);
            for (row, 0..) |x, i| {
                const a: u8 = if (i >= 4) row[i - 4] else 0;
                const b = previous[i];
                const c: u8 = if (i >= 4) previous[i - 4] else 0;
                const predicted: u8 = switch (kind) {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => @intCast((@as(u16, a) + b) / 2),
                    else => paeth(a, b, c),
                };
                out[1 + i] = x -% predicted;
                sum.* += @abs(@as(i8, @bitCast(out[1 + i])));
            }
        }
        const best = std.mem.indexOfMin(usize, &sums);
        try std.testing.expectEqualSlices(u8, &expected[best], encoder.filtered[y * (1 + rowBytes) ..][0 .. 1 + rowBytes]);
        previous = row.*;
    }
}
