# storymap

High Performance Vintage Story Map Renderer ⚡️

This project is early WIP.

To render a top-down heightmap of a save (Zig 0.17.0):

```bash
zig build run -- path/to/save.vcdbs [output.png]
```

The image goes to `out.png` when no output path is given. Saves are in the game's data folder, under `Saves/`.
