//! A WebP encoder for 8-bit RGBA images, lossless or lossy: libwebp's encoder. An `Encoder` sets up its
//! pixel and output buffers once, for the largest image it will take, and the working memory
//! libwebp allocates from as it encodes.
const std = @import("std");
const c = @import("encode");

pub const Options = struct {
    /// libwebp's trade between speed and size, from 0, the fastest, to 6.
    method: u8 = 0,
    /// How hard it looks for a smaller file, from 0 to 100.
    effort: f32 = 0,
    /// The working memory libwebp allocates from, in bytes; what doesn't fit comes from `malloc`.
    /// By default 4 MB and 48 bytes a pixel of the largest image: 512 × 512 tiles took up to
    /// 11.6 MB, and a 64 × 48 image 1.2 MB.
    workingMemory: ?usize = null,
};

pub const Encoder = struct {
    width: u32,
    height: u32,
    options: Options,
    /// The pixels being encoded, as libwebp takes them: each alpha, red, green and blue, from the
    /// highest byte. libwebp may change them as it encodes.
    argb: []u32,
    /// The file being written.
    out: []u8,
    working: Working,

    /// An encoder for images of up to `width` × `height` pixels.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, options: Options) !Encoder {
        const argb = try allocator.alloc(u32, @as(usize, width) * height);
        errdefer allocator.free(argb);
        // Twice the pixels' bytes: more than an image of noise takes.
        const out = try allocator.alloc(u8, 2 * @as(usize, width) * height * 4 + 4096);
        errdefer allocator.free(out);
        const workingMemory = options.workingMemory orelse (4 << 20) + 48 * @as(usize, width) * height;
        const memory = try allocator.alignedAlloc(u8, .fromByteUnits(Working.alignment), workingMemory);
        return .{ .width = width, .height = height, .options = options, .argb = argb, .out = out, .working = .{ .memory = memory } };
    }

    pub fn deinit(self: Encoder, allocator: std.mem.Allocator) void {
        allocator.free(self.argb);
        allocator.free(self.out);
        allocator.free(self.working.memory);
    }

    /// The lossless WebP file of `pixels`, `width` × `height` of them row by row, each red,
    /// green, blue and alpha bytes. Valid until the next `encode` or `encodeLossy`.
    /// error.EncodingFailed if libwebp can't encode it.
    pub fn encode(self: *Encoder, pixels: []const u8, width: u32, height: u32) error{EncodingFailed}![]const u8 {
        return self.encodeWith(pixels, width, height, true, self.options.effort);
    }

    /// `pixels` as a lossy WebP file, at `quality` from 0 to 100; the alpha channel stays
    /// lossless.
    pub fn encodeLossy(self: *Encoder, pixels: []const u8, width: u32, height: u32, quality: f32) error{EncodingFailed}![]const u8 {
        return self.encodeWith(pixels, width, height, false, quality);
    }

    fn encodeWith(self: *Encoder, pixels: []const u8, width: u32, height: u32, lossless: bool, quality: f32) error{EncodingFailed}![]const u8 {
        std.debug.assert(width <= self.width and height <= self.height and pixels.len == @as(usize, width) * height * 4);
        var config: c.WebPConfig = undefined;
        if (c.WebPConfigInit(&config) == 0) return error.EncodingFailed;
        config.lossless = @intFromBool(lossless);
        config.method = self.options.method;
        config.quality = quality;

        self.working.end = 0;
        self.working.last = 0;
        current = &self.working;
        defer current = null;

        var picture: c.WebPPicture = undefined;
        if (c.WebPPictureInit(&picture) == 0) return error.EncodingFailed;
        defer c.WebPPictureFree(&picture);
        const argb = self.argb[0 .. @as(usize, width) * height];
        toArgb(argb, pixels);
        picture.use_argb = 1;
        picture.width = @intCast(width);
        picture.height = @intCast(height);
        picture.argb = argb.ptr;
        picture.argb_stride = @intCast(width);

        var output: Output = .{ .out = self.out };
        picture.writer = Output.write;
        picture.custom_ptr = &output;
        if (c.WebPEncode(&config, &picture) == 0 or output.full) return error.EncodingFailed;
        return self.out[0..output.end];
    }
};

/// Memory libwebp allocates from as an encoder encodes, set up once: each allocation takes the
/// next bytes, freeing gives back only the last one, and each encode starts it empty.
const Working = struct {
    const alignment = 16;

    memory: []align(alignment) u8,
    end: usize = 0,
    /// Where the last allocation starts.
    last: usize = 0,
    /// The most an encode took.
    peak: usize = 0,
    /// Allocations that didn't fit, taken from `malloc` instead.
    overflows: usize = 0,

    fn allocate(self: *Working, bytes: usize) ?[*]u8 {
        const start = std.mem.alignForward(usize, self.end, alignment);
        if (start + bytes > self.memory.len) {
            self.overflows += 1;
            return null;
        }
        self.last = start;
        self.end = start + bytes;
        self.peak = @max(self.peak, self.end);
        return self.memory[start..].ptr;
    }

    fn owns(self: *const Working, ptr: *anyopaque) bool {
        const address = @intFromPtr(ptr);
        const base = @intFromPtr(self.memory.ptr);
        return address >= base and address < base + self.memory.len;
    }

    fn free(self: *Working, ptr: *anyopaque) void {
        if (@intFromPtr(ptr) - @intFromPtr(self.memory.ptr) == self.last) self.end = self.last;
    }
};

/// The working memory of the encoder encoding on this thread, if any.
threadlocal var current: ?*Working = null;

/// libwebp's own limit on one allocation.
const allocationLimit = 1 << 34;

/// `count` × `size` bytes, or null if that's more than libwebp allows.
fn sizeOf(count: u64, size: usize) ?usize {
    const bytes = std.math.mul(u64, count, size) catch return null;
    return if (bytes > allocationLimit) null else @intCast(bytes);
}

// libwebp allocates through these three (`src/utils/utils.c`, whose own are renamed in
// `build.zig`).

export fn WebPSafeMalloc(count: u64, size: usize) callconv(.c) ?*anyopaque {
    const bytes = sizeOf(count, size) orelse return null;
    if (current) |working| if (working.allocate(bytes)) |block| return block;
    return std.c.malloc(bytes);
}

export fn WebPSafeCalloc(count: u64, size: usize) callconv(.c) ?*anyopaque {
    const bytes = sizeOf(count, size) orelse return null;
    if (current) |working| if (working.allocate(bytes)) |block| {
        @memset(block[0..bytes], 0);
        return block;
    };
    return std.c.calloc(1, bytes);
}

export fn WebPSafeFree(ptr: ?*anyopaque) callconv(.c) void {
    const block = ptr orelse return;
    if (current) |working| if (working.owns(block)) return working.free(block);
    std.c.free(block);
}

/// `pixels`, each red, green, blue and alpha bytes, as libwebp's ARGB words.
fn toArgb(argb: []u32, pixels: []const u8) void {
    for (argb, std.mem.bytesAsSlice(u32, pixels)) |*out, rgba| {
        const pixel = std.mem.littleToNative(u32, rgba);
        out.* = (pixel & 0xff00ff00) | (pixel >> 16 & 0xff) | (pixel & 0xff) << 16;
    }
}

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

    // Lossy, with its alpha channel: a VP8X file, far smaller than lossless for noise.
    const lossy = try encoder.encodeLossy(&noise, width, height, 90);
    try std.testing.expectEqualStrings("WEBPVP8X", lossy[8..16]);
    try std.testing.expect(lossy.len < first.len);

    // All of it in the working memory.
    try std.testing.expectEqual(0, encoder.working.overflows);

    // With too little, the rest comes from malloc, for the same file.
    var short: Encoder = try .init(std.testing.allocator, width, height, .{ .workingMemory = 4096 });
    defer short.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first, try short.encode(&noise, width, height));
    try std.testing.expect(short.working.overflows > 0);
}

test toArgb {
    var pixels: [37 * 4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(2);
    prng.random().bytes(&pixels);
    var argb: [37]u32 = undefined;
    toArgb(&argb, &pixels);

    var picture: c.WebPPicture = undefined;
    try std.testing.expect(c.WebPPictureInit(&picture) != 0);
    defer c.WebPPictureFree(&picture);
    picture.use_argb = 1;
    picture.width = 37;
    picture.height = 1;
    try std.testing.expect(c.WebPPictureImportRGBA(&picture, &pixels, 37 * 4) != 0);
    try std.testing.expectEqualSlices(u32, picture.argb[0..37], &argb);
}
