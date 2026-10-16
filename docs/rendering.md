# Rendering notes

Research for storymap's two planned outputs: a **top-down map** and a **Mapcrafter-style isometric render**. The save format itself is documented in [`save-format/README.md`](save-format/README.md); sourcing conventions are the same as there.

## How the game draws its own world map

*(Source: [vsessentialsmod `Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs), the 1.22.7 code.)*

Per block column:

1. **Height:** `RainHeightMap[i]` from the column's map chunk: the top block that isn't rain-permeable.
2. **Block:** the block at that height, read from the fluid-or-solid layer, so water shows instead of the lake bed.
3. **Snow:** in the default mode, if the top block is snow, step one block down and use what's under it.
4. **Colour, default mode:** each block's `mapColorCode` attribute (falling back to a default per block material, then `land`) picks a colour from a small fixed palette (`hexColorsByCode`, e.g. `forest`, `lake`). Lake pixels next to non-lake pixels get a `wateredge` colour.
5. **Colour, "accurate" mode:** the block's average colour (`block.GetColor`) blended with a random texture colour (`GetRandomColor`, weight 0.6).
6. **Hill shading:** compare the height with the north-west, west and north neighbours; brighten slopes facing the light and darken the others, scaled by steepness; blur the shading, then multiply it into the colour. Lakes aren't shaded.

The game's map doesn't treat block entities specially: a chiseled block is coloured as whatever block sits at that position.

Seas and lakes are told apart by block: `saltwater` sets `mapColorCode: "ocean"`, while `water`, `rapidwater` and `boilingwater` set none and take the liquid default, and `lakeice` sets `"lake"`. *(Verified (1.22.7): `assets/survival/blocktypes/liquid/` in the install.)* Both test saves list `saltwater` in their block IDs but contain none: neither world reaches a sea.

storymap's top-down map scans blocks itself rather than reading map chunks. It reads both the solid layer (field 1) and the liquid layer (field 16) and shows a column as liquid when its highest liquid is at or above its highest solid block, ignoring solid blocks that share their place with a liquid. Those are water plants *(Verified (1.19, 1.22.7): at the water surface they're `seaweed`, `aquatic-*` (milfoil, crowfoot), reeds and tule)*, so the water shows and its depth reaches down to the ground. Lily pads (`waterlily`) sit on top of the water instead and still show as land.

## Assets

Blocks are defined by data files, not code *(Wiki)*:

- **Block types:** JSON in `blocktypes/`, with variant groups and per-variant properties. *([Wiki: Asset Type – BlockTypes](https://wiki.vintagestory.at/Modding:Asset_Type_-_BlockTypes))*
- **Shapes:** JSON in `shapes/`, normally made with the official Model Creator: boxes with per-face texture references, rotations and nested children. *([Wiki: Asset Type – Shapes](https://wiki.vintagestory.at/Modding:Asset_Type_-_Shapes))*
- **Textures:** PNG in `textures/`, referenced from block types and shapes by name. *([Wiki: Asset Type – Textures](https://wiki.vintagestory.at/Modding:Asset_Type_-_Textures))*

These are the game developers' copyrighted assets, so storymap never ships them: every user points storymap at their own game install (and mods) and storymap extracts what it needs. That's also the only way modded blocks render correctly.

Where they live *(Verified (1.22.7): a fresh Windows install)*:

- **Game install** (`%APPDATA%\Vintagestory` on Windows): `assets/<domain>/` with one folder per domain, `creative`, `game` and `survival`, each containing `blocktypes/`, `shapes/`, `textures/` and more. `assets/version-1.22.7.txt` names the version. The install's own `Mods/` folder holds only the built-in code (`VSSurvivalMod.dll`, `VSEssentials.dll`, `VSCreativeMod.dll`) and a `do_not_add_mods_here.txt`.
- **Data folder** (`%APPDATA%\VintagestoryData`): `Saves/`, and `Mods/` with user mods as zip files (e.g. `primitivesurvival_5.1.4.zip`). How a mod zip lays out its assets is still to be checked. There's also a `Maps/` folder with one small `.db` file per world, probably the client's world-map cache; not looked into.

### What the renderer needs from them

*(Verified (1.22.7): a read-only survey of the install and of `primitivesurvival_5.1.4.zip`.)*

The base game's `assets/` is 838 MB, mostly music (489 MB), world generation (70 MB), language files (39 MB) and sounds (35 MB), none of which a map needs. What block rendering touches:

| Folder | Size | Why |
| --- | --- | --- |
| `blocktypes/`, `itemtypes/` | 3 MB | Block and item definitions: shape, textures, variants, colour maps, `drawtype`. Items matter for ground storage and containers. |
| `shapes/` | 143 MB (block 70, entity 62, item 11) | Block and item models. 50 base-game block and item types reference `entity/` shapes or textures (boat figureheads, armour stands, fish), so `entity/` can't simply be skipped. |
| `textures/` | 54 MB (block 21, gui 18, entity 11, item 2, environment 1) | Block, item and entity textures; `environment/` holds the climate and season tint maps. `gui/` and `icons/` aren't needed. |
| `worldproperties/` | under 1 MB | Variant lists that block types load by name, e.g. `variantgroups: [{ code: "rock", loadFromProperties: "block/rockwithdeposit" }]` in `survival/blocktypes/stone/rock.json`. |
| `config/colormaps.json` | small | Maps colour map names used by block types (`climatePlantTint`, `seasonalGrass`, …) to textures in `textures/environment/`. Some block types also name separate `climateColorMapForMap` / `seasonColorMapForMap`, presumably for the world map. |
| `patches/` | small | JSON edits applied to other assets at load time. The base game's are gameplay settings; mods use them to change base-game blocks. |

**The JSON isn't standard JSON.** Asset files use unquoted keys and trailing commas, so a strict JSON parser (like Zig's `std.json`) rejects them; the renderer needs a lenient reader.

**Variant syntax:** block types generate one block per variant combination. Properties can be keyed by variant pattern (`texturesByType: { "rock-*": … }`, regex keys like `"@rock-(claystone|sandstone)"`), use `{rock}`-style placeholders, and a texture path ending in `*` means "all numbered alternates" (e.g. `block/stone/rock/{rock}*`).

### Mods

A mod is a zip in the data folder's `Mods/`, e.g. `primitivesurvival_5.1.4.zip`:

- `modinfo.json` at the top: `modid`, `name`, `version`, `type` (`code` here, so it also ships `primitivesurvival.dll`).
- `assets/<modid>/` with the same folder names as the base game (`blocktypes`, `shapes`, `textures`, `patches`, …), plus `compatibility/`, assets that apply only when another mod is present.
- Files in other domains, e.g. `assets/game/textures/` and `assets/game/lang/`, which override or add to the base game's assets.

## Block entities that change how things look

From the sample save (class counts in [`save-format/README.md` §5](save-format/README.md#5-block-entities-field-8)):

- **Chiseled blocks** (`MicroBlock`, `Chisel`): the shape is fully in the save as 16³-voxel cuboids with block-ID materials. Top-down: take the top voxel of each 16 × 16 sub-column. Isometric: draw the boxes with each material's texture. No model files needed.
- **Ground storage** (`GroundStorage`): item stacks placed on the ground (firewood, planks, ingots…). Needs item stack parsing and item models.
- **Containers, displays and decorations** (`GenericTypedContainer`, `Crate`, `DisplayCase`, `Tapestry`, `TorchHolder`, …): the base look comes from the block's own shape; contents and variants come from the block entity.

## Isometric reference

[Mapcrafter](https://github.com/mapcrafter/mapcrafter) renders Minecraft worlds as isometric tiles for a web map. It's the model for storymap's isometric output; its approach hasn't been studied in detail here yet.

## Output: tiles and levels of detail

storymap won't render a world as one image; today's single `out.png` is a stopgap. The output is a set of tiles for a map viewer, at several resolutions:

- **Tile unit:** a chunk (32 × 32 blocks) or a map region (16 × 16 chunk columns, 512 × 512 blocks, the same unit as the save's `mapregion` table). Which one is still to be decided.
- **Levels of detail:** each level halves the resolution of the one below, like a web map's zoom levels, so a zoomed-out view loads a few tiles that each cover many regions.
- **Fetching a tile's chunks:** a chunk's position is the table's row key (x in the low bits, then z, then y), so the chunks under one tile are a few range queries on that key, one per row of chunk columns and height.

Every tile has a fixed size, which is what makes the memory goal below possible.

## Memory: no allocation at runtime (goal)

Following [TigerBeetle's style](https://github.com/tigerbeetle/tigerbeetle/blob/1a90d33bed174fac26ace95f4f43e51019bbb89d/docs/TIGER_STYLE.md#safety) ("All memory must be statically allocated at startup"): everything is allocated once at startup, sized from the save, the installed mods and configured limits, and nothing is allocated per chunk or per tile. Memory use is then known up front, a render can't run out of memory partway through, hot paths make no allocator calls, and error paths have nothing to free.

| What | Grows with | Bound |
| --- | --- | --- |
| Palette and bit planes per layer | the format | At most 2¹⁵ palette entries (128 KB) and 15 planes of 4 KB; already enforced by `src/Compression.zig`. |
| zstd decompression context | nothing | Fixed size, built once per worker in a supplied buffer (`ZSTD_initStaticDCtx`). |
| Decompression output | the format | The same caps as the palette and planes. |
| A chunk record from SQLite | the chunk's contents | SQLite's memory; SQLite can run inside one fixed block (`SQLITE_ENABLE_MEMSYS5` with `SQLITE_CONFIG_HEAP`). |
| Block entity data | arbitrary (mods, full chests) | Not set by the format: a per-chunk limit, 2 MiB by default (`Chunk.Decoder.defaultBlockEntityBytes`), with entities over it skipped with a warning. Parsed, block entities take up to 4.6× their raw bytes; the busiest test chunk, a ruin with 659 chiseled blocks and 134 KB of raw data, needs 615 KB. |
| Block and item names (`gamedata`), later assets | the game version and mods | Read once at startup. |
| Tile height arrays and pixels | the tile size | Fixed per worker, reused for every tile. |
| PNG encoding (stb) | the tile size | stb's memory functions can be replaced (`STBIW_MALLOC`), so it can use a fixed buffer. |

Stages:

1. **No allocation per chunk** (done): each worker sets up one `Chunk.Decoder` (a zstd context in a fixed buffer, and the block entity buffer, reset before each chunk) and one `Chunk` with fixed-size layers, about 380 KB, and reuses both for every chunk. `Decoder.decode` takes no allocator. Collecting each tree's entries on the stack before copying them out once halved block entity memory (1.2 MB → 615 KB for the busiest chunk). Renders take the same time as before on the test worlds, since the PNG dominates; decoding-heavy work is much faster: a stress test of about 12 million damaged inputs went from about 14 minutes to just over a second, with identical results.
2. **Tiles with levels of detail,** each worker reusing one fixed tile buffer.
3. **Enforcement:** an allocator that refuses to allocate after startup, SQLite on its own fixed block, and stb's memory functions pointed at a fixed buffer.

## Performance

*(Measured 2026-10-14 on a 14-thread Windows machine with `zig build bench -Doptimize=ReleaseFast -- <save> 7`: the median of 7 renders after one untimed one. The PNG is encoded but not written to disk.)*

Where a render's time goes, the 1.22.7 world (6,224 chunks, a 3,232 × 4,224 image):

| Stage | Time | Chunks/s |
| --- | --- | --- |
| Opening the save, its extent and the block list | 0.01 s | |
| Decoding all chunks | 0.09 s | 70,000 |
| Decoding all chunks and finding each column's top block | 0.14 s | 44,700 |
| Turning heights into pixels and encoding the PNG (stb) | 0.64 s | |
| End to end | 0.80 s | 7,800 |

- **The PNG dominates large maps.** It grows with map area, while decoding grows with the number of chunks. Tiles (above) bound it.
- **One zstd decompression context per worker,** reused for every layer (stage 1 above). Creating one per layer cost at most ~0.05 s of kernel time per render, so renders barely changed; a stress test with millions of tiny inputs, which had spent 83% of its time creating contexts, got much faster.
- **Decoding runs on every core**, one SQLite connection per worker, each worker taking whole chunk columns. On these small test worlds it barely helps in ReleaseFast (decode and scan 0.19 s → 0.16 s), because starting threads and connections is a fixed cost; in Debug the 1.19 sample renders 2.5× faster (2.56 s → 1.02 s). The gain should grow with world size, which hasn't been measured on a large world yet.
