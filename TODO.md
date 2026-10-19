# TODO

Storymap renders Vintage Story saves as a **top-down map** and a **Mapcrafter-style isometric render**. Format knowledge lives in [`docs/save-format/README.md`](docs/save-format/README.md) and renderer research in [`docs/rendering.md`](docs/rendering.md): record every finding there, with its source, as it's made.

## Top-down map

1. **Climate and season tint for `style coloured`.** Grass, leaves and water have grey textures that the game tints by the climate where they are and by the season, through the colour maps in `config/colormaps.json` ([`docs/rendering.md`](docs/rendering.md#how-the-game-draws-its-own-world-map)). Needs each block's colour maps when preparing, and the climate from the map regions when rendering. The colour-accurate test world's map cache can check it.
2. **Incremental rendering.** Re-render only the tiles whose chunks changed since the last render, and the zoomed-out tiles above them, instead of the whole world every time.
3. **Measure on a large world.** Threaded decoding barely shows on the small test worlds; confirm it scales on a save with many more chunks.

## Memory

No allocation at runtime, TigerBeetle style ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)). Stage 1, no allocation per chunk, is done.

4. **Fixed buffers throughout.** Tiles already reuse per-worker buffers, and every waiting half is set aside before any work starts, but those are sized and allocated per render, and the PNG encoder allocates per tile.
5. **Enforcement.** An allocator that refuses to allocate after startup; SQLite on a fixed block (`SQLITE_ENABLE_MEMSYS5`); stb's memory functions on a fixed buffer.

## Block entities

6. **Chiseled blocks in the top-down map.** Top voxel per 16 × 16 sub-column, coloured by its material. The cuboids are already parsed (`BlockEntity.attributes`).
7. **Item stacks.** Decode what a stack's class and id refer to (needed for ground storage and containers).

## Isometric render

8. **Block models.** Resolve block-type variants, load shapes and textures from the extracted assets, apply climate tinting, render isometric tiles.
9. **Block entities in 3D.** Chiseled blocks first (pure data), then ground storage (needs item stacks and item models), then containers, displays and decorations.

## Done

- Zig 0.17.0 upgrade, SQLite built from the amalgamation (`35484a3`).
- Palette over-read fix (`092de71`).
- Blocks decoded from bit planes; greyscale top-down heightmap (`a314adf`).
- Save format docs and interactive explainer (`e900272`, then the restructure into `docs/save-format/`).
- Save path and output path as command-line arguments.
- Tree attribute parser: every block entity in the 1.19 sample parses (`src/vs/TreeAttribute.zig`).
- Saves opened with SQLite's `immutable=1`, so Storymap never writes next to them; a warning if the game may still be running.
- `storymap extract-assets`: copied blocktypes, itemtypes, shapes, textures (minus gui/icons), worldproperties, patches and `config/colormaps.json` (181 MB for 1.22.7) plus every mod, in the game's own layout. Since replaced by preparing blocks.
- Block ID → block code mapping from `gamedata` (`src/vs/GameData.zig`); every ID in both test saves has a name.
- No allocation per chunk (memory stage 1): one `Chunk.Decoder` and one fixed-size `Chunk` per worker, reused for every chunk ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)).
- Sepia relief map: pale at sea level, darker below, paler above, with hill shading. Sea level comes from the world height ([save format §6](docs/save-format/README.md#sea-level)), so colours don't depend on the rest of the map: tiles will match, and different worlds look alike.
- Water from the liquid layer: shaded by depth, saltwater (seas) apart from other water, inked coastlines; water plants don't hide the water.
- Heights from `mapchunk`: the rain height map, so plants and loose stones don't hide the ground, and the terrain height for water depth. Block columns without a stored height, or whose stored height is out of date, are scanned.
- Only the chunks holding the surface are read, fetched by key: 1,244 of 6,224 in the 1.22.7 world ([`docs/rendering.md`](docs/rendering.md#performance)).
- Tiles: the top-down map is written as 512 × 512 tiles by a pipeline every view shares (`src/tiles.zig`), seamless across tile edges, with zoomed-out levels up to a single tile.
- Only fully generated chunk columns (world-generation stage 6, Done) are drawn, like the game's own map: the rings of partly generated columns around them are left out ([save format §7](docs/save-format/README.md#world-generation-stages)).
- A viewer: `index.html` and `map.json` written beside the tiles; one page without libraries, panning and zooming with the mouse, touch and keyboard ([`docs/rendering.md`](docs/rendering.md#output-tiles-and-levels-of-detail)).
- The viewer's positions match the game's, relative to the world's centre: checked roughly at the spot where a player first spawned ([save format §2](docs/save-format/README.md#2-positions)).
- Themes: the page around the map is drawn by a theme, chosen with `--theme`: `printed`, `plain` or a folder of your own ([`docs/themes.md`](docs/themes.md)).
- Chunk decoding on every core, one SQLite connection per worker; timings in [`docs/rendering.md`](docs/rendering.md#performance).
- Format checked against 1.22.7: schema, positions, chunk fields, block and liquid decoding and block entities all hold; differences are noted in the docs.
- Chiseled blocks and ground storage checked on 1.22.7, in the larger test world's ruins: every block entity parses, every cuboid decodes, and the new keys are documented ([save format §5](docs/save-format/README.md#chiseled-blocks-microblock-chisel)).
- Assets read in place from `--game`/`--data` (found in the standard locations by default): files read by path or listed by folder, mod zips read without unpacking, mods replacing the game's files ([`docs/rendering.md`](docs/rendering.md#reading-them)).
- Preparing blocks, as Mapcrafter's Blockcrafter does: every block type of the game and mods expanded into the block codes the game makes, exactly those in the test saves, kept in a blocks folder (`blocks` in the current folder by default), one set per game version and mods; a render prepares on demand (`--prepare` to force, `storymap prepare` alone) and reports blocks the save has that the game and mods don't ([`docs/rendering.md`](docs/rendering.md#preparing-blocks)).
- Map colours from the theme's `topdown/style.txt`: a colour per map type, drawn as a relief (Printed) or shaded as the game draws its own map (plain, with the game's colours), the shaded style matching the game's own map cache on 99.65% of a test world's pixels ([`docs/themes.md`](docs/themes.md#map-colours), [`docs/rendering.md`](docs/rendering.md#how-the-game-draws-its-own-world-map)).
- `style coloured`, the game's colour-accurate map without its tint: each block's texture colours worked out when preparing, with grain picked by the game's position hash, and its hill shading ([`docs/rendering.md`](docs/rendering.md#texture-colours)).
- A modded world: the larger 1.22.7 test world was created with Primitive Survival. Mods' block and item codes carry their domain, and their IDs follow the game's ([save format §6](docs/save-format/README.md#block-and-item-ids)).
