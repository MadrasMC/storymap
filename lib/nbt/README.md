# nbt

A reader for [NBT](https://minecraft.wiki/w/NBT_format), the binary format of Minecraft's saves, for Zig 0.17.
It reads uncompressed NBT in place: nothing is allocated or copied, and strings and arrays are slices of the data, so the data must outlive them.

Every read is bounds-checked, so truncated or corrupt data is an error, not a crash.

## Example

```zig
const nbt = @import("nbt");

const root = try nbt.parse(data);
const version = (try root.get("DataVersion")).?.int;
var sections = (try root.get("sections")).?.list.iterator();
while (try sections.next()) |section| {
	const y = (try section.compound.get("Y")).?.byte;
}
```

## API

| name | contents |
| --- | --- |
| `parse(bytes)` | the root `Compound` |
| `Compound` | `get(name)`, the field of that name or null, and `iterator()`, yielding each `Field`'s `name` and `value` |
| `List` | `tag`, `count` and `iterator()`, yielding each `Value` |
| `Array(T)` | `len()` and `get(i)`, reading a big-endian integer where it lies |
| `Value` | a union by `Tag`: `byte`, `short`, `int`, `long`, `float`, `double`, `byteArray`, `string`, `list`, `compound`, `intArray`, `longArray` |
| `Error` | `EndOfData`, `UnknownTag`, `InvalidLength`, `TooDeep`, `NotCompound` |
| `maxDepth` | how deep values can nest, 512 |

`get` walks the compound's fields each time, so a field read often is better kept than asked for again.
Strings are Java's modified UTF-8, as stored.
