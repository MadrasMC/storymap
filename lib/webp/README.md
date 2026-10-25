# webp

A WebP encoder for 8-bit RGBA images, lossless or lossy, for Zig 0.17: [libwebp 1.6.0](https://github.com/webmproject/libwebp/tree/v1.6.0)'s encoder (BSD-3-Clause). An `Encoder` sets up its output buffer once, for the largest image it will take, and libwebp writes the file into it; libwebp allocates its own working memory as it encodes. Under fully transparent pixels, libwebp may change the colour, to compress better: what shows stays the same.

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
| `Encoder.init(allocator, width, height, options)` | an encoder for images up to `width` × `height`: 8 bytes per pixel for its output |
| `Encoder.encode(pixels, width, height)` | the lossless WebP file, valid until the next `encode` or `encodeLossy`; `error.EncodingFailed` if libwebp can't encode it |
| `Encoder.encodeLossy(pixels, width, height, quality)` | the same as a lossy WebP file, at `quality` from 0 to 100, its alpha channel still lossless |
| `Encoder.deinit(allocator)` | frees the buffer |
| `Options.method` | libwebp's trade between speed and size, from 0, the fastest (the default), to 6 |
| `Options.effort` | how hard it looks for a smaller file, from 0 (the default) to 100 |
