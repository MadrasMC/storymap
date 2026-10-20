# protobuf

A minimal reader for the [Protobuf wire format](https://protobuf.dev/programming-guides/encoding/) for Zig 0.17, without a schema: it returns each field's number and value, and what the fields mean is up to the program. The module is the reader type itself.

Every read is bounds-checked, so truncated or corrupt data is an error, not a crash.

## Example

```zig
const ProtoBuf = @import("protobuf");

var reader: ProtoBuf = .{ .buf = data };
while (try reader.next()) |field| switch (field.data) {
    .VARINT => |value| if (field.field_number == 1) count = value,
    .LEN => |bytes| if (field.field_number == 2) name = bytes,
    else => {},
};
```

## API

| name | contents |
| --- | --- |
| `buf`, `cur` | the data, and the position of the next read |
| `next()` | the next field as a `Message`, or null at the end of the data |
| `parseVarInt()` | reads a varint at the current position |
| `Message` | `field_number`, and `data`: `VARINT`, `LEN` (the bytes, for strings and nested messages), `I64` or `I32` |
| `Error` | `EndOfData`, `InvalidVarint` (longer than 10 bytes), `UnsupportedWireType` (groups, or wire types 6 and 7) |

Nested messages are read with a reader of their own over the `LEN` bytes.
