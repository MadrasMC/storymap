# png

A PNG encoder for 8-bit RGBA images, for Zig 0.17, that allocates nothing while encoding. An `Encoder` sets up its buffers once, for the largest image it will take; each `encode` writes the PNG into them and returns it.

Rows are filtered per row with the filter whose output adds up to the least as signed bytes (the usual heuristic), and compressed with `std.compress.flate`.

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
| `Encoder.init(allocator, width, height, options)` | an encoder for images up to `width` × `height`: about 4 bytes per pixel, plus 64 KB for deflate's window and the compressor's 224 KB |
| `Encoder.encode(pixels, width, height)` | the PNG, valid until the next `encode` |
| `Encoder.deinit(allocator)` | frees the buffers |
| `Options.level` | deflate's trade between speed and size, one of `std.compress.flate.Compress.Options` (`.level_4` by default) |
