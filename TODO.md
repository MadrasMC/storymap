# TODO

storymap renders Vintage Story saves as a **top-down map** and a **Mapcrafter-style isometric render**. Format knowledge lives in [`docs/save-format/README.md`](docs/save-format/README.md) and renderer research in [`docs/rendering.md`](docs/rendering.md): record every finding there, with its source, as it's made.

## Next

1. **Save path as a command-line argument.** `zig build run -- my-save.vcdbs`, as the README already says. The path is hard-coded in `src/main.zig` today.
2. **Asset extraction from the user's own game install.** A flag or subcommand that takes the game folder (and mod folders) and extracts the block types, shapes and textures the renderer needs into a local cache. storymap never ships the game's assets; every user supplies their own copy, which also makes modded content render correctly. Needs a real install to confirm where assets and mods live.
3. **Block ID → block code mapping.** Palettes and chiseled-block materials hold numeric IDs; the mapping is probably in `gamedata`. Everything with names, colours or models depends on this.

## Top-down map

4. **Colour map.** Read liquids (chunk field 16), look under snow, colour per block (the game's `mapColorCode` palette or the average texture colour) and add hill shading, as the game's own map does ([`docs/rendering.md`](docs/rendering.md)).
5. **Height from `mapchunk`.** Decode the stored rain height map, if it's there, instead of scanning every block.

## Block entities

6. **Tree attribute parser in Zig.** Replace the hard-coded offsets in `src/BlockEntity.zig` with the general format from [README §5](docs/save-format/README.md#5-block-entities-field-8).
7. **Chiseled blocks in the top-down map.** Top voxel per 16 × 16 sub-column, coloured by its material.

## Isometric render

8. **Block models.** Resolve block-type variants, load shapes and textures from the extracted assets, apply climate tinting, render isometric tiles.
9. **Block entities in 3D.** Chiseled blocks first (pure data), then ground storage (needs item stacks and item models), then containers, displays and decorations.

## Format coverage

10. **Check against 1.22.7.** Decode a current save and record every difference inline in the docs as a **1.22:** note.

## Done

- Zig 0.17.0 upgrade, SQLite built from the amalgamation (`1162659`).
- Palette over-read fix (`12219e3`).
- Blocks decoded from bit planes; greyscale top-down heightmap (`f9dc6e3`).
- Save format docs and interactive explainer (`aebadc2`, then the restructure into `docs/save-format/`).
