# Performance

How fast each tagged version of Storymap renders, measured as in [Measuring](#measuring). Each table is one save, measured in one sitting on one machine, so its rows compare. Across saves the numbers don't: a render has a fixed cost of about 60 ms, which weighs more in a small world.

## Vintage Story 1.22.7

A world of 29,192 chunks, 2.79 km², 256 blocks high, the game's default height, which nearly every world has; so km²/s tells how fast a world of that height renders. Drawn top-down as 34 tiles in 5 levels, and isometric as 4,440 tiles in 9 levels. Intel Xeon E3-1270 v6, 4 cores, 8 threads, Debian 13; tiles written (`--write`); measured 2026-11-15 (UTC).

The isometric view alone, with the script's `--isometric`. Versions up to 0.2.0 have no isometric view of their own to measure.

| version | save | end to end | km²/s | chunks/s | drawing | open | peak memory | changes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.3.0 | 442c9598fa0d | 10.066 s | 0.28 | 2900 | 10.039 s | 0.009 s | 253 MiB | – |

The top-down view. Versions up to 0.2.0 report no times of their own, so their drawing and open aren't measured (see [Measuring](#measuring)).

| version | save | end to end | km²/s | chunks/s | drawing | open | peak memory | changes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.3.0 | 442c9598fa0d | 0.246 s | 11.34 | 118443 | 0.220 s | 0.009 s | 146 MiB | PNG rows filtered with vector instructions, and tiles compressed with libdeflate instead of std's flate |
| 0.2.0 | 442c9598fa0d | 0.408 s | 6.85 | 71580 | – | – | 146 MiB | a PNG encoder of its own, set up once per worker, instead of stb_image_write, which allocated for every tile |
| 0.1.0 | 442c9598fa0d | 0.470 s | 5.95 | 62168 | – | – | 146 MiB | – |

## Measuring

From the project's folder:

```bash
zig run scripts/benchmark.zig -- <save-file> --write --game <folder> --data <folder>
```

[`scripts/benchmark.zig`](../scripts/benchmark.zig) checks out each `v*` tag into its own worktree in `.benchmark/`, builds it with `-Doptimize=ReleaseFast`, prepares its blocks with its own `prepare` if they aren't prepared yet, and renders the save 7 times after one untimed run, as `storymap <save-file>` with `--json` if the version has it, taking the median of each time. It prints a table row for each version, newest first, then the save, the world, the machine and each version's time per part of the tile pipeline, summed over all workers: drawing, filtering and compressing the PNGs, writing them and shrinking tiles for the levels above.

| option | effect |
| --- | --- |
| `--tag v0.1.0` | measures only the tags given; repeatable |
| `--current` | adds the working tree |
| `--runs <n>` | renders each version n times, 7 by default |
| `--isometric` | draws the isometric view alone instead (`--views isometric`), in a table of its own; versions without `--views` are left out |
| `--write` | writes the tiles into `.benchmark/out`, removed before each run, so writing them is timed too; without it, versions up to 0.2.0 are left out, as they render only with their tiles written |
| `--jpegxl` | encodes the tiles as JPEG XL instead of PNG |
| `--webp` | encodes the tiles as WebP instead of PNG |
| `--lossy-from <level>` | with `--webp`, encodes the tiles from this level up as lossy WebP |
| `--game <folder>`, `--data <folder>` | the game's install and data folders, for preparing each version's blocks into `.benchmark/<tag>.storyblk`, or `.benchmark/<tag>.blocks/` for versions up to 0.2.0; renders don't look for the game, so they don't hash its assets |

Each tag is built by the Zig release its `build.zig.zon` names. The script looks for it in `.benchmark/zig/`, or in `--zigs <folder>`, as its archive unpacks (`zig-x86_64-windows-0.17.0/`), and downloads it there from ziglang.org if it's missing.

| column | contents |
| --- | --- |
| save | the first 12 hex digits of the save file's SHA-256 |
| end to end | a whole render, from starting the process to its exit: loading the prepared blocks, opening the save, then every tile, its PNGs written with `--write` |
| km²/s | the world's area per second, end to end: the area the top-down view draws, for both views |
| chunks/s | all the save's chunks per second, end to end, though only those holding the surface are read for the top-down view |
| drawing | the view's tiles: drawing, encoding and building the zoomed-out levels, with the PNGs written with `--write` |
| open | opening the save, its block list and which tiles it has, and giving it the prepared blocks |
| peak memory | the most memory a render held at once (Windows' peak working set, elsewhere the peak resident set) |
| changes | what made a version much faster than the one before; written by hand, as the script doesn't know |

- **Styles:** every version draws the slowest styles, the Plain theme's with `game:coloured` top-down, from blocks prepared by its own `prepare`.
- **Versions up to 0.2.0** have no `--json` and no `--no-write`: the script times their whole render, which always writes its tiles, and their drawing and open are "–". Their km²/s and chunks/s take the save's area and chunk count from a version that reports them. They have no isometric view.
- **Runs:** each time is the median of 7 renders after one untimed one. On the world above, the median of 7 consecutive runs stays within 3% of the next 7; 9 runs is no closer, and 3 or 5 are 5–6% apart.
- **Sittings:** on a laptop, the same build measures up to 8% apart at different times, with the machine's heat, power plan and background work; on a machine doing nothing else, two sittings an hour apart came within 1.3% of each other. So a table is measured in one sitting, and on a laptop a difference under about 5% between rows isn't a change.
- **Small maps:** a render's fixed startup cost of about 60 ms is most of a very small map's time, so its km²/s and chunks/s come out low, and a few milliseconds of noise move them a lot. A table's save should be a large world.
- **A new version:** measure every tag in the newest table, the new one included, on its save and machine, and replace the table's rows.
- **A new save,** usually for a new game version: start a new table, measuring every tag that reads that game version (`--tag`).
