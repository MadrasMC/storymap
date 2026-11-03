# lz4

A decoder for [LZ4's block format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) for Zig 0.17, and for the stream of blocks that lz4-java's `LZ4BlockOutputStream` writes.
It decodes into a buffer the caller provides and allocates nothing.

Every read and write is bounds-checked, so corrupt data is an error, not a crash.
Checksums aren't compared.

## Example

```zig
const lz4 = @import("lz4");

const length = try lz4.decompressStream(buffer, stream);
const text = buffer[0..length];
```

## API

| name | contents |
| --- | --- |
| `decompressBlock(out, block)` | decodes one block into `out`, returning the bytes written |
| `decompressStream(out, stream)` | decodes an lz4-java stream into `out`, returning the bytes written |
| `Error` | `InvalidData`, `OutputTooLong` |

LZ4's frame format, which the `lz4` command line tool writes, isn't supported.
