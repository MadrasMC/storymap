# storymap

High Performance Vintage Story Map Renderer ⚡️

storymap renders a greyscale top-down heightmap today; colour, tiles and an isometric render are next ([TODO.md](TODO.md)). Tested on saves from Vintage Story 1.19 and 1.22.7.

To render a top-down heightmap of a save (Zig 0.17.0):

```bash
zig build run -- path/to/save.vcdbs [output.png]
```

The image goes to `out.png` when no output path is given. Saves are in the game's data folder, under `Saves/`. storymap never writes next to a save.

To copy the game assets the renderer needs (block types, shapes, textures) from your own Vintage Story install and mods into a folder, for example to render on a machine without the game:

```bash
zig build run -- extract-assets path/to/output [--game <install folder>] [--data <data folder>]
```

The output mirrors the game's own layout (`game/assets/...` and `data/Mods/...`). `--game` and `--data` default to the standard locations. storymap never ships the game's assets.

## Save format

[`docs/save-format/README.md`](docs/save-format/README.md) documents the `.vcdbs` format as far as storymap has worked it out: the SQLite schema, chunk positions, the Protobuf chunk fields, block palettes and bit planes, and block entities. Every claim is marked with its source: verified against a real save, read in the game's open-source code, from the wiki, or unverified.

## Performance

A render of a 1.22.7 world (6,224 chunks, a 3,232 × 4,224 image), ReleaseFast on a 14-thread machine:

| Stage | Time |
| --- | --- |
| Decoding all chunks | 0.09 s (70,000 chunks/s) |
| Finding each column's top block, with decoding | 0.14 s |
| Shading the pixels and encoding the PNG | 0.64 s |
| End to end | 0.80 s |

To measure your own save:

```bash
zig build bench -Doptimize=ReleaseFast -- path/to/save.vcdbs [runs]
```

More numbers and what they mean: [`docs/rendering.md`](docs/rendering.md#performance).

## License

MIT, see [LICENSE](LICENSE).
