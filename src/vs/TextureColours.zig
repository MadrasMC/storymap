//! A block texture's colours for the map, as the game's colour-accurate map takes them from
//! its texture atlas: the texture's average colour, and a handful of its pixels picked at
//! random, which the map mixes in for grain (docs/rendering.md#how-the-game-draws-its-own-world-map).
//! Worked out when preparing blocks, so rendering never reads a texture.
const TextureColours = @This();

const std = @import("std");
const columns = @import("../columns.zig");
const stb = @import("stb_image");

const Rgb = columns.Rgb;

/// How many pixels are picked, as the game's atlas keeps (vsapi `TextureAtlasPosition.RndColorsLength`).
pub const samples = 30;

average: Rgb,
grain: [samples]Rgb,

/// The colours of the PNG image `png`, or null if it can't be decoded or is wholly
/// transparent.
pub fn ofPng(png: []const u8) ?TextureColours {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = stb.stbi_load_from_memory(png.ptr, @intCast(png.len), &width, &height, &channels, 4) orelse return null;
    defer stb.stbi_image_free(data);
    const count: usize = @intCast(width * height);
    const pixels: []const [4]u8 = @ptrCast(data[0 .. count * 4]);
    return of(pixels);
}

/// The colours of an image's RGBA pixels: the average weighs each pixel by how opaque it is,
/// and the grain is picked from pixels that aren't transparent, the same ones every time.
pub fn of(pixels: []const [4]u8) ?TextureColours {
    var sums: [3]u64 = .{ 0, 0, 0 };
    var weight: u64 = 0;
    for (pixels) |pixel| {
        for (&sums, pixel[0..3]) |*sum, channel| sum.* += @as(u64, channel) * pixel[3];
        weight += pixel[3];
    }
    if (weight == 0) return null;
    var self: TextureColours = undefined;
    for (&self.average, sums) |*channel, sum| channel.* = @intCast((sum + weight / 2) / weight);

    var random: std.Random.DefaultPrng = .init(0);
    for (&self.grain) |*sample| {
        // A few tries for a pixel that isn't transparent; there's at least one.
        var tries: usize = 0;
        const picked = while (true) : (tries += 1) {
            const pixel = pixels[random.random().uintLessThan(usize, pixels.len)];
            if (pixel[3] > 0 or tries == 64) break pixel;
        };
        sample.* = if (picked[3] > 0) picked[0..3].* else self.average;
    }
    return self;
}

test of {
    const pixels = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 0 }, .{ 0, 0, 0, 0 } };
    const colours = of(&pixels).?;
    try std.testing.expectEqual(Rgb{ 128, 0, 128 }, colours.average);
    for (colours.grain) |sample| try std.testing.expect(std.meta.eql(sample, Rgb{ 255, 0, 0 }) or std.meta.eql(sample, Rgb{ 0, 0, 255 }));
    try std.testing.expectEqual(null, of(&.{.{ 9, 9, 9, 0 }}));
}
