# TODO

storymap renders Vintage Story saves as a **top-down map** and a **Mapcrafter-style isometric render**. Format knowledge lives in [`docs/save-format/README.md`](docs/save-format/README.md) and renderer research in [`docs/rendering.md`](docs/rendering.md): record every finding there, with its source, as it's made.

## Next

1. **Block ID → block code mapping.** Palettes and chiseled-block materials hold numeric IDs; the mapping is probably in `gamedata`. Everything with names, colours or models depends on this.

## Assets

2. **Renderer reads assets** from `--game`/`--data` (the real folders, auto-discovered by default, or an `extract-assets` copy, which has the same layout). Mod zips are read in place.
3. **Mod settings.** Honour `modPaths` and `disabledMods` in the data folder's `clientsettings.json` instead of taking every mod in `<data>/Mods`.

## Top-down map

4. **Colour map.** Read liquids (chunk field 16), look under snow, colour per block (the game's `mapColorCode` palette or the average texture colour) and add hill shading, as the game's own map does ([`docs/rendering.md`](docs/rendering.md)).
5. **Height from `mapchunk`.** Decode the stored rain height map, if it's there, instead of scanning every block.

## Block entities

6. **Chiseled blocks in the top-down map.** Top voxel per 16 × 16 sub-column, coloured by its material. The cuboids are already parsed (`BlockEntity.attributes`).
7. **Item stacks.** Decode what a stack's class and id refer to (needed for ground storage and containers).

## Isometric render

8. **Block models.** Resolve block-type variants, load shapes and textures from the extracted assets, apply climate tinting, render isometric tiles.
9. **Block entities in 3D.** Chiseled blocks first (pure data), then ground storage (needs item stacks and item models), then containers, displays and decorations.

## Format coverage

10. **Chiseled blocks and ground storage on 1.22.7.** The 1.22.7 test world has neither; it needs a world with ruins (or a placed chiseled block) and items on the ground.
11. **A modded world.** Primitive Survival is installed but was added after the test world was made. When modded content becomes relevant (asset extraction for mods, the ID mapping), ask for a new world created with it enabled.

## Done

- Zig 0.17.0 upgrade, SQLite built from the amalgamation (`1162659`).
- Palette over-read fix (`12219e3`).
- Blocks decoded from bit planes; greyscale top-down heightmap (`f9dc6e3`).
- Save format docs and interactive explainer (`aebadc2`, then the restructure into `docs/save-format/`).
- Save path and output path as command-line arguments.
- Tree attribute parser: every block entity in the 1.19 sample parses (`src/TreeAttribute.zig`).
- Saves opened with SQLite's `immutable=1`, so storymap never writes next to them; a warning if the game may still be running.
- `storymap extract-assets`: copies blocktypes, itemtypes, shapes, textures (minus gui/icons), worldproperties, patches and `config/colormaps.json` (181 MB for 1.22.7) plus every mod, in the game's own layout. Verified byte-for-byte against the install.
- Format checked against 1.22.7: schema, positions, chunk fields, block and liquid decoding and block entities all hold; differences are noted in the docs.
