# png

A PNG encoder for 8-bit RGBA images, for Zig 0.17, that allocates nothing while encoding. An `Encoder` sets up its buffers once, for the largest image it will take; each `encode` writes the PNG into them and returns it.

Rows are filtered per row with the filter whose output adds up to the least as signed bytes (the usual heuristic), all five filters worked out together with vector instructions, and compressed with libdeflate (`lib/libdeflate`), with `std.compress.flate`, or with `PixelDeflate`, which looks for a match only where a pixel starts and writes one block with its own Huffman codes. libdeflate's level 1 makes files as small as `std.compress.flate`'s `level_4` in under a third of the time. `RowEncoder`, which writes as it goes, compresses with libdeflate a band of filtered rows of about 1 MiB at a time, each without the history of the bands before it, and writes each as one `IDAT` chunk.

## Example

```zig
const png = @import("png");

var encoder: png.Encoder = try .init(allocator, 512, 512, .{});
defer encoder.deinit(allocator);
// `pixels`: 512 × 512 × 4 bytes, row by row, each red, green, blue, alpha.
const file = try encoder.encode(pixels, 512, 512);
try dir.writeFile(io, .{ .sub_path = "tile.png", .data = file });
```

For an image too large to hold, a `RowEncoder` writes as it goes:

```zig
var encoder: png.RowEncoder = try .init(allocator, 40000, .{ .level = 1 });
defer encoder.deinit(allocator);
try encoder.begin(&file.interface, 40000, 30000);
// Each `row`: 40,000 × 4 bytes, top to bottom.
for (rows) |row| try encoder.writeRow(row);
try encoder.finish();
try file.interface.flush();
```

## API

| name | contents |
| --- | --- |
| `maxSide` | the most pixels across or down a PNG can have, 2³¹ − 1 |
| `Encoder.init(allocator, width, height, options)` | an encoder for images up to `width` × `height`: about 8 bytes per pixel, plus 64 KiB for deflate's window, `std.compress.flate`'s compressor's 225 KiB and, for `.libdeflate`, libdeflate's working memory, from `malloc` |
| `Encoder.encode(pixels, width, height)` | the PNG, valid until the next `encode` or `compress`: `filter`, then `compress` |
| `Encoder.filter(pixels, width, height)` | filters the image's rows, the first half of `encode`; with `compress`, the two halves can be timed apart |
| `Encoder.compress()` | the PNG of the image `filter` last filtered, the second half of `encode` |
| `Encoder.deinit(allocator)` | frees the buffers |
| `Options.compressor` | `.libdeflate` (the default), `.flate`, `std.compress.flate`, or `.pixels`, a deflate that looks for a match only where a pixel starts, as fpng does |
| `Options.libdeflate.level` | for `.libdeflate`, from 0, stored uncompressed, through 1, the fastest that compresses (the default), to 12, the smallest |
| `Options.pixels.ways` | for `.pixels`, how many places it remembers for each 4 bytes, the longest match among them taken (8 by default): more makes smaller files, more slowly |
| `Options.level` | for `.flate`, deflate's trade between speed and size, one of `std.compress.flate.Compress.Options` (`.level_4` by default) |
| `RowEncoder.init(allocator, width, options)` | an encoder for images up to `width` wide, of any height, with libdeflate at `options.level` (1 by default): two rows, a band of filtered rows of 1 MiB or one row if that's more, the band compressed, and libdeflate's working memory. It must stay where it is while encoding |
| `RowEncoder.memory(width)` | about how many bytes an encoder for images up to `width` wide takes, at levels up to 9 |
| `RowEncoder.bandBytes` | how much filtered image data a band holds, 1 MiB, in whole rows and at least one |
| `RowEncoder.begin(out, width, height)` | starts an image in `out`, a `std.Io.Writer`; one encoder can encode one image after another |
| `RowEncoder.writeRow(row)` | adds the next row, filtered and compressed; `row` needn't outlast the call |
| `RowEncoder.finish()` | ends the image, once all its rows are in; flushing `out` is left to the caller |
| `RowEncoder.deinit(allocator)` | frees the buffers |
