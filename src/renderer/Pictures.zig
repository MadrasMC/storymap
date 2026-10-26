//! The isometric view's pictures of a game's blocks, every one drawn once
//! (`isometric.drawPictures`) and kept in a file, `pictures.bin`, beside what the game's reader
//! prepared, which a render maps and reads in place.
//!
//! The file, all in little-endian order, starts with a `Header`, then an `Entry` for each
//! block, by the number the game's reader gives it, then a `Stored` for each picture, then the
//! pictures' pixels: for each, its plain layer, its tinted layer if it has one, and its depths,
//! each row by row, padded to 4 bytes. Everything in it lies at a multiple of its own size, so
//! it's read where it's mapped.
const Pictures = @This();

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // The file is read in place, as the machine's own integers.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const fileName = "pictures.bin";

/// The pictures and the file's layout: raise it when either changes, so files drawn before are
/// drawn again.
pub const version = 1;

entries: []const Entry,
stored: []const Stored,
data: []const u8,

pub const Header = extern struct {
    magic: [8]u8 = magic,
    version: u32 = version,
    entries: u32,
    pictures: u32,
    /// The bytes of pixels after the table of pictures.
    dataLength: u32,
};

const magic = "SMPICTS\x00".*;

/// A block's pictures: `variants` of them from picture number `first`, one for each variant
/// of its textures; none without a picture.
pub const Entry = extern struct {
    first: u32 = 0,
    variants: u16 = 0,
    flags: Flags = .{},

    pub const Flags = packed struct(u16) {
        /// Drawn in its shape, rather than as a cube.
        shape: bool = false,
        /// Its pictures have a tinted layer.
        tinted: bool = false,
        _: u14 = 0,
    };
};

/// Where a picture is in the file, and what it covers.
pub const Stored = extern struct {
    /// From the start of the pixels.
    offset: u32,
    left: i16,
    top: i16,
    width: u16,
    height: u16,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        tinted: bool = false,
        fills: bool = false,
        _: u30 = 0,
    };
};

/// A block drawn in its textures: what it shows of a cube's square, and around it for a shape
/// that reaches out of its block, each pixel with how far into the block its point is.
pub const Picture = struct {
    /// Where its top left pixel is, from the top left of the cube's square.
    left: i16,
    top: i16,
    width: u16,
    height: u16,
    /// Row by row, opaque where the block is, and transparent where it shows nothing.
    plain: []const u32,
    /// Lit but not yet tinted, each pixel's alpha how much of it the layer covers.
    tinted: ?[]const u32,
    /// x + y + z of each pixel's point, the block being from 0 to 1, in 256ths.
    depths: []const i16,
    /// Whether it covers the whole of a cube's square, so nothing behind the block shows.
    fills: bool,

    /// Whether it shows anything at pixel `p`.
    pub fn shows(self: *const Picture, p: usize) bool {
        if (self.plain[p] & 0xff000000 != 0) return true;
        const tinted = self.tinted orelse return false;
        return tinted[p] & 0xff000000 != 0;
    }

    fn bytes(self: Picture) usize {
        const pixels = @as(usize, self.width) * self.height;
        return pixels * 4 + (if (self.tinted != null) pixels * 4 else 0) + std.mem.alignForward(usize, pixels * 2, 4);
    }
};

/// Writes `pictures` and each block's `entries` naming them.
pub fn write(w: *std.Io.Writer, entries: []const Entry, pictures: []const Picture) !void {
    var length: usize = 0;
    for (pictures) |each| length += each.bytes();
    if (length > std.math.maxInt(u32)) return error.TooLarge;
    const header: Header = .{ .entries = @intCast(entries.len), .pictures = @intCast(pictures.len), .dataLength = @intCast(length) };
    try w.writeAll(std.mem.asBytes(&header));
    try w.writeAll(std.mem.sliceAsBytes(entries));
    var offset: u32 = 0;
    for (pictures) |each| {
        const stored: Stored = .{
            .offset = offset,
            .left = each.left,
            .top = each.top,
            .width = each.width,
            .height = each.height,
            .flags = .{ .tinted = each.tinted != null, .fills = each.fills },
        };
        try w.writeAll(std.mem.asBytes(&stored));
        offset += @intCast(each.bytes());
    }
    for (pictures) |each| {
        try w.writeAll(std.mem.sliceAsBytes(each.plain));
        if (each.tinted) |tinted| try w.writeAll(std.mem.sliceAsBytes(tinted));
        try w.writeAll(std.mem.sliceAsBytes(each.depths));
        try w.splatByteAll(0, std.mem.alignForward(usize, each.depths.len * 2, 4) - each.depths.len * 2);
    }
}

/// The pictures in `bytes`, read in place: they must start at a multiple of 4 and outlive the
/// result. error.NotPictures for anything other than a whole file of this version.
pub fn parse(bytes: []align(4) const u8) error{NotPictures}!Pictures {
    if (bytes.len < @sizeOf(Header)) return error.NotPictures;
    const header: *const Header = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, &header.magic, &magic) or header.version != version) return error.NotPictures;
    const entriesEnd = @sizeOf(Header) + @as(usize, header.entries) * @sizeOf(Entry);
    const storedEnd = entriesEnd + @as(usize, header.pictures) * @sizeOf(Stored);
    if (bytes.len != storedEnd + header.dataLength) return error.NotPictures;
    const self: Pictures = .{
        .entries = @alignCast(std.mem.bytesAsSlice(Entry, bytes[@sizeOf(Header)..entriesEnd])),
        .stored = @alignCast(std.mem.bytesAsSlice(Stored, bytes[entriesEnd..storedEnd])),
        .data = bytes[storedEnd..],
    };
    for (self.entries) |block| if (@as(usize, block.first) + block.variants > self.stored.len) return error.NotPictures;
    for (self.stored) |stored| {
        const pixels = @as(usize, stored.width) * stored.height;
        const length = pixels * (if (stored.flags.tinted) @as(usize, 8) else 4) + std.mem.alignForward(usize, pixels * 2, 4);
        if (stored.offset % 4 != 0 or @as(usize, stored.offset) + length > self.data.len) return error.NotPictures;
    }
    return self;
}

/// Block `number`'s pictures; none for a number the file doesn't have.
pub fn entry(self: *const Pictures, number: u32) Entry {
    return if (number < self.entries.len) self.entries[number] else .{};
}

/// Picture `index`, its pixels where the file is.
pub fn picture(self: *const Pictures, index: u32) Picture {
    const stored = self.stored[index];
    const pixels = @as(usize, stored.width) * stored.height;
    var at: usize = stored.offset;
    const plain = self.take(u32, &at, pixels);
    const tinted = if (stored.flags.tinted) self.take(u32, &at, pixels) else null;
    return .{
        .left = stored.left,
        .top = stored.top,
        .width = stored.width,
        .height = stored.height,
        .plain = plain,
        .tinted = tinted,
        .depths = self.take(i16, &at, pixels),
        .fills = stored.flags.fills,
    };
}

fn take(self: *const Pictures, comptime T: type, at: *usize, count: usize) []const T {
    const bytes = self.data[at.*..][0 .. count * @sizeOf(T)];
    at.* += count * @sizeOf(T);
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}

test "write and parse" {
    const allocator = std.testing.allocator;
    // A cube's picture and a plant's, the plant reaching out of its square and tinted.
    const pictures = [_]Picture{
        .{ .left = 0, .top = 0, .width = 2, .height = 1, .plain = &.{ 1, 2 }, .tinted = null, .depths = &.{ 3, 4 }, .fills = true },
        .{ .left = -3, .top = 1, .width = 1, .height = 3, .plain = &.{ 5, 6, 7 }, .tinted = &.{ 8, 9, 10 }, .depths = &.{ -1, 0, 1 }, .fills = false },
    };
    const entries = [_]Entry{ .{ .first = 0, .variants = 1 }, .{}, .{ .first = 1, .variants = 1, .flags = .{ .shape = true, .tinted = true } } };
    var file: std.Io.Writer.Allocating = .init(allocator);
    defer file.deinit();
    try write(&file.writer, &entries, &pictures);
    const bytes = try allocator.alignedAlloc(u8, .@"4", file.written().len);
    defer allocator.free(bytes);
    @memcpy(bytes, file.written());

    const read = try parse(bytes);
    try std.testing.expectEqual(3, read.entries.len);
    try std.testing.expectEqual(0, read.entry(1).variants);
    try std.testing.expectEqual(0, read.entry(7).variants);
    const plant = read.entry(2);
    try std.testing.expect(plant.flags.shape and plant.flags.tinted);
    const drawn = read.picture(plant.first);
    try std.testing.expectEqual(@as(i16, -3), drawn.left);
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 7 }, drawn.plain);
    try std.testing.expectEqualSlices(u32, &.{ 8, 9, 10 }, drawn.tinted.?);
    try std.testing.expectEqualSlices(i16, &.{ -1, 0, 1 }, drawn.depths);
    try std.testing.expect(!drawn.fills);
    try std.testing.expectEqualSlices(i16, &.{ 3, 4 }, read.picture(0).depths);
    try std.testing.expect(read.picture(0).fills);

    // Cut short, or of another version, it isn't pictures.
    try std.testing.expectError(error.NotPictures, parse(bytes[0 .. bytes.len - 4]));
    bytes[8] +%= 1;
    try std.testing.expectError(error.NotPictures, parse(bytes));
}
