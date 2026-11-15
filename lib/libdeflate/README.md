# libdeflate

Deflate compression into zlib streams, for Zig 0.17: [libdeflate 1.26](https://github.com/ebiggers/libdeflate/tree/v1.26)'s compressor (MIT), with a patch that compresses a stream a chunk at a time. A `Compressor` is set up once, for one level; libdeflate allocates its working memory with `malloc` then, and nothing while compressing. It compresses a whole buffer in one call, which suits data held in memory, such as an image's filtered rows, or a stream in chunks, each compressed without the history of the ones before it, which suits data too large to hold, a band of an image's rows at a time.

`build.zig` fetches libdeflate as a dependency and compiles its compressor, its zlib wrapping, Adler-32, CRC-32 and the CPU feature detection, without the decompressor or gzip, optimized in every build mode, and translates `libdeflate.h` for Zig. Its `lib/deflate_compress.c` is replaced by the patched copy here.

## Patch

`deflate_compress.c` is libdeflate 1.26's `lib/deflate_compress.c` with `deflate_compress.patch` applied, which adds `libdeflate_deflate_compress_chunk`. libdeflate always ends what it writes with a final block, at a bit it doesn't say, so its outputs can't follow one another in one stream, as a PNG's `IDAT` chunks must. The patch:

- adds a `continues` field to the compressor, which keeps `deflate_flush_block` from marking any block final; how the data is split into blocks and matched is unchanged
- gives `deflate_compress_none`, which stores small inputs and everything at level 0, an `is_final` parameter
- adds `libdeflate_deflate_compress_chunk(compressor, in, in_nbytes, out, out_nbytes_avail, is_final)`: the final chunk is `libdeflate_deflate_compress`'s output; any other ends with an empty stored block, on a byte boundary, as zlib's `Z_SYNC_FLUSH` does

To move to another libdeflate release: apply the patch in its folder (`patch -p1 < deflate_compress.patch`), settle any part that doesn't apply, replace the copy here with the result, write the patch again against the new release (`diff -u a/lib/deflate_compress.c b/lib/deflate_compress.c`), and update the version in `build.zig.zon` and this README.

## Example

```zig
const libdeflate = @import("libdeflate");

const compressor: libdeflate.Compressor = try .init(.{ .level = 1 });
defer compressor.deinit();
const out = try allocator.alloc(u8, compressor.zlibBound(data.len));
defer allocator.free(out);
const stream = out[0..try compressor.compress(out, data)];
```

A stream in chunks is `zlibHeader`, each chunk, and the `adler32` of all their data, big-endian:

```zig
try writer.writeAll(&libdeflate.zlibHeader);
var adler: u32 = 1;
for (chunks, 0..) |chunk, i| {
    adler = libdeflate.adler32(adler, chunk);
    const length = try compressor.compressChunk(out, chunk, i == chunks.len - 1);
    try writer.writeAll(out[0..length]);
}
try writer.writeInt(u32, adler, .big);
```

## API

| name | contents |
| --- | --- |
| `maxLevel` | the highest level, 12 |
| `zlibHeader` | a zlib stream's first two bytes |
| `adler32(adler, data)` | a running Adler-32, which starts at 1, with `data` added |
| `crc32(crc, data)` | a running CRC-32, zlib's and PNG's, which starts at 0, with `data` added; with PCLMULQDQ where the processor has it |
| `Compressor.init(options)` | a compressor at `options.level`, with libdeflate's working memory: 6 KiB at level 0, 198 KiB at 1, 653 KiB at 2 to 9 and 8.6 MiB at 10 to 12; `error.OutOfMemory` if libdeflate can't allocate it |
| `Compressor.compress(out, data)` | compresses `data` into a zlib stream at the start of `out` and returns its length; `error.NoSpace` if it doesn't fit |
| `Compressor.zlibBound(bytes)` | the most a zlib stream of `bytes` bytes of data takes: an `out` this long always fits |
| `Compressor.compressChunk(out, data, last)` | compresses `data` as the next chunk of a deflate stream, at the start of `out`, and returns its length; unless it's the `last`, the stream goes on; `error.NoSpace` if it doesn't fit |
| `Compressor.chunkBound(bytes)` | the most `compressChunk` writes for `bytes` bytes of data |
| `Compressor.deinit()` | frees libdeflate's working memory |
| `Options.level` | from 0, stored uncompressed, through 1, the fastest that compresses (the default), to 12, the smallest |
