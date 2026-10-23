# Performance

How fast each tagged version of Storymap renders, measured as in [Measuring](#measuring). Each table is one save, measured in one sitting on one machine, so its rows compare. Across saves the numbers don't: a render has a fixed cost of about 60 ms, which weighs more in a small world.

## Vintage Story 1.22.7

A world of 29,192 chunks, 2.79 km² drawn as 34 tiles in 5 levels. Intel Core Ultra 5 225H, 14 threads, Windows 11; measured 2026-10-22 (UTC).

| version | save | end to end | km²/s | chunks/s | tiles | open |
| --- | --- | --- | --- | --- | --- | --- |
| 0.1.0 | 442c9598fa0d | 0.265 s | 10.6 | 110158 | 0.251 s | 0.014 s |

## Measuring

From the project's folder:

```bash
zig run scripts/benchmark.zig -- <save-file>
```

[`scripts/benchmark.zig`](../scripts/benchmark.zig) checks out each `v*` tag into its own worktree in `.benchmark/`, builds it with `-Doptimize=ReleaseFast` and runs `storymap bench <save-file> 7 --json`. It prints a table row for each, then the save, the world and the machine. `--tag v0.1.0` (repeatable) measures only the tags given, and `--current` adds the working tree.

Each tag is built by the Zig release its `build.zig.zon` names. The script looks for it in `.benchmark/zig/`, or in `--zigs <folder>`, as its archive unpacks (`zig-x86_64-windows-0.17.0/`), and downloads it there from ziglang.org if it's missing.

| column | contents |
| --- | --- |
| save | the first 12 hex digits of the save file's SHA-256 |
| end to end | a whole render: opening the save, then every tile, with the PNGs encoded but not written |
| km²/s | the map's area drawn per second, end to end |
| chunks/s | all the save's chunks per second, end to end, though only those holding the surface are read |
| tiles | drawing, encoding and the zoomed-out levels of every tile |
| open | opening the save: its block list and which tiles it has |

- **Runs:** each time is the median of 7 renders after one untimed one. On the world above, the median of 7 consecutive runs stays within 3% of the next 7; 9 runs is no closer, and 3 or 5 are 5–6% apart.
- **Sittings:** the same build measures up to 8% apart at different times, with the machine's heat, power plan and background work. So a table is measured in one sitting, and a difference under about 5% between rows isn't a change.
- **Small maps:** a render's fixed startup cost of about 60 ms is most of a very small map's time, so its km²/s and chunks/s come out low, and a few milliseconds of noise move them a lot. A table's save should be a large world.
- **A new version:** measure every tag in the newest table, the new one included, on its save and machine, and replace the table's rows.
- **A new save,** usually for a new game version: start a new table, measuring every tag that reads that game version (`--tag`).
