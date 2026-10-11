# Conventions

How code in this project is written. Applies to everyone and every tool working on it.

## Zig conventions

### Parameter order

Context first, then the real arguments:

1. the receiver (`self`, or the `Dir`/`File` being acted on), and `comptime` type parameters
2. the allocator
3. `io`
4. the function's own arguments
5. an options struct, if any

```zig
fn copyAssets(gpa: std.mem.Allocator, io: Io, assetsDir: Dir, outAssets: Dir) !usize
```

This matches the standard library, which mostly puts the allocator before `io` and both before the arguments (`dir.openDir(io, path, options)`), so our calls and std's read the same way.

### Naming allocator parameters

Name an allocator parameter `arena` only when the function relies on arena semantics: it allocates and never frees individually (intermediate lists, partial results on error). Otherwise name it `allocator`, or `gpa` when it frees what it allocates.

Whether the caller happens to pass an arena doesn't matter; the name describes what the function needs. Prefer results the caller can always free: return `null` and let the caller pick a fallback, rather than returning a static string from a function that otherwise allocates.
