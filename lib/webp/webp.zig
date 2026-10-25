//! A lossless WebP encoder for 8-bit RGBA images: libwebp's encoder. An `Encoder` sets up its
//! output buffer once, for the largest image it will take; libwebp allocates its own working
//! memory as it encodes.
const std = @import("std");
const c = @import("encode");

pub const Options = struct {
    /// libwebp's trade between speed and size, from 0, the fastest, to 6.
    method: u8 = 0,
    /// How hard it looks for a smaller file, from 0 to 100.
    effort: f32 = 0,
};

pub const Encoder = struct {
    width: u32,
    height: u32,
    options: Options,
    /// The file being written.
    out: []u8,

    /// An encoder for images of up to `width` × `height` pixels.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, options: Options) !Encoder {
        // Twice the pixels' bytes: more than an image of noise takes.
        const out = try allocator.alloc(u8, 2 * @as(usize, width) * height * 4 + 4096);
        return .{ .width = width, .height = height, .options = options, .out = out };
    }

    pub fn deinit(self: Encoder, allocator: std.mem.Allocator) void {
        allocator.free(self.out);
    }

    /// The WebP file of `pixels`, `width` × `height` of them row by row, each red, green, blue
    /// and alpha bytes. Valid until the next `encode`. error.EncodingFailed if libwebp can't
    /// encode it.
    pub fn encode(self: *Encoder, pixels: []const u8, width: u32, height: u32) error{EncodingFailed}![]const u8 {
        std.debug.assert(width <= self.width and height <= self.height and pixels.len == @as(usize, width) * height * 4);
        var config: c.WebPConfig = undefined;
        if (c.WebPConfigInit(&config) == 0) return error.EncodingFailed;
        config.lossless = 1;
        config.method = self.options.method;
        config.quality = self.options.effort;

        var picture: c.WebPPicture = undefined;
        if (c.WebPPictureInit(&picture) == 0) return error.EncodingFailed;
        defer c.WebPPictureFree(&picture);
        picture.use_argb = 1;
        picture.width = @intCast(width);
        picture.height = @intCast(height);
        if (c.WebPPictureImportRGBA(&picture, pixels.ptr, @intCast(width * 4)) == 0) return error.EncodingFailed;

        var output: Output = .{ .out = self.out };
        picture.writer = Output.write;
        picture.custom_ptr = &output;
        if (c.WebPEncode(&config, &picture) == 0 or output.full) return error.EncodingFailed;
        return self.out[0..output.end];
    }
};

/// Where libwebp writes the file, as it goes.
const Output = struct {
    out: []u8,
    end: usize = 0,
    /// Set if the file didn't fit.
    full: bool = false,

    fn write(data: [*c]const u8, size: usize, picture: [*c]const c.WebPPicture) callconv(.c) c_int {
        const self: *Output = @ptrCast(@alignCast(picture.*.custom_ptr));
        if (self.end + size > self.out.len) {
            self.full = true;
            return 0;
        }
        @memcpy(self.out[self.end..][0..size], data[0..size]);
        self.end += size;
        return 1;
    }
};

test Encoder {
    const width = 64;
    const height = 48;
    var encoder: Encoder = try .init(std.testing.allocator, width, height, .{});
    defer encoder.deinit(std.testing.allocator);

    // A WebP file, lossless, the same every time.
    var noise: [width * height * 4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(1);
    prng.random().bytes(&noise);
    const first = try std.testing.allocator.dupe(u8, try encoder.encode(&noise, width, height));
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("RIFF", first[0..4]);
    try std.testing.expectEqualStrings("WEBPVP8L", first[8..16]);
    try std.testing.expectEqualSlices(u8, first, try encoder.encode(&noise, width, height));

    // One colour takes far less than noise, and a smaller image fits the same encoder.
    const flat: [16 * 8 * 4]u8 = @splat(200);
    const small = try encoder.encode(&flat, 16, 8);
    try std.testing.expectEqualStrings("RIFF", small[0..4]);
    try std.testing.expect(small.len * 20 < first.len);
}
