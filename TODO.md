# TODO

storymap renders Vintage Story saves as a **top-down map** and a **Mapcrafter-style isometric render**. Format knowledge lives in [`docs/save-format/README.md`](docs/save-format/README.md) and renderer research in [`docs/rendering.md`](docs/rendering.md): record every finding there, with its source, as it's made.

## Assets

1. **Renderer reads assets** from `--game`/`--data` (the real folders, auto-discovered by default, or an `extract-assets` copy, which has the same layout). Mod zips are read in place.
2. **Mod settings.** Honour `modPaths` and `disabledMods` in the data folder's `clientsettings.json` instead of taking every mod in `<data>/Mods`.

## Top-down map

3. **Colour map.** Look under snow and through lily pads, colour per block (the game's `mapColorCode` palette or the average texture colour) and add hill shading, as the game's own map does ([`docs/rendering.md`](docs/rendering.md)). Block names come from `GameData`.
4. **Levels of detail and a viewer** ([`docs/rendering.md`](docs/rendering.md#output-tiles-and-levels-of-detail)): zoomed-out levels built bottom-up from level 0 (averaging 2 × 2 pixels, weighted by transparency), then `map.json` describing each view, then a viewer page: our own, not a map library, with a projection per view so isometric views fit in later.
5. **Measure on a large world.** Threaded decoding barely shows on the small test worlds; confirm it scales on a save with many more chunks.

## Memory

No allocation at runtime, TigerBeetle style ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)). Stage 1, no allocation per chunk, is done.

6. **Fixed tile buffers** for the zoomed-out levels, one per worker; level-0 tiles already reuse theirs. The PNG encoder still allocates per tile.
7. **Enforcement.** An allocator that refuses to allocate after startup; SQLite on a fixed block (`SQLITE_ENABLE_MEMSYS5`); stb's memory functions on a fixed buffer.

## Block entities

8. **Chiseled blocks in the top-down map.** Top voxel per 16 × 16 sub-column, coloured by its material. The cuboids are already parsed (`BlockEntity.attributes`).
9. **Item stacks.** Decode what a stack's class and id refer to (needed for ground storage and containers).

## Isometric render

10. **Block models.** Resolve block-type variants, load shapes and textures from the extracted assets, apply climate tinting, render isometric tiles.
11. **Block entities in 3D.** Chiseled blocks first (pure data), then ground storage (needs item stacks and item models), then containers, displays and decorations.

## Format coverage

12. **Chiseled blocks and ground storage on 1.22.7.** The 1.22.7 test world has neither; it needs a world with ruins (or a placed chiseled block) and items on the ground.
13. **A modded world.** Primitive Survival is installed but was added after the test world was made. When modded content becomes relevant (asset extraction for mods, the ID mapping), ask for a new world created with it enabled.

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
- Sepia relief map: pale at sea level, darker below, paler above, with hill shading. Sea level comes from the world height ([save format §6](docs/save-format/README.md#sea-level)), so colours don't depend on the rest of the map: tiles will match, and different worlds look alike.
- Water from the liquid layer: shaded by depth, saltwater (seas) apart from other water, inked coastlines; water plants don't hide the water.
- Heights from `mapchunk`: the rain height map, so plants and loose stones don't hide the ground, and the terrain height for water depth. Block columns without a stored height, or whose stored height is out of date, are scanned.
- Only the chunks holding the surface are read, fetched by key: 1,244 of 6,224 in the 1.22.7 world ([`docs/rendering.md`](docs/rendering.md#performance)).
- Tiles: the top-down map is written as 512 × 512 tiles by a pipeline every view shares (`src/tiles.zig`), seamless across tile edges.
- Chunk decoding on every core, one SQLite connection per worker; timings in [`docs/rendering.md`](docs/rendering.md#performance).
- Format checked against 1.22.7: schema, positions, chunk fields, block and liquid decoding and block entities all hold; differences are noted in the docs.
