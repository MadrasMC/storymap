# libdeflate

Deflate compression into zlib streams, for Zig 0.17: [libdeflate 1.26](https://github.com/ebiggers/libdeflate/tree/v1.26)'s compressor (MIT). A `Compressor` is set up once, for one level; libdeflate allocates its working memory with `malloc` then, and nothing while compressing. It compresses a whole buffer in one call, which suits data held in memory, such as an image's filtered rows; it can't add to a stream a piece at a time.

`build.zig` fetches libdeflate as a dependency and compiles its compressor, its zlib wrapping, Adler-32 and the CPU feature detection, without the decompressor or gzip, optimized in every build mode, and translates `libdeflate.h` for Zig.

## Example

```zig
const libdeflate = @import("libdeflate");

const compressor: libdeflate.Compressor = try .init(.{ .level = 1 });
defer compressor.deinit();
const out = try allocator.alloc(u8, compressor.zlibBound(data.len));
defer allocator.free(out);
const stream = out[0..try compressor.compress(out, data)];
```

## API

| name | contents |
| --- | --- |
| `maxLevel` | the highest level, 12 |
| `Compressor.init(options)` | a compressor at `options.level`, with libdeflate's working memory: 6 KiB at level 0, 198 KiB at 1, 653 KiB at 2 to 9 and 8.6 MiB at 10 to 12; `error.OutOfMemory` if libdeflate can't allocate it |
| `Compressor.compress(out, data)` | compresses `data` into a zlib stream at the start of `out` and returns its length; `error.NoSpace` if it doesn't fit |
| `Compressor.zlibBound(bytes)` | the most a zlib stream of `bytes` bytes of data takes: an `out` this long always fits |
| `Compressor.deinit()` | frees libdeflate's working memory |
| `Options.level` | from 0, stored uncompressed, through 1, the fastest that compresses (the default), to 12, the smallest |
