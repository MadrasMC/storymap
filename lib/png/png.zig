//! A PNG encoder for 8-bit RGBA images that allocates nothing while encoding: an `Encoder` sets
//! up its buffers once, for the largest image it will take.
const std = @import("std");
const flate = std.compress.flate;

pub const Options = struct {
    /// Deflate's trade between speed and size.
    level: flate.Compress.Options = .level_4,
};

pub const Encoder = struct {
    width: u32,
    height: u32,
    options: Options,
    /// The PNG being written: big enough for `width` × `height` pixels stored uncompressed.
    out: []u8,
    /// Deflate's history.
    window: []u8,
    /// Each filter's output for the row being filtered, with its filter type first.
    rows: [5][]u8,
    /// The image `filter` last filtered, row by row, each with its filter type first, and its
    /// size in pixels.
    filtered: []u8,
    filteredWidth: u32 = 0,
    filteredHeight: u32 = 0,
    deflate: *flate.Compress,

    /// An encoder for images of up to `width` × `height` pixels.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, options: Options) !Encoder {
        const rowBytes = 1 + @as(usize, width) * 4;
        const raw = rowBytes * height;
        // Deflate's stored blocks add 5 bytes per 65,535; the PNG and zlib wrapping, 57 more.
        const out = try allocator.alloc(u8, raw + (raw / 65535 + 1) * 5 + 64);
        errdefer allocator.free(out);
        const window = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(window);
        const rows = try allocator.alloc(u8, 5 * rowBytes);
        errdefer allocator.free(rows);
        const filtered = try allocator.alloc(u8, raw);
        errdefer allocator.free(filtered);
        const deflate = try allocator.create(flate.Compress);
        var encoder: Encoder = .{ .width = width, .height = height, .options = options, .out = out, .window = window, .rows = undefined, .filtered = filtered, .deflate = deflate };
        for (&encoder.rows, 0..) |*row, i| row.* = rows[i * rowBytes ..][0..rowBytes];
        return encoder;
    }

    pub fn deinit(self: Encoder, allocator: std.mem.Allocator) void {
        allocator.destroy(self.deflate);
        allocator.free(self.filtered);
        allocator.free(self.rows[0].ptr[0 .. 5 * self.rows[0].len]);
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
        var previous: []const u8 = &.{};
        for (0..height) |y| {
            const row = pixels[y * rowBytes ..][0..rowBytes];
            @memcpy(self.filtered[y * (1 + rowBytes) ..][0 .. 1 + rowBytes], self.filterRow(row, previous));
            previous = row;
        }
        self.filteredWidth = width;
        self.filteredHeight = height;
    }

    /// The PNG of the image `filter` last filtered. Valid until the next `encode` or `compress`.
    pub fn compress(self: *Encoder) ![]const u8 {
        const width = self.filteredWidth;
        const height = self.filteredHeight;
        const signature = "\x89PNG\r\n\x1a\n";
        @memcpy(self.out[0..8], signature);
        var header: [13]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], width, .big);
        std.mem.writeInt(u32, header[4..8], height, .big);
        // 8 bits per channel, RGBA, deflate, adaptive filtering, no interlacing.
        header[8..13].* = .{ 8, 6, 0, 0, 0 };
        var end = 8 + writeChunk(self.out[8..], "IHDR", &header);

        // The image data's length and type are filled in once it's compressed.
        const data = end + 8;
        var output: std.Io.Writer = .fixed(self.out[data .. self.out.len - 12 - 4]);
        self.deflate.* = try .init(&output, self.window, .zlib, self.options.level);
        try self.deflate.writer.writeAll(self.filtered[0 .. height * (1 + @as(usize, width) * 4)]);
        try self.deflate.finish();
        const length = output.end;
        std.mem.writeInt(u32, self.out[end..][0..4], @intCast(length), .big);
        @memcpy(self.out[end + 4 ..][0..4], "IDAT");
        std.mem.writeInt(u32, self.out[data + length ..][0..4], std.hash.Crc32.hash(self.out[end + 4 .. data + length]), .big);
        end = data + length + 4;
        end += writeChunk(self.out[end..], "IEND", "");
        return self.out[0..end];
    }

    /// `row` filtered as each PNG filter does it, and the one whose bytes, as signed numbers, add
    /// up to the least: the usual guess at which compresses best. `previous` is the row above,
    /// empty for the first.
    fn filterRow(self: *Encoder, row: []const u8, previous: []const u8) []const u8 {
        var best: usize = 0;
        var bestSum: usize = std.math.maxInt(usize);
        for (&self.rows, 0..) |out, kind| {
            out[0] = @intCast(kind);
            var sum: usize = 0;
            for (row, 0..) |x, i| {
                const a: u8 = if (i >= 4) row[i - 4] else 0;
                const b: u8 = if (previous.len > 0) previous[i] else 0;
                const c: u8 = if (i >= 4 and previous.len > 0) previous[i - 4] else 0;
                const predicted: u8 = switch (kind) {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => @intCast((@as(u16, a) + b) / 2),
                    else => paeth(a, b, c),
                };
                const filtered = x -% predicted;
                out[1 + i] = filtered;
                sum += @abs(@as(i8, @bitCast(filtered)));
            }
            if (sum < bestSum) {
                best = kind;
                bestSum = sum;
            }
        }
        return self.rows[best][0 .. 1 + row.len];
    }
};

/// Of `a` (left), `b` (above) and `c` (above left), the one closest to a + b - c.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}

/// Writes a chunk of `kind` holding `data` at the start of `out`, and returns its length.
fn writeChunk(out: []u8, comptime kind: *const [4]u8, data: []const u8) usize {
    std.mem.writeInt(u32, out[0..4], @intCast(data.len), .big);
    @memcpy(out[4..8], kind);
    @memcpy(out[8..][0..data.len], data);
    std.mem.writeInt(u32, out[8 + data.len ..][0..4], std.hash.Crc32.hash(out[4 .. 8 + data.len]), .big);
    return 12 + data.len;
}

test Encoder {
    var encoder: Encoder = try .init(std.testing.allocator, 4, 3, .{});
    defer encoder.deinit(std.testing.allocator);
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @intCast(i * 7 % 256);
    const png = try encoder.encode(&pixels, 4, 3);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqualStrings("IHDR", png[12..16]);
    try std.testing.expectEqualStrings("IEND", png[png.len - 8 .. png.len - 4]);

    // The image data decompresses to the filtered rows, which unfilter to the pixels.
    const length = std.mem.readInt(u32, png[33..37], .big);
    var input: std.Io.Reader = .fixed(png[41..][0..length]);
    var buffer: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &buffer);
    var rows: [3 * (1 + 4 * 4)]u8 = undefined;
    try decompress.reader.readSliceAll(&rows);
    var previous: [16]u8 = @splat(0);
    for (0..3) |y| {
        const row = rows[y * 17 ..][0..17];
        var line: [16]u8 = undefined;
        for (0..16) |i| {
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
        try std.testing.expectEqualSlices(u8, pixels[y * 16 ..][0..16], &line);
        previous = line;
    }
}
