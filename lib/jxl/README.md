# jxl

A lossless JPEG XL encoder for 8-bit RGBA images, for Zig 0.17: libjxl's fast lossless encoder, `lib/jxl/enc_fast_lossless.cc` from [libjxl 0.12.0](https://github.com/libjxl/libjxl/tree/v0.12.0) (BSD-3-Clause), built standalone, without the rest of libjxl. An `Encoder` sets up its output buffer once, for the largest image it will take; libjxl allocates its own working memory as it encodes. The files are bare JPEG XL codestreams, starting `FF 0A`.

`build.zig` fetches libjxl as a dependency and compiles that one file with `-DFJXL_STANDALONE=1`, optimized in every build mode, and links the C++ standard library.

## Example

```zig
const jxl = @import("jxl");

var encoder: jxl.Encoder = try .init(allocator, 512, 512, .{});
defer encoder.deinit(allocator);
// `pixels`: 512 × 512 × 4 bytes, row by row, each red, green, blue, alpha.
const file = try encoder.encode(pixels, 512, 512);
try dir.writeFile(io, .{ .sub_path = "tile.jxl", .data = file });
```

## API

| name | contents |
| --- | --- |
| `Encoder.init(allocator, width, height, options)` | an encoder for images up to `width` × `height`: 8 bytes per pixel for its output |
| `Encoder.encode(pixels, width, height)` | the JPEG XL file, valid until the next `encode`; `error.EncodingFailed` if libjxl can't encode it |
| `Encoder.deinit(allocator)` | frees the buffer |
| `Options.effort` | how hard the encoder looks, from 1 (2 by default); from 2 up, it keeps a palette for an image with few colours |
