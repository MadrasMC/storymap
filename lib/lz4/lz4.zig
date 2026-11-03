//! A decoder for LZ4's block format, and for the stream of blocks that lz4-java's
//! `LZ4BlockOutputStream` writes: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
//!
//! Every read and write is bounds-checked, so corrupt data is an error, not a crash. Checksums
//! aren't compared.
const std = @import("std");

pub const Error = error{
    /// Data that isn't what the format allows.
    InvalidData,
    /// More output than the buffer holds.
    OutputTooLong,
};

/// A block's compressed bytes decoded into `out`, which must be as long as the output can be.
/// Returns how much of it they fill.
pub fn decompressBlock(out: []u8, block: []const u8) Error!usize {
    var at: usize = 0;
    var written: usize = 0;
    while (true) {
        if (at == block.len) return error.InvalidData;
        const token = block[at];
        at += 1;

        const literals = try extendedLength(block, &at, token >> 4);
        if (literals > block.len - at) return error.InvalidData;
        if (literals > out.len - written) return error.OutputTooLong;
        @memcpy(out[written..][0..literals], block[at..][0..literals]);
        at += literals;
        written += literals;
        // The last sequence is only literals.
        if (at == block.len) return written;

        if (block.len - at < 2) return error.InvalidData;
        const offset = std.mem.readInt(u16, block[at..][0..2], .little);
        at += 2;
        if (offset == 0 or offset > written) return error.InvalidData;
        const length = try extendedLength(block, &at, token & 0xF);
        const matched = std.math.add(usize, length, 4) catch return error.InvalidData;
        if (matched > out.len - written) return error.OutputTooLong;
        // A match can overlap what it writes, repeating it, so byte by byte.
        for (0..matched) |i| out[written + i] = out[written + i - offset];
        written += matched;
    }
}

/// A token's 4-bit length, followed by more bytes when it's 15, each adding to it until one is
/// below 255.
fn extendedLength(block: []const u8, at: *usize, start: u8) Error!usize {
    var length: usize = start;
    if (start != 15) return length;
    while (true) {
        if (at.* == block.len) return error.InvalidData;
        const more = block[at.*];
        at.* += 1;
        length = std.math.add(usize, length, more) catch return error.InvalidData;
        if (more != 255) return length;
    }
}

const magic = "LZ4Block";
const headerLength = magic.len + 1 + 3 * 4;
const methodMask = 0xF0;
const methodRaw = 0x10;
const methodLz4 = 0x20;

/// The stream `stream`, as lz4-java writes it, decoded into `out`. Each block has a header: the
/// magic, its method and level, then its compressed length, its length and a checksum as
/// little-endian integers. An empty block ends the stream. Returns how much of `out` it fills.
pub fn decompressStream(out: []u8, stream: []const u8) Error!usize {
    var at: usize = 0;
    var written: usize = 0;
    while (true) {
        if (stream.len - at < headerLength or !std.mem.eql(u8, stream[at..][0..magic.len], magic)) return error.InvalidData;
        const fields = stream[at + magic.len ..][0 .. headerLength - magic.len];
        at += headerLength;
        const method = fields[0] & methodMask;
        const compressed: usize = std.mem.readInt(u32, fields[1..][0..4], .little);
        const length: usize = std.mem.readInt(u32, fields[5..][0..4], .little);
        if (length == 0) {
            if (compressed != 0) return error.InvalidData;
            return written;
        }
        if (compressed > stream.len - at) return error.InvalidData;
        if (length > out.len - written) return error.OutputTooLong;
        const block = stream[at..][0..compressed];
        at += compressed;
        switch (method) {
            methodRaw => {
                if (compressed != length) return error.InvalidData;
                @memcpy(out[written..][0..length], block);
            },
            methodLz4 => if (try decompressBlock(out[written..][0..length], block) != length) return error.InvalidData,
            else => return error.InvalidData,
        }
        written += length;
    }
}

fn expectBlock(expected: []const u8, block: []const u8) !void {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, out[0..try decompressBlock(&out, block)]);
}

test decompressBlock {
    // Literals alone.
    try expectBlock("hello", &([_]u8{0x50} ++ "hello".*));
    // 2 literals, a match of 4 + 2 at offset 2 repeating them, then a last literal.
    try expectBlock("abababab!", &.{ 0x22, 'a', 'b', 2, 0, 0x10, '!' });
    // 15 + 3 literals, in a length that goes on past the token.
    try expectBlock("abcdefghijklmnopqr", &([_]u8{ 0xF0, 3 } ++ "abcdefghijklmnopqr".*));
    // A match of 4 + 15 + 1, overlapping itself from one byte, then nothing left over.
    const repeated: [21]u8 = @splat('x');
    try expectBlock(&repeated, &.{ 0x1F, 'x', 1, 0, 1, 0x00 });
}

test "invalid blocks" {
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidData, decompressBlock(&out, &.{}));
    // Literals past the end, an offset of 0, one before the start, and one cut short.
    try std.testing.expectError(error.InvalidData, decompressBlock(&out, &.{ 0x50, 'a' }));
    try std.testing.expectError(error.InvalidData, decompressBlock(&out, &.{ 0x10, 'a', 0, 0, 0x00 }));
    try std.testing.expectError(error.InvalidData, decompressBlock(&out, &.{ 0x10, 'a', 2, 0, 0x00 }));
    try std.testing.expectError(error.InvalidData, decompressBlock(&out, &.{ 0x10, 'a', 1 }));
    try std.testing.expectError(error.InvalidData, decompressBlock(&out, &.{ 0xF0, 255 }));
    // Too long for the output, as literals and as a match.
    try std.testing.expectError(error.OutputTooLong, decompressBlock(out[0..2], &([_]u8{0x30} ++ "abc".*)));
    try std.testing.expectError(error.OutputTooLong, decompressBlock(out[0..3], &.{ 0x10, 'a', 1, 0, 0x00 }));
}

/// A stream header for a block.
fn header(method: u8, compressed: u32, length: u32) [headerLength]u8 {
    var out: [headerLength]u8 = undefined;
    @memcpy(out[0..magic.len], magic);
    out[magic.len] = method;
    std.mem.writeInt(u32, out[magic.len + 1 ..][0..4], compressed, .little);
    std.mem.writeInt(u32, out[magic.len + 5 ..][0..4], length, .little);
    std.mem.writeInt(u32, out[magic.len + 9 ..][0..4], 0, .little);
    return out;
}

test decompressStream {
    var out: [32]u8 = undefined;
    const end = header(methodRaw, 0, 0);
    // A raw block, and a compressed one with the level in the method's low bits, then the end.
    const stream = header(methodRaw | 1, 3, 3) ++ "raw".* ++
        header(methodLz4 | 2, 7, 9) ++ [_]u8{ 0x22, 'a', 'b', 2, 0, 0x10, '!' } ++
        end;
    try std.testing.expectEqualStrings("rawabababab!", out[0..try decompressStream(&out, &stream)]);

    // Cut short, without its end, or with another magic.
    try std.testing.expectError(error.InvalidData, decompressStream(&out, stream[0 .. stream.len - 1]));
    try std.testing.expectError(error.InvalidData, decompressStream(&out, stream[0 .. headerLength + 3]));
    try std.testing.expectError(error.InvalidData, decompressStream(&out, "not a stream of blocks"));
    // A method that doesn't exist, a raw block of the wrong length, and a compressed block that
    // comes out shorter than it says.
    try std.testing.expectError(error.InvalidData, decompressStream(&out, &(header(0x30, 1, 1) ++ "x".* ++ end)));
    try std.testing.expectError(error.InvalidData, decompressStream(&out, &(header(methodRaw, 1, 2) ++ "x".* ++ end)));
    try std.testing.expectError(error.InvalidData, decompressStream(&out, &(header(methodLz4, 2, 2) ++ [_]u8{ 0x10, 'x' } ++ end)));
    try std.testing.expectError(error.OutputTooLong, decompressStream(out[0..2], &stream));
}
