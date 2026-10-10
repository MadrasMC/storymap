# storymap

High Performance Vintage Story Map Renderer ⚡️

This project is early WIP.

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
