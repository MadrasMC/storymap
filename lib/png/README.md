# png

A PNG encoder for 8-bit RGBA images, for Zig 0.17, that allocates nothing while encoding. An `Encoder` sets up its buffers once, for the largest image it will take; each `encode` writes the PNG into them and returns it.

Rows are filtered per row with the filter whose output adds up to the least as signed bytes (the usual heuristic), all five filters worked out together with vector instructions, and compressed with `std.compress.flate`, or with `PixelDeflate`, which looks for a match only where a pixel starts and writes one block with its own Huffman codes.

## Example

```zig
const png = @import("png");

var encoder: png.Encoder = try .init(allocator, 512, 512, .{});
defer encoder.deinit(allocator);
// `pixels`: 512 × 512 × 4 bytes, row by row, each red, green, blue, alpha.
const file = try encoder.encode(pixels, 512, 512);
try dir.writeFile(io, .{ .sub_path = "tile.png", .data = file });
```

## API

| name | contents |
| --- | --- |
| `Encoder.init(allocator, width, height, options)` | an encoder for images up to `width` × `height`: about 8 bytes per pixel, plus 64 KB for deflate's window and the compressor's 224 KB |
| `Encoder.encode(pixels, width, height)` | the PNG, valid until the next `encode` or `compress`: `filter`, then `compress` |
| `Encoder.filter(pixels, width, height)` | filters the image's rows, the first half of `encode`; with `compress`, the two halves can be timed apart |
| `Encoder.compress()` | the PNG of the image `filter` last filtered, the second half of `encode` |
| `Encoder.deinit(allocator)` | frees the buffers |
| `Options.compressor` | `.flate`, `std.compress.flate` (the default), or `.pixels`, a deflate that looks for a match only where a pixel starts, as fpng does: faster, and larger |
| `Options.pixels.ways` | for `.pixels`, how many places it remembers for each 4 bytes, the longest match among them taken (8 by default): more makes smaller files, more slowly |
| `Options.level` | for `.flate`, deflate's trade between speed and size, one of `std.compress.flate.Compress.Options` (`.level_4` by default) |
