# Conventions

How code in this project is written. Applies to everyone and every tool working on it.

## Modules

Each folder in `src/` and `lib/` is a module of its own in `build.zig`, with a root file of the folder's name (`src/vs/vs.zig`), imported by name (`@import("vs")`). A module can import only the modules `build.zig` gives it, and no file outside its folder, so the compiler checks the rules below. Within a module, files import each other by path.

| module | imports |
| --- | --- |
| `tiles` | – |
| `world` | `tiles` |
| `theme` | `world` |
| `viewer` | `tiles`, `theme`, `world` |
| `console` | – |
| `renderer` | `world`, `tiles`, `theme` |
| `vs` | `world`, `tiles`, `sqlite`, `protobuf` |
| `cli` | `vs`, `renderer`, `viewer`, `theme`, `console`, `sqlite`, `args` |

`main.zig` only imports `cli`, `console` and `args`.

## Keeping the game apart

Everything that knows Vintage Story, its save format, its assets and its block names, lives in `vs`. The renderers, the tile pipeline, the viewer and `world` don't import it: a game's reader tells them what they need to know about its world (`world`): what's on top of each block column, how each block appears on a map, and the world's name and heights. They draw from that alone, so another game could be read the same way. Only the commands in `cli`, which put the program together, import both.

## Libraries

`lib/` holds libraries that know nothing of Storymap: `args` for command lines, `sqlite` and `protobuf`. Each has its own README. Anything about Storymap itself, such as how its messages read or when it exits, stays in Storymap: a library returns what happened and leaves the rest to the program.

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
