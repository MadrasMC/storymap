//! The isometric view's sprites of a game's blocks, every one drawn once when the game's
//! blocks are prepared (`isometric.drawSprites`), in two sections of the prepared blocks file
//! (docs/storyblk/spec.md): `sprites`, a `Sprite` for each, and `sprite_layers`, their pixels.
//! Everything in them lies at a multiple of its own size, so a render reads them where the file
//! is mapped.
const Sprites = @This();

const std = @import("std");
const builtin = @import("builtin");
const ReservedBuffer = @import("ReservedBuffer.zig");

comptime {
    // The sections are read in place, as the machine's own integers.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 8 and @sizeOf(Sprite) == 16);
}

/// How the sprites are drawn: raise it when that changes, so files drawn before are drawn again.
pub const generatorVersion: u16 = 4;
/// The layout of both sections (spec §7).
pub const layoutVersion: u8 = 1;

pub const entriesSection = "sprites";
pub const layersSection = "sprite_layers";

/// The width of a cube's square the sprites were drawn for, in pixels.
blockWidth: u16,
entries: []const Sprite,
/// The `sprite_layers` section.
layers: []align(4) const u8,

/// The `sprites` section's fields before its entries.
const Header = extern struct {
    count: u32,
    blockWidth: u16,
    reserved: u16 = 0,
};

/// Where a sprite's layers are in `sprite_layers`, and what it covers.
pub const Sprite = extern struct {
    /// From the start of `sprite_layers`, a multiple of 4; `write` sets it.
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

/// The two sections as they're made, a sprite at a time: a sprite's layers need to last only
/// until it's added, so the pixels are never held twice, and `sprite_layers`, which is as long
/// as a section can be for all anyone knows until the last sprite is drawn, is never copied.
pub const Sections = struct {
    entries: std.ArrayList(Sprite) = .empty,
    layers: ReservedBuffer,

    pub fn init() error{OutOfMemory}!Sections {
        return .{ .layers = try .init(std.math.maxInt(u32)) };
    }

    /// `entries` is left to the allocator given to `add`.
    pub fn deinit(self: *Sections) void {
        self.layers.deinit();
    }

    /// Adds `sprite` with its `layers`, its offset set to where they go.
    pub fn add(self: *Sections, allocator: std.mem.Allocator, sprite: Sprite, layers: SpriteLayers) !void {
        std.debug.assert(layers.plain.len == sprite.pixelCount() and layers.depths.len == sprite.pixelCount());
        std.debug.assert((layers.tinted != null) == sprite.flags.tinted);
        if (self.entries.items.len == std.math.maxInt(u32)) return error.TooManySprites;
        var stored = sprite;
        stored.offset = @intCast(self.layers.length);
        try self.entries.append(allocator, stored);
        self.appendLayers(layers) catch |err| return switch (err) {
            error.BufferFull => error.SpriteLayersTooLong,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn appendLayers(self: *Sections, layers: SpriteLayers) !void {
        try self.layers.append(std.mem.sliceAsBytes(layers.plain));
        if (layers.tinted) |tinted| try self.layers.append(std.mem.sliceAsBytes(tinted));
        try self.layers.append(std.mem.sliceAsBytes(layers.depths));
        const padding = std.mem.alignForward(usize, layers.depths.len * 2, 4) - layers.depths.len * 2;
        try self.layers.append((&[_]u8{ 0, 0 })[0..padding]);
    }

    /// The `sprites` section's bytes.
    pub fn entryBytes(self: *const Sections, allocator: std.mem.Allocator, blockWidth: u16) ![]align(4) u8 {
        const records = std.mem.sliceAsBytes(self.entries.items);
        const bytes = try allocator.alignedAlloc(u8, .@"4", @sizeOf(Header) + records.len);
        const header: Header = .{ .count = @intCast(self.entries.items.len), .blockWidth = blockWidth };
        @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));
        @memcpy(bytes[@sizeOf(Header)..], records);
        return bytes;
    }
};

/// The sprites in the `sprites` section's bytes, `entries`, and the `sprite_layers` section's,
/// `layers`, read in place: they must outlive the result.
pub fn parse(entries: []align(4) const u8, layers: []align(4) const u8) error{NotPreparedBlocks}!Sprites {
    if (entries.len < @sizeOf(Header)) return error.NotPreparedBlocks;
    const header: *const Header = @ptrCast(entries.ptr);
    if (entries.len != @sizeOf(Header) + @as(usize, header.count) * @sizeOf(Sprite)) return error.NotPreparedBlocks;
    const self: Sprites = .{
        .blockWidth = header.blockWidth,
        .entries = @alignCast(std.mem.bytesAsSlice(Sprite, entries[@sizeOf(Header)..])),
        .layers = layers,
    };
    for (self.entries) |sprite| {
        if (sprite.offset % 4 != 0 or sprite.offset > layers.len or sprite.layersLength() > layers.len - sprite.offset) return error.NotPreparedBlocks;
    }
    return self;
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
    // A cube's sprite and a plant's, the plant reaching out of its square and tinted.
    const sprites = [_]Sprite{
        .{ .left = 0, .top = 0, .width = 2, .height = 1, .flags = .{ .fills = true } },
        .{ .left = -3, .top = 1, .width = 1, .height = 3, .flags = .{ .tinted = true } },
    };
    const layers = [_]SpriteLayers{
        .{ .plain = &.{ 1, 2 }, .tinted = null, .depths = &.{ 3, 4 } },
        .{ .plain = &.{ 5, 6, 7 }, .tinted = &.{ 8, 9, 10 }, .depths = &.{ -1, 0, 1 } },
    };
    var sections: Sections = try .init();
    defer sections.deinit();
    defer sections.entries.deinit(allocator);
    for (sprites, layers) |sprite, each| try sections.add(allocator, sprite, each);
    const entries = try sections.entryBytes(allocator, 32);
    defer allocator.free(entries);
    try std.testing.expectEqual(8 + 2 * 16, entries.len);
    const pixels = sections.layers.written();

    const read = try parse(entries, pixels);
    try std.testing.expectEqual(32, read.blockWidth);
    try std.testing.expectEqual(2, read.entries.len);
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
