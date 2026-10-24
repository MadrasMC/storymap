//! A deflate compressor for PNG's filtered rows that looks for a match only where a pixel
//! starts, and only where those 4 bytes were last seen, as fpng does: much faster than a general
//! compressor, and nearly as good on images that repeat whole pixels. It writes one block with
//! its own Huffman codes, in a zlib stream, or the data stored if that's smaller.
const PixelDeflate = @This();

const std = @import("std");

/// Where each 4-byte value was last seen, by its hash, as its position + 1; 0 for nowhere.
table: []u32,
/// The data as literals and matches (`Token`), between the two passes.
tokens: []Token,

const hashBits = 15;
const window = 32768;
const maxLength = 258;
const minLength = 4;
const maxBits = 15;

/// A literal byte, or a match: its length, 3 to 258, and distance, 1 to 32,768.
const Token = packed struct(u32) {
    /// The byte, or for a match, its distance.
    value: u16,
    /// For a match, its length − 3.
    length: u8 = 0,
    isMatch: bool = false,
    _: u7 = 0,
};

/// A compressor for data of up to `maxBytes` bytes.
pub fn init(allocator: std.mem.Allocator, maxBytes: usize) !PixelDeflate {
    const table = try allocator.alloc(u32, 1 << hashBits);
    errdefer allocator.free(table);
    return .{ .table = table, .tokens = try allocator.alloc(Token, maxBytes) };
}

pub fn deinit(self: PixelDeflate, allocator: std.mem.Allocator) void {
    allocator.free(self.tokens);
    allocator.free(self.table);
}

/// The most a zlib stream of `bytes` bytes takes: stored, 5 bytes for each 65,535, and zlib's
/// 6.
pub fn bound(bytes: usize) usize {
    return bytes + (bytes / 65535 + 1) * 5 + 6;
}

/// Compresses `data`, rows of `rowBytes` bytes each starting with its filter type, as a zlib
/// stream at the start of `out`, which holds `bound(data.len)`, and returns its length.
pub fn compress(self: *PixelDeflate, data: []const u8, rowBytes: usize, out: []u8) usize {
    std.debug.assert(data.len <= self.tokens.len and out.len >= bound(data.len));
    var lengths: Frequencies(286) = .{};
    var distances: Frequencies(30) = .{};
    const tokens = self.match(data, rowBytes, &lengths, &distances);
    lengths.counts[256] = 1;

    var bits: BitWriter = .{ .out = out };
    // CMF: deflate with a 32 KB window; FLG: the fastest level, and a multiple of 31.
    bits.writeBytes(&.{ 0x78, 0x01 });
    const codes: Codes = .of(&lengths, &distances);
    if (codes.bits(&lengths, &distances) < data.len * 8) {
        writeHuffman(&bits, &codes, tokens);
    } else {
        writeStored(&bits, data);
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    bits.writeBytes(&adler);
    return bits.end;
}

/// The first pass: `data` as tokens, counting their symbols.
fn match(self: *PixelDeflate, data: []const u8, rowBytes: usize, lengths: *Frequencies(286), distances: *Frequencies(30)) []const Token {
    @memset(self.table, 0);
    var count: usize = 0;
    var position: usize = 0;
    var rowStart: usize = 0;
    while (position < data.len) {
        while (position >= rowStart + rowBytes) rowStart += rowBytes;
        const column = position - rowStart;
        // A pixel starts after the filter type, every 4 bytes.
        if (column == 0 or (column - 1) % 4 != 0 or position + minLength > data.len) {
            self.tokens[count] = .{ .value = data[position] };
            lengths.counts[data[position]] += 1;
            count += 1;
            position += 1;
            continue;
        }
        const value = std.mem.readInt(u32, data[position..][0..4], .little);
        const slot = &self.table[hash(value)];
        const seen = slot.*;
        slot.* = @intCast(position + 1);
        if (seen != 0 and position + 1 - seen <= window and std.mem.readInt(u32, data[seen - 1 ..][0..4], .little) == value) {
            const from = seen - 1;
            const length = matchLength(data, from, position);
            const distance = position - from;
            self.tokens[count] = .{ .value = @intCast(distance), .length = @intCast(length - 3), .isMatch = true };
            lengths.counts[257 + lengthCode(length)] += 1;
            distances.counts[distanceCode(distance)] += 1;
            count += 1;
            position += length;
            continue;
        }
        self.tokens[count] = .{ .value = data[position] };
        lengths.counts[data[position]] += 1;
        count += 1;
        position += 1;
    }
    return self.tokens[0..count];
}

fn hash(value: u32) u32 {
    return (value *% 2654435761) >> (32 - hashBits);
}

/// How long the bytes at `from` and `position` stay the same, from the 4 known, up to 258.
fn matchLength(data: []const u8, from: usize, position: usize) usize {
    const most = @min(maxLength, data.len - position);
    var length: usize = minLength;
    while (length + 8 <= most) {
        const a = std.mem.readInt(u64, data[from + length ..][0..8], .little);
        const b = std.mem.readInt(u64, data[position + length ..][0..8], .little);
        if (a != b) return length + @ctz(a ^ b) / 8;
        length += 8;
    }
    while (length < most and data[from + length] == data[position + length]) length += 1;
    return length;
}

/// The first length of each length code, 257 to 285, and their extra bits.
const lengthBase = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const lengthExtra = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
/// Each length's code, from 257.
const lengthCodes: [maxLength + 1]u8 = codes: {
    var out: [maxLength + 1]u8 = undefined;
    for (0..lengthBase.len) |code| {
        const end = if (code + 1 < lengthBase.len) lengthBase[code + 1] else maxLength + 1;
        for (lengthBase[code]..end) |length| out[length] = code;
    }
    break :codes out;
};

fn lengthCode(length: usize) usize {
    return lengthCodes[length];
}

/// A distance's code, 0 to 29: 0 to 3 alone, then two for each power of two.
fn distanceCode(distance: usize) u8 {
    const d: u32 = @intCast(distance - 1);
    if (d < 4) return @intCast(d);
    const top: u5 = @intCast(31 - @clz(d));
    return @intCast(2 * @as(u32, top) + ((d >> (top - 1)) & 1));
}

/// How many extra bits follow distance code `code`, and the first distance it covers.
fn distanceExtra(code: u8) u4 {
    return if (code < 4) 0 else @intCast(code / 2 - 1);
}

fn distanceBase(code: u8) u32 {
    if (code < 4) return code + 1;
    const extra = distanceExtra(code);
    return (@as(u32, 2 + (code & 1)) << extra) + 1;
}

fn Frequencies(comptime symbols: usize) type {
    return struct { counts: [symbols]u32 = @splat(0) };
}

/// A Huffman code's lengths, and the codes themselves, bit-reversed for writing.
fn Code(comptime symbols: usize) type {
    return struct {
        const Self = @This();
        lengths: [symbols]u4 = @splat(0),
        codes: [symbols]u16 = @splat(0),

        /// The best code of up to `limit` bits for `counts`, as miniz builds it: lengths by
        /// Moffat and Katajainen's method, then the longest shortened.
        fn of(counts: []const u32, limit: u4) Self {
            var self: Self = .{};
            var sorted: [symbols]Symbol = undefined;
            var used: usize = 0;
            for (counts, 0..) |count, symbol| {
                if (count == 0) continue;
                sorted[used] = .{ .key = count, .symbol = @intCast(symbol) };
                used += 1;
            }
            // Two codes at least, so each code is complete: distances with no matches need one,
            // and zlib refuses a code-length code with only one.
            for (0..symbols) |symbol| {
                if (used >= 2) break;
                if (counts[symbol] != 0) continue;
                sorted[used] = .{ .key = 1, .symbol = @intCast(symbol) };
                used += 1;
            }
            const list = sorted[0..used];
            std.mem.sort(Symbol, list, {}, Symbol.lessThan);
            minimumRedundancy(list);
            var perLength: [64]u32 = @splat(0);
            for (list) |entry| perLength[entry.key] += 1;
            limitLengths(&perLength, used, limit);
            // The most frequent symbols, at the end, take the shortest lengths.
            var next = used;
            for (1..@as(usize, limit) + 1) |length| {
                for (0..perLength[length]) |_| {
                    next -= 1;
                    self.lengths[list[next].symbol] = @intCast(length);
                }
            }
            self.assign();
            return self;
        }

        /// The canonical codes for the lengths.
        fn assign(self: *Self) void {
            var perLength: [16]u16 = @splat(0);
            for (self.lengths) |length| perLength[length] += 1;
            perLength[0] = 0;
            var next: [16]u16 = undefined;
            var code: u16 = 0;
            for (1..16) |length| {
                code = (code + perLength[length - 1]) << 1;
                next[length] = code;
            }
            for (self.lengths, &self.codes) |length, *out| {
                if (length == 0) continue;
                out.* = @bitReverse(next[length]) >> @intCast(16 - @as(u5, length));
                next[length] += 1;
            }
        }
    };
}

const Symbol = struct {
    key: u32,
    symbol: u16,

    fn lessThan(_: void, a: Symbol, b: Symbol) bool {
        return a.key < b.key;
    }
};

/// Replaces each key, a count, in `list`, sorted by count, with its code's length (miniz
/// `tdefl_calculate_minimum_redundancy`).
fn minimumRedundancy(list: []Symbol) void {
    const n = list.len;
    if (n == 1) {
        list[0].key = 1;
        return;
    }
    list[0].key += list[1].key;
    var root: usize = 0;
    var leaf: usize = 2;
    for (1..n - 1) |next| {
        if (leaf >= n or list[root].key < list[leaf].key) {
            list[next].key = list[root].key;
            list[root].key = @intCast(next);
            root += 1;
        } else {
            list[next].key = list[leaf].key;
            leaf += 1;
        }
        if (leaf >= n or (root < next and list[root].key < list[leaf].key)) {
            list[next].key += list[root].key;
            list[root].key = @intCast(next);
            root += 1;
        } else {
            list[next].key += list[leaf].key;
            leaf += 1;
        }
    }
    list[n - 2].key = 0;
    var next: usize = n - 2;
    while (next > 0) {
        next -= 1;
        list[next].key = list[list[next].key].key + 1;
    }
    var available: usize = 1;
    var used: usize = 0;
    var depth: u32 = 0;
    var rootAt: isize = @intCast(n - 2);
    var nextAt: usize = n - 1;
    while (available > 0) {
        while (rootAt >= 0 and list[@intCast(rootAt)].key == depth) {
            used += 1;
            rootAt -= 1;
        }
        while (available > used) {
            list[nextAt].key = depth;
            if (nextAt > 0) nextAt -= 1;
            available -= 1;
        }
        available = 2 * used;
        depth += 1;
        used = 0;
    }
}

/// Shortens codes longer than `limit`, keeping the code complete (miniz
/// `tdefl_huffman_enforce_max_code_size`).
fn limitLengths(perLength: *[64]u32, used: usize, limit: u4) void {
    if (used <= 1) return;
    for (@as(usize, limit) + 1..64) |length| {
        perLength[limit] += perLength[length];
        perLength[length] = 0;
    }
    var total: u64 = 0;
    for (1..@as(usize, limit) + 1) |length| total += @as(u64, perLength[length]) << @intCast(limit - length);
    while (total != @as(u64, 1) << limit) {
        perLength[limit] -= 1;
        var length: usize = limit - 1;
        while (length > 0) : (length -= 1) {
            if (perLength[length] != 0) {
                perLength[length] -= 1;
                perLength[length + 1] += 2;
                break;
            }
        }
        total -= 1;
    }
}

/// The block's codes, and how its code lengths are written.
const Codes = struct {
    lengths: Code(286),
    distances: Code(30),
    /// The code lengths of both, run-length coded (`CodeLengths`), and their own code.
    runs: CodeLengths,
    header: Code(19),

    fn of(lengths: *const Frequencies(286), distances: *const Frequencies(30)) Codes {
        var self: Codes = .{
            .lengths = .of(&lengths.counts, maxBits),
            .distances = .of(&distances.counts, maxBits),
            .runs = undefined,
            .header = undefined,
        };
        self.runs = .of(&self.lengths.lengths, &self.distances.lengths);
        self.header = .of(&self.runs.counts, 7);
        return self;
    }

    /// The block's size in bits, as `writeHuffman` writes it.
    fn bits(self: *const Codes, lengths: *const Frequencies(286), distances: *const Frequencies(30)) usize {
        var total: usize = 3 + 5 + 5 + 4 + 3 * @as(usize, self.headerCount());
        for (self.runs.items[0..self.runs.count]) |run| total += @as(usize, self.header.lengths[run.symbol]) + extraBits(run.symbol);
        for (lengths.counts, self.lengths.lengths, 0..) |count, length, symbol| {
            total += count * (@as(usize, length) + if (symbol > 256) lengthExtra[symbol - 257] else 0);
        }
        for (distances.counts, self.distances.lengths, 0..) |count, length, code| total += count * (@as(usize, length) + distanceExtra(@intCast(code)));
        return total;
    }

    /// How many code-length codes are written, in `headerOrder`: at least 4.
    fn headerCount(self: *const Codes) u8 {
        var count: u8 = 19;
        while (count > 4 and self.header.lengths[headerOrder[count - 1]] == 0) count -= 1;
        return count;
    }
};

/// The order the code-length code's lengths are written in.
const headerOrder = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

fn extraBits(symbol: u8) u3 {
    return switch (symbol) {
        16 => 2,
        17 => 3,
        18 => 7,
        else => 0,
    };
}

/// The two codes' lengths, the literal and length code's up to its last used, at least 257,
/// then the distance code's, at least 1, as code-length symbols: 0 to 15 a length, 16 the last
/// length again 3 to 6 times, 17 a run of 3 to 10 zeros and 18 of 11 to 138.
const CodeLengths = struct {
    items: [286 + 30]Run = undefined,
    count: usize = 0,
    counts: [19]u32 = @splat(0),
    literals: u16,
    distances: u16,

    const Run = struct { symbol: u8, extra: u8 = 0 };

    fn of(lengths: *const [286]u4, distances: *const [30]u4) CodeLengths {
        var literals: u16 = 286;
        while (literals > 257 and lengths[literals - 1] == 0) literals -= 1;
        var distanceCount: u16 = 30;
        while (distanceCount > 1 and distances[distanceCount - 1] == 0) distanceCount -= 1;
        var all: [286 + 30]u4 = undefined;
        @memcpy(all[0..literals], lengths[0..literals]);
        @memcpy(all[literals..][0..distanceCount], distances[0..distanceCount]);
        var self: CodeLengths = .{ .literals = literals, .distances = distanceCount };
        const values = all[0 .. literals + distanceCount];
        var i: usize = 0;
        while (i < values.len) {
            const value = values[i];
            var run: usize = 1;
            while (i + run < values.len and values[i + run] == value) run += 1;
            i += run;
            if (value == 0) {
                while (run >= 11) {
                    const taken = @min(run, 138);
                    self.add(.{ .symbol = 18, .extra = @intCast(taken - 11) });
                    run -= taken;
                }
                if (run >= 3) {
                    self.add(.{ .symbol = 17, .extra = @intCast(run - 3) });
                    run = 0;
                }
            } else {
                self.add(.{ .symbol = value });
                run -= 1;
                while (run >= 3) {
                    const taken = @min(run, 6);
                    self.add(.{ .symbol = 16, .extra = @intCast(taken - 3) });
                    run -= taken;
                }
            }
            for (0..run) |_| self.add(.{ .symbol = value });
        }
        return self;
    }

    fn add(self: *CodeLengths, run: Run) void {
        self.items[self.count] = run;
        self.count += 1;
        self.counts[run.symbol] += 1;
    }
};

fn writeHuffman(bits: *BitWriter, codes: *const Codes, tokens: []const Token) void {
    // The last block, with its own codes.
    bits.write(1, 1);
    bits.write(2, 2);
    bits.write(codes.runs.literals - 257, 5);
    bits.write(codes.runs.distances - 1, 5);
    const headerCount = codes.headerCount();
    bits.write(headerCount - 4, 4);
    for (headerOrder[0..headerCount]) |symbol| bits.write(codes.header.lengths[symbol], 3);
    for (codes.runs.items[0..codes.runs.count]) |run| {
        bits.write(codes.header.codes[run.symbol], codes.header.lengths[run.symbol]);
        bits.write(run.extra, extraBits(run.symbol));
    }
    const lengths = &codes.lengths;
    const distances = &codes.distances;
    for (tokens) |token| {
        if (!token.isMatch) {
            bits.write(lengths.codes[token.value], lengths.lengths[token.value]);
            continue;
        }
        const length = @as(usize, token.length) + 3;
        const code = lengthCode(length);
        bits.write(lengths.codes[257 + code], lengths.lengths[257 + code]);
        bits.write(@intCast(length - lengthBase[code]), lengthExtra[code]);
        const distanceSymbol = distanceCode(token.value);
        bits.write(distances.codes[distanceSymbol], distances.lengths[distanceSymbol]);
        bits.write(@intCast(token.value - distanceBase(distanceSymbol)), distanceExtra(distanceSymbol));
    }
    bits.write(lengths.codes[256], lengths.lengths[256]);
    bits.flush();
}

fn writeStored(bits: *BitWriter, data: []const u8) void {
    var start: usize = 0;
    while (true) {
        const length = @min(data.len - start, 65535);
        const last = start + length == data.len;
        bits.write(@intFromBool(last), 1);
        bits.write(0, 2);
        bits.flush();
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], @intCast(length), .little);
        std.mem.writeInt(u16, header[2..4], ~@as(u16, @intCast(length)), .little);
        bits.writeBytes(&header);
        bits.writeBytes(data[start..][0..length]);
        start += length;
        if (last) break;
    }
}

/// Deflate's bits, the first in each byte's lowest bit.
const BitWriter = struct {
    out: []u8,
    end: usize = 0,
    buffer: u64 = 0,
    count: u6 = 0,

    fn write(self: *BitWriter, value: u32, bits: u5) void {
        self.buffer |= @as(u64, value) << self.count;
        self.count += bits;
        if (self.count >= 32) {
            std.mem.writeInt(u32, self.out[self.end..][0..4], @truncate(self.buffer), .little);
            self.end += 4;
            self.buffer >>= 32;
            self.count -= 32;
        }
    }

    /// Writes the bits left over, padding the last byte with zeros.
    fn flush(self: *BitWriter) void {
        while (self.count > 0) {
            self.out[self.end] = @truncate(self.buffer);
            self.end += 1;
            self.buffer >>= 8;
            self.count -|= 8;
        }
        self.buffer = 0;
    }

    fn writeBytes(self: *BitWriter, bytes: []const u8) void {
        std.debug.assert(self.count == 0);
        @memcpy(self.out[self.end..][0..bytes.len], bytes);
        self.end += bytes.len;
    }
};

/// Compresses `data` and decompresses it again with std's inflate.
fn roundTrip(data: []const u8, rowBytes: usize) !usize {
    var compressor: PixelDeflate = try .init(std.testing.allocator, data.len);
    defer compressor.deinit(std.testing.allocator);
    const out = try std.testing.allocator.alloc(u8, bound(data.len));
    defer std.testing.allocator.free(out);
    const length = compressor.compress(data, rowBytes, out);

    var input: std.Io.Reader = .fixed(out[0..length]);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &history);
    const back = try std.testing.allocator.alloc(u8, data.len);
    defer std.testing.allocator.free(back);
    try inflate.reader.readSliceAll(back);
    try std.testing.expectEqualSlices(u8, data, back);
    try std.testing.expectError(error.EndOfStream, inflate.reader.takeByte());
    return length;
}

test compress {
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    const rowBytes = 1 + 64 * 4;
    var data: [rowBytes * 40]u8 = undefined;

    // Repeating pixels, rows like the ones above and noise between, as tiles have.
    for (&data, 0..) |*byte, i| {
        const column = i % rowBytes;
        byte.* = if (column == 0) 2 else if ((i / rowBytes) % 7 == 3) random.int(u8) else @intCast((column / 4 % 9) * 17);
    }
    const repeating = try roundTrip(&data, rowBytes);
    try std.testing.expect(repeating < data.len / 4);

    // Noise is stored, a little larger than it is.
    random.bytes(&data);
    try std.testing.expect(try roundTrip(&data, rowBytes) <= bound(data.len));

    // One byte all over, and a few bytes.
    @memset(&data, 9);
    try std.testing.expect(try roundTrip(&data, rowBytes) < 100);
    _ = try roundTrip(data[0..3], rowBytes);
    _ = try roundTrip(data[0..1], rowBytes);
}

test distanceCode {
    for ([_][2]usize{ .{ 1, 0 }, .{ 4, 3 }, .{ 5, 4 }, .{ 6, 4 }, .{ 7, 5 }, .{ 9, 6 }, .{ 13, 7 }, .{ 24577, 29 }, .{ 32768, 29 } }) |case| {
        const code = distanceCode(case[0]);
        try std.testing.expectEqual(case[1], code);
        try std.testing.expect(case[0] >= distanceBase(code) and case[0] < distanceBase(code) + (@as(u32, 1) << distanceExtra(code)));
    }
}
