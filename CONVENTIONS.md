# Conventions

How code in this project is written. Applies to everyone and every tool working on it.

## Modules

Each folder in `src/` and `lib/` is a module of its own in `build.zig`, with a root file of the folder's name (`src/vs/vs.zig`), imported by name (`@import("vs")`). A module can import only the modules `build.zig` gives it, and no file outside its folder, so the compiler holds each module to its imports. Within a module, files import each other by path.

`build.zig` lists each module's imports. Before giving a module another, check it against these rules:

- **Each module does its own part:** `vs` reads the game, `world` holds what it tells the others about a world, `renderer` draws the views, `tiles` cuts and encodes tiles, `viewer` writes the page, `theme` loads themes, `console` writes messages, and `cli` puts them together into commands. A module that needs another's part done hands over what it has instead of importing that module to do it: the renderers return their stats, and `cli` prints them.
- **The game at arm's length:** only `vs`, and `cli` putting the program together, know the game ([Keeping the game apart](#keeping-the-game-apart)).
- **Libraries know nothing of Storymap** ([Libraries](#libraries)), so they import no module of `src/`.
- **`main.zig`** only picks the command from the command line and runs it from `cli`.

## Keeping the game apart

Everything that knows Vintage Story, its save format, its assets and its block names, lives in `vs`. The renderers, the tile pipeline, the viewer and `world` don't import it: a game's reader tells them what they need to know about its world (`world`): what's on top of each block column, what each block is on a map, and the world's name and heights. They draw from that alone, so another game could be read the same way. How a game draws its own maps is knowledge about the game too, so the game's reader draws those (`vs/MapPainter.zig`), and the renderer only draws Storymap's own relief map. Only the commands in `cli`, which put the program together, import both.

## Libraries

`lib/` holds libraries that know nothing of Storymap: `args` for command lines, `png`, `jxl`, `webp`, `sqlite` and `protobuf`. Each has its own README. Anything about Storymap itself, such as how its messages read or when it exits, stays in Storymap: a library returns what happened and leaves the rest to the program.

## Versions

`minimum_zig_version` in `build.zig.zon` is the exact Zig release that must be used to build Storymap. Only tagged Zig releases must be used; not master. `scripts/benchmark.zig` uses this property to reproduce Storymap versions with the exact Zig version for consistency of benchmarks.

Switching to a new Zig release must cause a Storymap version bump in `build.zig.zon`.

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

### Messages

Storymap writes everything through `console`. Libraries in `lib/` don't import it (see "Libraries").

| function | use | output |
| --- | --- | --- |
| `console.log` | what the program did: status lines (`blocks: …`), render summaries | stderr |
| `console.warn` | something skipped or missing from the map, as the program carries on | stderr, after `storymap: ` |
| `console.err` | an error the program carries on from | stderr, after `storymap: ` |
| `console.fail` | an error that stops the program, with exit status 1 | stderr, after `storymap: ` |
| `console.print` | a command's results, such as `--json`'s and `--version`'s | stdout, as is |

Write a message without the `storymap: ` prefix or a trailing newline: `console.logFn`, the program's `std_options.logFn` in `main.zig`, adds them.

`log`, `warn`, `err` and `fail` go through `std.log`, so in tests they reach the test runner instead. It fails a test that logs an error, holds back `log`'s messages, and prints warnings. `zig build test` shows whatever a passing test writes to stderr under its step, the way it shows a failure, so a test that causes a warning on purpose sets `std.testing.log_level = .err` and restores `.warn` with `defer`. The test runner doesn't reset it between tests.
