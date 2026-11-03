//! The isometric view's sprites of a game's blocks, in every rotation, each drawn when the game's
//! blocks are prepared (`isometric.drawSprites`), in two sections of the prepared blocks file
//! (docs/storyblk/spec.md): `sprites`, a `Sprite` for each, and `sprite_layers`, their pixels,
//! which sprites that look the same share. Everything in them lies at a multiple of its own size,
//! so a render reads them where the file is mapped.
const Sprites = @This();

const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("FileBuffer.zig");

comptime {
    // The sections are read in place, as the machine's own integers.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 8 and @sizeOf(Sprite) == 16);
}

/// How the sprites are drawn: raise it when that changes, so files drawn before are drawn again.
pub const generatorVersion: u16 = 5;
/// The layout of both sections (spec §7).
pub const layoutVersion: u8 = 2;

pub const entriesSection = "sprites";
pub const layersSection = "sprite_layers";

/// How many rotations of the view the sprites are drawn in.
pub const rotationCount = 4;

/// The width of a cube's square the sprites were drawn for, in pixels.
blockWidth: u16,
/// The sprites in each rotation.
count: u32,
/// `count` for each rotation, one rotation after another.
entries: []const Sprite,
/// The `sprite_layers` section.
layers: []align(4) const u8,

/// The `sprites` section's fields before its entries.
const Header = extern struct {
    /// The sprites in each rotation.
    count: u32,
    blockWidth: u16,
    reserved: u16 = 0,
};

/// Where a sprite's layers are in `sprite_layers`, and what it covers.
pub const Sprite = extern struct {
    /// From the start of `sprite_layers`, a multiple of 4; `Sections.add` sets it.
    offset: u32 = 0,
    /// Where its top left pixel is, from the top left of the cube's square.
    left: i16,
    top: i16,
    width: u16,
    height: u16,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        /// It has a tinted layer.
        tinted: bool = false,
        /// It covers every pixel a cube's top and sides do, which leave the square's corners
        /// empty, so nothing behind the block shows.
        fills: bool = false,
        _: u30 = 0,
    };

    fn pixelCount(self: Sprite) usize {
        return @as(usize, self.width) * self.height;
    }

    /// The bytes of its layers, padded to a multiple of 4.
    fn layersLength(self: Sprite) usize {
        const pixels = self.pixelCount();
        return pixels * (if (self.flags.tinted) @as(usize, 8) else 4) + std.mem.alignForward(usize, pixels * 2, 4);
    }
};

/// A sprite's pixels, each with how far into the block its point is.
pub const SpriteLayers = struct {
    /// Row by row, opaque where the block is, and transparent where it shows nothing.
    plain: []const u32,
    /// Lit but not yet tinted, each pixel's alpha how much of it the layer covers.
    tinted: ?[]const u32,
    /// x + y + z of each pixel's point, the block being from 0 to 1, in 256ths.
    depths: []const i16,

    /// Whether it shows anything at pixel `p`.
    pub fn shows(self: *const SpriteLayers, p: usize) bool {
        if (self.plain[p] & 0xff000000 != 0) return true;
        const tinted = self.tinted orelse return false;
        return tinted[p] & 0xff000000 != 0;
    }
};

/// The two sections as they're made, a sprite at a time: each sprite is drawn in place in a small
/// buffer of `sprite_layers`, which goes to the file whenever it's full, so memory holds only
/// the sprites drawn since. Each sprite's record goes straight in its place in the `sprites`
/// section, which is sized once, from the sprites planned.
pub const Sections = struct {
    /// The sprites' records in the `sprites` section; `count` of them are written.
    entries: []Sprite,
    count: usize = 0,
    layers: FileBuffer,
    /// Where each different sprite's layers are, by their hash (`shareLast`).
    offsets: std.AutoHashMapUnmanaged([16]u8, u32) = .empty,

    /// How long a buffer to give `init`: enough for many sprites, the largest about 92 KB.
    pub const bufferLength = 1 << 20;

    /// The bytes of a `sprites` section of `count` sprites in each rotation.
    pub fn entriesLength(count: usize) usize {
        return @sizeOf(Header) + count * rotationCount * @sizeOf(Sprite);
    }

    /// With `sprite_layers` at `start` in `file`, which must be open for writing, and the `sprites`
    /// section in `entries`, `entriesLength` long.
    pub fn init(io: std.Io, file: std.Io.File, start: u64, buffer: *align(4) [bufferLength]u8, entries: []align(4) u8, blockWidth: u16) Sections {
        const records: []Sprite = @alignCast(std.mem.bytesAsSlice(Sprite, entries[@sizeOf(Header)..]));
        const header: *Header = @ptrCast(entries.ptr);
        header.* = .{ .count = @intCast(records.len / rotationCount), .blockWidth = blockWidth };
        return .{ .entries = records, .layers = .init(io, file, start, std.math.maxInt(u32), buffer) };
    }

    /// Makes room for every sprite's hash, so `offsets` is never moved.
    pub fn ensureCapacity(self: *Sections, allocator: std.mem.Allocator) !void {
        try self.offsets.ensureTotalCapacity(allocator, @intCast(self.entries.len));
    }

    /// With the sprite last added filled in: if a sprite before it has the same layers, points
    /// it at those instead and takes its own back.
    pub fn shareLast(self: *Sections, allocator: std.mem.Allocator) !void {
        const sprite = &self.entries[self.count - 1];
        const length = sprite.layersLength();
        var hash: [16]u8 = undefined;
        std.crypto.hash.Blake3.hash(self.layers.buffer[self.layers.held - length .. self.layers.held], &hash, .{});
        const found = try self.offsets.getOrPut(allocator, hash);
        if (found.found_existing) {
            sprite.offset = found.value_ptr.*;
            self.layers.drop(length);
        } else {
            found.value_ptr.* = sprite.offset;
        }
    }

    /// `sprite_layers` is done, and all of it in the file.
    pub fn flush(self: *Sections) !void {
        try self.layers.flush();
    }

    /// `sprite_layers`, read back from the file, on a multiple of 4 as a mapped file's sections
    /// are.
    pub fn readLayers(self: *const Sections, allocator: std.mem.Allocator) ![]align(4) u8 {
        const bytes = try allocator.alignedAlloc(u8, .@"4", self.layers.length);
        errdefer allocator.free(bytes);
        if (try self.layers.file.readPositionalAll(self.layers.io, bytes, self.layers.start) != bytes.len) return error.EndOfStream;
        return bytes;
    }

    /// A sprite's layers, where they go, to be filled in before the next sprite is added.
    pub const Room = struct {
        plain: []u32,
        tinted: ?[]u32,
        depths: []i16,
    };

    /// Adds `sprite`, its offset set to where its layers go, and returns them.
    pub fn add(self: *Sections, sprite: Sprite) !Room {
        const offset = self.layers.length;
        const bytes = self.layers.reserve(sprite.layersLength()) catch |err| return switch (err) {
            error.BufferFull => error.SpriteLayersTooLong,
            else => |e| e,
        };
        self.entries[self.count] = sprite;
        self.entries[self.count].offset = @intCast(offset);
        self.count += 1;
        const pixels = sprite.pixelCount();
        const aligned: []align(4) u8 = @alignCast(bytes);
        const depthsAt = pixels * (if (sprite.flags.tinted) @as(usize, 8) else 4);
        return .{
            .plain = @alignCast(std.mem.bytesAsSlice(u32, aligned[0 .. pixels * 4])),
            .tinted = if (sprite.flags.tinted) @alignCast(std.mem.bytesAsSlice(u32, aligned[pixels * 4 .. depthsAt])) else null,
            .depths = @alignCast(std.mem.bytesAsSlice(i16, aligned[depthsAt..][0 .. pixels * 2])),
        };
    }
};

/// The sprites in the `sprites` section's bytes, `entries`, and the `sprite_layers` section's,
/// `layers`, read in place: they must outlive the result.
pub fn parse(entries: []align(4) const u8, layers: []align(4) const u8) error{NotPreparedBlocks}!Sprites {
    if (entries.len < @sizeOf(Header)) return error.NotPreparedBlocks;
    const header: *const Header = @ptrCast(entries.ptr);
    if (entries.len != Sections.entriesLength(header.count)) return error.NotPreparedBlocks;
    const self: Sprites = .{
        .blockWidth = header.blockWidth,
        .count = header.count,
        .entries = @alignCast(std.mem.bytesAsSlice(Sprite, entries[@sizeOf(Header)..])),
        .layers = layers,
    };
    for (self.entries) |sprite| {
        if (sprite.offset % 4 != 0 or sprite.offset > layers.len or sprite.layersLength() > layers.len - sprite.offset) return error.NotPreparedBlocks;
    }
    return self;
}

/// Those of rotation `rotation`, by quarter turn from 0.
pub fn ofRotation(self: *const Sprites, rotation: usize) Sprites {
    var out = self.*;
    out.entries = self.entries[rotation * self.count ..][0..self.count];
    return out;
}

/// Sprite `index`'s layers, where the file is.
pub fn layersOf(self: *const Sprites, index: u32) SpriteLayers {
    const sprite = self.entries[index];
    const pixels = sprite.pixelCount();
    var at: usize = sprite.offset;
    const plain = self.take(u32, &at, pixels);
    const tinted = if (sprite.flags.tinted) self.take(u32, &at, pixels) else null;
    return .{ .plain = plain, .tinted = tinted, .depths = self.take(i16, &at, pixels) };
}

fn take(self: *const Sprites, comptime T: type, at: *usize, count: usize) []const T {
    const bytes = self.layers[at.*..][0 .. count * @sizeOf(T)];
    at.* += count * @sizeOf(T);
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}

test "add and parse" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "sprites", .{ .read = true });
    defer file.close(io);
    // A cube's sprite and a plant's, the plant reaching out of its square and tinted.
    const sprites = [_]Sprite{
        .{ .left = 0, .top = 0, .width = 2, .height = 1, .flags = .{ .fills = true } },
        .{ .left = -3, .top = 1, .width = 1, .height = 3, .flags = .{ .tinted = true } },
    };
    const layers = [_]SpriteLayers{
        .{ .plain = &.{ 1, 2 }, .tinted = null, .depths = &.{ 3, 4 } },
        .{ .plain = &.{ 5, 6, 7 }, .tinted = &.{ 8, 9, 10 }, .depths = &.{ -1, 0, 1 } },
    };
    var buffer: [Sections.bufferLength]u8 align(4) = undefined;
    var section: [Sections.entriesLength(2)]u8 align(4) = undefined;
    const entries: []align(4) u8 = &section;
    var sections: Sections = .init(io, file, 8, &buffer, entries, 32);
    for (0..rotationCount) |_| for (sprites, layers) |sprite, each| {
        const room = try sections.add(sprite);
        @memcpy(room.plain, each.plain);
        if (room.tinted) |tinted| @memcpy(tinted, each.tinted.?);
        @memcpy(room.depths, each.depths);
    };
    try sections.flush();
    try std.testing.expectEqual(8 + 2 * rotationCount * 16, entries.len);
    const pixels = try sections.readLayers(allocator);
    defer allocator.free(pixels);

    const read = try parse(entries, pixels);
    try std.testing.expectEqual(32, read.blockWidth);
    try std.testing.expectEqual(2, read.count);
    try std.testing.expectEqual(2 * rotationCount, read.entries.len);
    const plant = read.entries[1];
    try std.testing.expectEqual(@as(i16, -3), plant.left);
    try std.testing.expect(plant.flags.tinted and !plant.flags.fills);
    // The cube's depths take 4 bytes, so the plant's layers start after 8 + 4.
    try std.testing.expectEqual(12, plant.offset);
    const drawn = read.layersOf(1);
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 7 }, drawn.plain);
    try std.testing.expectEqualSlices(u32, &.{ 8, 9, 10 }, drawn.tinted.?);
    try std.testing.expectEqualSlices(i16, &.{ -1, 0, 1 }, drawn.depths);
    try std.testing.expectEqualSlices(i16, &.{ 3, 4 }, read.layersOf(0).depths);
    try std.testing.expectEqual(null, read.layersOf(0).tinted);
    try std.testing.expect(read.entries[0].flags.fills);

    // A rotation's sprites are numbered as rotation 0's are, and read the same layers here.
    const last = read.ofRotation(rotationCount - 1);
    try std.testing.expectEqual(2, last.entries.len);
    try std.testing.expectEqual(&read.entries[6], &last.entries[0]);
    try std.testing.expect(last.entries[1].flags.tinted);

    // A `sprites` section of another length than its count gives, or a sprite whose layers go
    // past the end of `sprite_layers`, isn't one.
    try std.testing.expectError(error.NotPreparedBlocks, parse(entries[0 .. entries.len - 16], pixels));
    try std.testing.expectError(error.NotPreparedBlocks, parse(entries[0..4], pixels));
    try std.testing.expectError(error.NotPreparedBlocks, parse(entries, pixels[0 .. pixels.len - 4]));
    // Nor is one whose layers aren't on a multiple of 4.
    const second: *Sprite = @ptrCast(@alignCast(entries[8 + 16 ..][0..16]));
    second.offset += 2;
    try std.testing.expectError(error.NotPreparedBlocks, parse(entries, pixels));
}

test "Sections.shareLast" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "sprites", .{ .read = true });
    defer file.close(io);
    var buffer: [Sections.bufferLength]u8 align(4) = undefined;
    var section: [Sections.entriesLength(1)]u8 align(4) = undefined;
    var sections: Sections = .init(io, file, 0, &buffer, &section, 32);
    defer sections.offsets.deinit(allocator);
    try sections.ensureCapacity(allocator);

    // The same pixels twice, a different one, and the same again where another sprite is.
    const sprite: Sprite = .{ .left = 0, .top = 0, .width = 1, .height = 1, .flags = .{} };
    const moved: Sprite = .{ .left = 5, .top = 6, .width = 1, .height = 1, .flags = .{} };
    for ([_]Sprite{ sprite, sprite, sprite, moved }, [_]u32{ 1, 1, 2, 1 }) |each, colour| {
        (try sections.add(each)).plain[0] = colour;
        try sections.shareLast(allocator);
    }
    try sections.flush();
    const pixels = try sections.readLayers(allocator);
    defer allocator.free(pixels);

    const entries = sections.entries;
    try std.testing.expectEqual(2 * 8, pixels.len);
    try std.testing.expectEqual(2, sections.offsets.count());
    try std.testing.expectEqual(entries[0].offset, entries[1].offset);
    try std.testing.expectEqual(8, entries[2].offset);
    try std.testing.expectEqual(entries[0].offset, entries[3].offset);
    try std.testing.expectEqual(5, entries[3].left);
}
