# TODO

storymap renders Vintage Story saves as a **top-down map** and a **Mapcrafter-style isometric render**. Format knowledge lives in [`docs/save-format/README.md`](docs/save-format/README.md) and renderer research in [`docs/rendering.md`](docs/rendering.md): record every finding there, with its source, as it's made.

## Assets

1. **Renderer reads assets** from `--game`/`--data` (the real folders, auto-discovered by default, or an `extract-assets` copy, which has the same layout). Mod zips are read in place.
2. **Mod settings.** Honour `modPaths` and `disabledMods` in the data folder's `clientsettings.json` instead of taking every mod in `<data>/Mods`.

## Top-down map

3. **Colour map.** Read liquids (chunk field 16), look under snow, colour per block (the game's `mapColorCode` palette or the average texture colour) and add hill shading, as the game's own map does ([`docs/rendering.md`](docs/rendering.md)). Block names come from `GameData`. Plants such as tall grass are often the top block (up to 15% of columns); decide whether to look through them.
4. **Height from `mapchunk`.** Decode the stored rain height map, if it's there, instead of scanning every block.
5. **Tiles with levels of detail** instead of one image: per chunk or per map region, at several resolutions for the map viewer ([`docs/rendering.md`](docs/rendering.md#output-tiles-and-levels-of-detail)). Writing one big PNG is two-thirds of a large map's render time today; per-tile images bound that.
6. **Measure on a large world.** Threaded decoding barely shows on the small test worlds; confirm it scales on a save with many more chunks.

## Memory

No allocation at runtime, TigerBeetle style ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)). Stage 1, no allocation per chunk, is done.

7. **Fixed tile buffers,** one per worker, as part of the tiles item above.
8. **Enforcement.** An allocator that refuses to allocate after startup; SQLite on a fixed block (`SQLITE_ENABLE_MEMSYS5`); stb's memory functions on a fixed buffer.

## Block entities

9. **Chiseled blocks in the top-down map.** Top voxel per 16 × 16 sub-column, coloured by its material. The cuboids are already parsed (`BlockEntity.attributes`).
10. **Item stacks.** Decode what a stack's class and id refer to (needed for ground storage and containers).

## Isometric render

11. **Block models.** Resolve block-type variants, load shapes and textures from the extracted assets, apply climate tinting, render isometric tiles.
12. **Block entities in 3D.** Chiseled blocks first (pure data), then ground storage (needs item stacks and item models), then containers, displays and decorations.

## Format coverage

13. **Chiseled blocks and ground storage on 1.22.7.** The 1.22.7 test world has neither; it needs a world with ruins (or a placed chiseled block) and items on the ground.
14. **A modded world.** Primitive Survival is installed but was added after the test world was made. When modded content becomes relevant (asset extraction for mods, the ID mapping), ask for a new world created with it enabled.

## Done

- Zig 0.17.0 upgrade, SQLite built from the amalgamation (`35484a3`).
- Palette over-read fix (`092de71`).
- Blocks decoded from bit planes; greyscale top-down heightmap (`a314adf`).
- Save format docs and interactive explainer (`e900272`, then the restructure into `docs/save-format/`).
- Save path and output path as command-line arguments.
- Tree attribute parser: every block entity in the 1.19 sample parses (`src/TreeAttribute.zig`).
- Saves opened with SQLite's `immutable=1`, so storymap never writes next to them; a warning if the game may still be running.
- `storymap extract-assets`: copies blocktypes, itemtypes, shapes, textures (minus gui/icons), worldproperties, patches and `config/colormaps.json` (181 MB for 1.22.7) plus every mod, in the game's own layout. Verified byte-for-byte against the install.
- Block ID → block code mapping from `gamedata` (`src/GameData.zig`); every ID in both test saves has a name.
- No allocation per chunk (memory stage 1): one `Chunk.Decoder` and one fixed-size `Chunk` per worker, reused for every chunk ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)).
- Sepia relief map: pale at ground level (the median height), darker below, paler above, with hill shading.
- Chunk decoding on every core, one SQLite connection per worker; timings in [`docs/rendering.md`](docs/rendering.md#performance).
- Format checked against 1.22.7: schema, positions, chunk fields, block and liquid decoding and block entities all hold; differences are noted in the docs.
