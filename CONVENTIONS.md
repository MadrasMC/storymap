# Conventions

How code in this project is written. Applies to everyone and every tool working on it.

## Keeping the game apart

Everything that knows Vintage Story, its save format, its assets and its block names, lives in `src/vs/`. The renderers, the tile pipeline, the viewer and `src/columns.zig` don't import it: a game's reader tells the renderers what's on top of each block column (`columns.zig`), and they draw from that alone, so another game could be read the same way. Only `main.zig` and `bench.zig`, which put the program together, import both.

## Zig conventions

### Parameter order

Context first, then the real arguments:

1. the receiver (`self`, or the `Dir`/`File` being acted on), and `comptime` type parameters
2. the allocator
3. `io`
4. the function's own arguments
5. an options struct, if any
6. an out-parameter reporting on the call, if any: a `*Problem` saying what went wrong, or `*Stats`

```zig
fn copyAssets(gpa: std.mem.Allocator, io: Io, assetsDir: Dir, outAssets: Dir) !usize
pub fn parse(text: []const u8, problem: *Problem) error{InvalidStyle}!File
```

A buffer the result is written into isn't one of these: like std's `bufPrint(buffer, ...)`, it comes first, as what the function acts on.

This matches the standard library, which mostly puts the allocator before `io` and both before the arguments (`dir.openDir(io, path, options)`), so our calls and std's read the same way.

### Memory

The goal is no allocation after startup ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)). New code in the per-chunk and per-tile paths takes buffers sized at startup instead of allocating; sizes come from the save, the installed mods or configured limits. Existing code is being moved there (see `TODO.md`).

### Naming allocator parameters

Name an allocator parameter `arena` only when the function relies on arena semantics: it allocates and never frees individually (intermediate lists, partial results on error). Otherwise name it `allocator`, or `gpa` when it frees what it allocates.

Whether the caller happens to pass an arena doesn't matter; the name describes what the function needs. Prefer results the caller can always free: return `null` and let the caller pick a fallback, rather than returning a static string from a function that otherwise allocates.
