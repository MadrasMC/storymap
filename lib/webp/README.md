# webp

A WebP encoder for 8-bit RGBA images, lossless or lossy, for Zig 0.17: [libwebp 1.6.0](https://github.com/webmproject/libwebp/tree/v1.6.0)'s encoder (BSD-3-Clause). An `Encoder` sets up its buffers once, for the largest image it will take: the pixels in libwebp's layout, the file libwebp writes, and the working memory libwebp allocates from as it encodes. `lib/webp` replaces libwebp's allocation functions (`WebPSafeMalloc`, `WebPSafeCalloc` and `WebPSafeFree`, renamed in `src/utils/utils.c` by `build.zig`): while an encoder encodes on a thread, they take from its working memory, freeing gives back only the last allocation, and each encode starts it empty; what doesn't fit, and allocations outside an encode, go to `malloc`. On Windows, this made lossless encoding of 512 × 512 tiles a third faster, as fast as with glibc's `malloc` on Linux. Under fully transparent pixels, libwebp may change the colour, to compress better: what shows stays the same.

`build.zig` fetches libwebp as a dependency and compiles its encoder, with what it shares with the decoder but not the decoder itself, optimized in every build mode, and translates `src/webp/encode.h` for Zig.

## Example

```zig
const webp = @import("webp");

var encoder: webp.Encoder = try .init(allocator, 512, 512, .{});
defer encoder.deinit(allocator);
// `pixels`: 512 × 512 × 4 bytes, row by row, each red, green, blue, alpha.
const file = try encoder.encode(pixels, 512, 512);
try dir.writeFile(io, .{ .sub_path = "tile.webp", .data = file });
```

## API

| name | contents |
| --- | --- |
| `Encoder.init(allocator, width, height, options)` | an encoder for images up to `width` × `height`: 12 bytes per pixel for its pixels and output, and its working memory |
| `Encoder.encode(pixels, width, height)` | the lossless WebP file, valid until the next `encode` or `encodeLossy`; `error.EncodingFailed` if libwebp can't encode it |
| `Encoder.encodeLossy(pixels, width, height, quality)` | the same as a lossy WebP file, at `quality` from 0 to 100, its alpha channel still lossless |
| `Encoder.deinit(allocator)` | frees the buffers |
| `Encoder.working.peak`, `Encoder.working.overflows` | the most working memory an encode took, and how many allocations didn't fit and came from `malloc` |
| `Options.method` | libwebp's trade between speed and size, from 0, the fastest (the default), to 6 |
| `Options.effort` | how hard it looks for a smaller file, from 0 (the default) to 100 |
| `Options.workingMemory` | the working memory's size in bytes; by default 4 MB and 48 bytes a pixel (16.6 MB for 512 × 512, where tiles took up to 11.6) |
