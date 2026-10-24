//! A lossless JPEG XL encoder for 8-bit RGBA images: libjxl's fast lossless encoder
//! (`lib/jxl/enc_fast_lossless.cc`, built standalone). An `Encoder` sets up its output buffer
//! once, for the largest image it will take; libjxl allocates its own working memory as it
//! encodes.
const std = @import("std");

pub const Options = struct {
    /// How hard the encoder looks, from 1. From 2 up, it keeps a palette for an image with few
    /// colours, and more effort samples more of the image for better codes.
    effort: u8 = 2,
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

    /// The JPEG XL file of `pixels`, `width` × `height` of them row by row, each red, green,
    /// blue and alpha bytes. Valid until the next `encode`. error.EncodingFailed if libjxl
    /// can't encode it.
    pub fn encode(self: *Encoder, pixels: []const u8, width: u32, height: u32) error{EncodingFailed}![]const u8 {
        std.debug.assert(width <= self.width and height <= self.height and pixels.len == @as(usize, width) * height * 4);
        var image: Image = .{ .pixels = pixels.ptr, .rowBytes = @as(usize, width) * 4 };
        const frame = JxlFastLosslessPrepareFrame(image.source(), width, height, 4, 8, false, self.options.effort, 1) orelse return error.EncodingFailed;
        defer JxlFastLosslessFreeFrameState(frame);
        if (!JxlFastLosslessProcessFrame(frame, true, null, null, null)) return error.EncodingFailed;
        if (!JxlFastLosslessPrepareHeader(frame, 1, 1)) return error.EncodingFailed;
        if (JxlFastLosslessMaxRequiredOutput(frame) > self.out.len) return error.EncodingFailed;
        var length: usize = 0;
        while (true) {
            const written = JxlFastLosslessWriteOutput(frame, self.out.ptr + length, self.out.len - length);
            if (written == 0) break;
            length += written;
        }
        return self.out[0..length];
    }
};

/// The pixels the encoder reads, as libjxl asks for them.
const Image = struct {
    pixels: [*]const u8,
    rowBytes: usize,

    fn source(self: *Image) InputSource {
        return .{ .@"opaque" = self, .get_color_channel_data_at = at, .release_buffer = release };
    }

    /// The pixel at (x, y), and the bytes from one row to the next.
    fn at(context: ?*anyopaque, x: usize, y: usize, _: usize, _: usize, rowOffset: *usize) callconv(.c) ?*const anyopaque {
        const self: *const Image = @ptrCast(@alignCast(context));
        rowOffset.* = self.rowBytes;
        return self.pixels + y * self.rowBytes + x * 4;
    }

    fn release(_: ?*anyopaque, _: ?*const anyopaque) callconv(.c) void {}
};

// lib/jxl/enc_fast_lossless.h, with FJXL_STANDALONE.
const InputSource = extern struct {
    @"opaque": ?*anyopaque,
    get_color_channel_data_at: *const fn (?*anyopaque, usize, usize, usize, usize, *usize) callconv(.c) ?*const anyopaque,
    release_buffer: *const fn (?*anyopaque, ?*const anyopaque) callconv(.c) void,
};
const FrameState = opaque {};
const Runner = fn (?*anyopaque, ?*anyopaque, *const fn (?*anyopaque, usize) callconv(.c) void, usize) callconv(.c) void;
extern fn JxlFastLosslessPrepareFrame(input: InputSource, width: usize, height: usize, channels: usize, bitDepth: usize, bigEndian: bool, effort: c_int, oneShot: c_int) ?*FrameState;
extern fn JxlFastLosslessProcessFrame(frame: *FrameState, isLast: bool, runnerContext: ?*anyopaque, runner: ?*const Runner, outputProcessor: ?*anyopaque) bool;
extern fn JxlFastLosslessPrepareHeader(frame: *FrameState, addImageHeader: c_int, isLast: c_int) bool;
extern fn JxlFastLosslessMaxRequiredOutput(frame: *const FrameState) usize;
extern fn JxlFastLosslessWriteOutput(frame: *FrameState, output: [*]u8, size: usize) usize;
extern fn JxlFastLosslessFreeFrameState(frame: *FrameState) void;

test Encoder {
    const width = 64;
    const height = 48;
    var encoder: Encoder = try .init(std.testing.allocator, width, height, .{});
    defer encoder.deinit(std.testing.allocator);

    // A JPEG XL codestream, the same every time.
    var noise: [width * height * 4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(1);
    prng.random().bytes(&noise);
    const first = try std.testing.allocator.dupe(u8, try encoder.encode(&noise, width, height));
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x0A }, first[0..2]);
    try std.testing.expectEqualSlices(u8, first, try encoder.encode(&noise, width, height));

    // One colour takes far less than noise, and a smaller image fits the same encoder.
    const flat: [16 * 8 * 4]u8 = @splat(200);
    const small = try encoder.encode(&flat, 16, 8);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x0A }, small[0..2]);
    try std.testing.expect(small.len * 20 < first.len);
}
