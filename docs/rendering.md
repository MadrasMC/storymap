# Rendering notes

Research for Storymap's two planned outputs: a **top-down map** and a **Mapcrafter-style isometric render**. The save format itself is documented in [`save-format/README.md`](save-format/README.md); sourcing conventions are the same as there. How a block is read from the game's assets and drawn is in [`blocks.md`](blocks.md).

## How the game draws its own world map

*(Source: [vsessentialsmod `Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs), the 1.22.7 code.)*

Per block column:

1. **Height:** `RainHeightMap[i]` from the column's map chunk: the top block that isn't rain-permeable.
2. **Block:** the block at that height, read from the fluid-or-solid layer, so water shows instead of the lake bed.
3. **Snow:** in the default mode, if the top block's material is snow, step one block down and use what's under it.
4. **Colour, default mode:** each block's `mapColorCode` attribute (falling back to a default per block material, then `land`) picks a colour from a small fixed palette (`hexColorsByCode`, e.g. `forest`, `lake`; [Block colours](blocks.md#block-colours)). A lake is a block of water material, or of ice other than `glacierice`. It's drawn in `wateredge` if any of the four blocks beside it at the same height isn't a lake, unless one of their chunks isn't loaded, when it's drawn as lake.
5. **Colour, "accurate" mode** (the world setting `colorAccurateWorldmap`): the block's average colour (`block.GetColor`, the average of its `textureCodeForBlockColor`, `up` or first texture, tinted by climate and season) overlaid with one of 30 random texture colours (`GetRandomColor`, from its `particlesTextureCode`, `up` or first texture, likewise tinted, picked by `GameMath.MurmurHash3Mod` of the position) at weight 0.6 (`colorRandomizationWeight`), each channel rounded down. It doesn't look under snow, and lakes are shaded and have no edge. A block with no textures is white, and its grain black. *(Source: also vsapi [`Block.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/Collectible/Block/Block.cs), `GetColor`, `GetRandomColor` and `LoadTextureSubIdForBlockColor`, and [`GameMath.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Math/GameMath.cs).)* The average and the 30 colours are worked out by the texture atlas, in the closed engine, so how isn't known.
6. **Hill shading:** the column's height minus each of its north-west, west and north neighbours' (0 where a neighbour's map chunk isn't loaded). If the signs add up to more than 0, the shading is 128 × (1.08 + min(0.5, steepness / 10) / 1.25), where steepness is the largest difference; below 0, 128 × (0.92 − the same); otherwise 128, as for lakes. The shading is box-blurred within each chunk, 3 wide, across and then down. The colour is multiplied by 1 + the blurred shading, as a fraction above 128 times 5, rounded towards 0, divided by 5, + the unblurred one's remainder, divided by 5, and clamped. *(Source: `ChunkMapLayer.GenerateChunkImage` and [`BlurTool.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/BlurTool.cs).)*

The game's map cache keeps every pixel it drew, so it's a reference for drawing the same way: Storymap's `game:shaded` style ([themes.md](themes.md#vintage-storys-styles)) matches it on 99.65% of the larger 1.22.7 world's pixels, 2,748,998 of 2,758,656. Most of the rest are lit or shaded differently along chunk borders: the cache keeps pieces drawn while a neighbouring chunk hadn't loaded yet, whose border shading took that neighbour as level. *(Verified (1.22.7): the larger world's map cache, in default mode, against Storymap's tiles of the same world.)*

Storymap's `game:coloured` style draws accurate mode, with the tint as below ([Climate and season tint](blocks.md#climate-and-season-tint)). Against the map cache of a 1.22.7 world in accurate mode, the shading matches, as do untinted blocks such as sand, gravel, rock, snow and glacier ice, and water within 2 levels of 255 on average. Grassland comes out 15–20% darker than the game's, and forest about 10%. Grain can't match pixel for pixel, as the game's 30 colours are picked at random, but averaged over 4 × 4 blocks, 97% of the map is within 25 levels of the game's. *(Measured (1.22.7): the cache against Storymap's tiles, by map type.)*

Chiseled blocks ([save format §5](save-format/README.md#chiseled-blocks-microblock-chisel)): in default mode, the game's map colours one as the chiseled block itself, by the chiseled block type's colour code (`land`). In accurate mode, the chiseled block passes both colours on to its materials: the average colour is its first material's, and the grain its majority material's, the one filling the most voxels, leaving out meta blocks such as colliders. Each is tinted as its own material. *(Source: vssurvivalmod [`BlockMicroBlock.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BlockMicroBlock.cs), `GetColorWithoutTint` and `GetRandomColor`, and `BEMicroBlock.cs`, `getMajorityMaterial`.)* Storymap's `game:` styles do the same. Its relief shows each chiseled block as the material covering most of its top: of the top voxels of its 16 × 16 columns of voxels, the material most of them have, looking through meta blocks. In the ruins of the larger 1.22.7 world, a sixth of the chiseled blocks on the surface have a meta block, `meta-selectablecollider`, as their first material, and a tenth have a different majority material from their first. *(Verified (1.22.7).)*

The game's map only shows chunk columns the client has received, all of them fully generated: in a 1.22.7 test world, every piece in its cache was a stage-6 (Done) column, and none were partly generated columns ([save format §7](save-format/README.md#the-games-map-cache)).

Seas and lakes are told apart by block: `saltwater` sets `mapColorCode: "ocean"`, while `water`, `rapidwater` and `boilingwater` set none and take the liquid default, and `lakeice` sets `"lake"`. *(Verified (1.22.7): `assets/survival/blocktypes/liquid/` in the install.)* All three test saves list `saltwater` in their block IDs but contain none: no test world reaches a sea.

Storymap's top-down map takes each column's height from its map chunk's rain height ([save format §7](save-format/README.md#7-map-chunks)), like the game, and looks up only the block there, in the solid layer (field 1) and the liquid layer (field 16). A liquid there is a water surface, and the map chunk's terrain height gives its bed. Rain falls through plants and loose stones, so the map shows the ground beneath them. The map covers only fully generated chunk columns: those whose map chunk says world generation is Done (stage 6; [save format §7](save-format/README.md#world-generation-stages)). The game rings everything it finishes with partly generated columns, which look unfinished (no trees or plants up to stage 3) and which its own map leaves out. A column that isn't Done stays transparent, and in the ring around a tile it counts as no blocks. Every chunk column has a map chunk in the test saves (§2 of the save format); one without wouldn't be drawn either. Block columns without a stored height, or whose stored height points at a block that's gone, are scanned instead: from the top down, a column shows liquid when its highest liquid is at or above its highest solid block, ignoring solid blocks that share their place with a liquid. Those are water plants *(Verified (1.19, 1.22.7): at the water surface they're `seaweed`, `aquatic-*` (milfoil, crowfoot), reeds and tule)*, so the water shows and its depth reaches down to the ground. Lily pads (`waterlily`) sit on top of the water instead and still show as land. Water under a solid top block, such as a lake under a tree's leaves, is looked for between the top and the map chunk's terrain height, the ground before trees and plants grew; for most columns the two are the same, so nothing is looked at. The block under the top is noted too, for looking under snow.

## Assets

Blocks are defined by data files, not code *(Wiki)*:

- **Block types:** JSON in `blocktypes/`, with variant groups and per-variant properties. *([Wiki: Asset Type – BlockTypes](https://wiki.vintagestory.at/Modding:Asset_Type_-_BlockTypes))*
- **Shapes:** JSON in `shapes/`, normally made with the official Model Creator: boxes with per-face texture references, rotations and nested children. *([Wiki: Asset Type – Shapes](https://wiki.vintagestory.at/Modding:Asset_Type_-_Shapes))*
- **Textures:** PNG in `textures/`, referenced from block types and shapes by name. *([Wiki: Asset Type – Textures](https://wiki.vintagestory.at/Modding:Asset_Type_-_Textures))*

These are the game developers' copyrighted assets, so Storymap never ships them: every user's own install and mods are read. That's also the only way modded blocks render correctly. They're read once, to prepare what a map needs, and a render reads only that ([Preparing blocks](blocks.md#preparing-blocks)). Mapcrafter works the same way: a separate tool, Blockcrafter, renders every block's image from the game's assets once, and the renderer only loads those images.

Where they live *(Verified (1.22.7): a fresh Windows install)*:

- **Game install** (`%APPDATA%\Vintagestory` on Windows): `assets/` with three folders, `creative`, `game` and `survival`, each containing `blocktypes/`, `shapes/`, `textures/` and more. All three are the `game` domain: block types in `survival/blocktypes/` make codes without a domain, such as `rock-granite`, and refer to each other's files without one *(Verified (1.22.7): the block codes they make are those in the saves, [Block codes](blocks.md#block-codes))*. `assets/version-1.22.7.txt` names the version. The install's own `Mods/` folder holds only the built-in code (`VSSurvivalMod.dll`, `VSEssentials.dll`, `VSCreativeMod.dll`) and a `do_not_add_mods_here.txt`.
- **Data folder** (`%APPDATA%\VintagestoryData`): `Saves/`, and `Mods/` with user mods as zip files (e.g. `primitivesurvival_5.1.4.zip`), laid out as in [Mods](#mods) below. There's also a `Maps/` folder with one small `.db` file per world, probably the client's world-map cache; not looked into.

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

**The JSON isn't standard JSON.** Asset files use unquoted keys, single-quoted strings, numbers like `.5`, comments and trailing commas, so a strict JSON parser (like Zig's `std.json`) rejects them. [`src/vs/Json.zig`](../src/vs/Json.zig) reads them. *(Verified (1.22.7): every block type, item type, world property and patch file of the game and Primitive Survival, 1,025 files.)*

**Variant syntax:** block types generate one block per variant combination. Properties can be keyed by variant pattern (`texturesByType: { "rock-*": … }`, regex keys like `"@rock-(claystone|sandstone)"`), use `{rock}`-style placeholders, and a texture path ending in `*` means "all numbered alternates" (e.g. `block/stone/rock/{rock}*`).

### Mods

A mod is a zip in the data folder's `Mods/`, e.g. `primitivesurvival_5.1.4.zip`:

- `modinfo.json` at the top: `modid`, `name`, `version`, `type` (`code` here, so it also ships `primitivesurvival.dll`).
- `assets/<modid>/` with the same folder names as the base game (`blocktypes`, `shapes`, `textures`, `patches`, …), plus `compatibility/`, assets that apply only when another mod is present.
- Files in other domains, e.g. `assets/game/textures/` and `assets/game/lang/`, which override or add to the base game's assets.

A save names the mods its blocks and items come from: their codes carry the mod's domain, as in `primitivesurvival:treehollowgrown-…` ([save format §6](save-format/README.md#block-and-item-ids)).

### Reading them

Preparing reads the assets in place, from the install and the data folder (`--game` and `--data`, defaulting to the standard locations above). [`src/vs/Assets.zig`](../src/vs/Assets.zig) does this:

- **Mods:** each zip or folder in `Mods` is read in place, zips without unpacking them. Its `assets/<domain>/` folders count like the game's. All of them are used, enabled or not.
- **Files are read by path:** most of what rendering needs is named exactly, such as a block type's shape and textures, or `config/colormaps.json`. Only the files in the table above are read. Mods' `compatibility/` folders are left out for now.
- **Some files are listed instead:** nothing in a save's block code says which file defines it (`survival/blocktypes/stone/rock.json` defines every `rock-*`), so block types are found by listing every domain's `blocktypes/`. Patches are listed the same way, and so is a folder of numbered texture alternates.
- **A zip has no lookup by name**, so the entries rendering needs are mapped when it's opened, from its central directory.
- **Case doesn't matter**, as in the game, which lowercases every asset location *(Source: [vsapi `AssetLocation.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/Assets/AssetLocation.cs))*. A few of the game's files aren't lowercase, such as `survival/shapes/block/clutter/pipes/h-EW.json`, 34 of the files rendering needs in 1.22.7; where the file system minds case, a file not found by its lowercase path is looked for by its own name.
- **A mod's file replaces the game's** of the same domain and path, and mods are taken in name order, so which one wins when two mods have the same file doesn't depend on the file system. In what order the game itself applies mods isn't checked.

Opening the assets takes about 2 ms for 1.22.7 with Primitive Survival, and listing every block type, 543 from the game and 69 from the mod, about 4 ms. *(Verified (1.22.7): files read this way match the same files read from the install and from inside the zip, byte for byte.)*

## Block entities that change how things look

From the sample save (class counts in [`save-format/README.md` §5](save-format/README.md#5-block-entities-field-8)):

- **Chiseled blocks** (`MicroBlock`, `Chisel`): the shape is fully in the save as 16³-voxel cuboids with block-ID materials. Top-down: one colour per block, from its materials ([How the game draws its own world map](#how-the-game-draws-its-own-world-map)). Isometric: draw the boxes with each material's texture. No model files needed.
- **Ground storage** (`GroundStorage`): item stacks placed on the ground (firewood, planks, ingots…). Needs item stack parsing and item models.
- **Containers, displays and decorations** (`GenericTypedContainer`, `Crate`, `DisplayCase`, `Tapestry`, `TorchHolder`, …): the base look comes from the block's own shape; contents and variants come from the block entity.

## Isometric reference

[Mapcrafter](https://github.com/mapcrafter/mapcrafter) renders Minecraft worlds as isometric tiles for a web map. It's the model for Storymap's isometric output; its approach hasn't been studied in detail here yet.

## Output: tiles and levels of detail

Storymap renders a world as square tiles for a map viewer, never as one image, like a web map. Every view (the top-down map, the isometric view with `--isometric`, and later one isometric view per direction) is a pyramid of tiles:

- **Tiles are 512 × 512 pixels** in every view and level. In the top-down view's full-detail level that's 512 × 512 blocks, 16 × 16 chunk columns, the same area as a map region (the save's `mapregion` table). In an isometric view a block takes many pixels and a region projects to a slanted diamond, so tiles are defined in pixels, not blocks.
- **Levels of detail:** level 0 is full detail; each level above halves the resolution, so a level-n tile covers 2ⁿ × 2ⁿ level-0 tiles and a zoomed-out view loads a few tiles. The top level is a single tile covering the whole world, or up to 2 × 2 tiles where the world lies either side of tile position 0: a tile's parent is its position halved and rounded down, which keeps −1 at −1 and 0 at 0, so tiles −1 and 0 never meet. Levels stop where halving brings the tiles no closer: across and down, they're at one position, or at exactly −1 and 0.
- **Only tiles with something in them are written.** Empty pixels are transparent; the viewer draws the paper behind them.
- **Layout:** `<output>/<view>/<level>/<x>/<y>.png`, e.g. `out/topdown/0/1000/999.png`. Beside them, `map.json` describes the world and each view with the tiles it has and their file extension, and `index.html` is the viewer.
- **Format:** PNG; with `--webp` lossless WebP (`.webp`, `lib/webp`), as fast and smaller, which every browser shows, and with `--lossy-from <level>` lossy from that level up, at quality 90, smaller again where blocks are drawn small enough that blurred edges don't show; or with `--jpegxl` lossless JPEG XL (`.jxl`, `lib/jxl`), which encodes faster but larger, and not every browser shows: Chrome from 155 and Firefox from 158 do, Safari partly, and Edge doesn't (caniuse, October 2026). All three are kept until one is chosen ([TODO.md](../TODO.md), item 7).
- **The viewer** (`src/viewer/viewer.html`, one page without libraries) has the map's description inlined, as a browser opening the page straight from the disk won't let it fetch `map.json`. It asks only for tiles that exist, at the level whose pixels are closest to screen pixels without being smaller; while a tile loads, the nearest loaded tile above it stands in. Positions show as the game shows them, from the origin `map.json` gives, which in Vintage Story is the world's centre ([save format §2](save-format/README.md#2-positions)), and the current one is kept in the page's address with the zoom (`#512,-512,2:1`, `#512,-512,1:8`, or `fit` for the whole map at a step of its own). Everything around the map is drawn by a theme ([themes.md](themes.md)), inlined like the description. The built-in Printed theme sets the page out like a printed map: a neatline, a grid in the game's coordinates labelled in the margin, and a title cartouche with the game and the version that last saved the world (`gamedata` field 21) and when the map was rendered, both from `map.json`. The zoom shows as a scale of screen pixels to blocks, the same in every world and written as maps write theirs: at 1 : 1 a block is one screen pixel, the tiles' full detail, and at 1 : 8 eight blocks share a pixel. The buttons and keys step between whole magnifications (1 : 4, 1 : 2, 1 : 1, 2 : 1, 4 : 1), while the wheel and pinching zoom freely; a zoom between whole numbers shows the nearest one in italic over a dotted line, while the address keeps the exact value. The view of the whole map snaps to a whole step within ×1.2 of it (up only while the explored area still fits); farther from one, it's a step of its own. Either way the zoom is circled there, and the view stays the whole map when the window changes shape. Pressing the zoom shows the whole map. Zooming in stops at 4 : 1, past which only the pixels grow; zooming out stops at the whole step at or below half the view of the whole explored area, the one limit that depends on the world.
- **Views:** with more than one, the theme switches between them, at the same place in the world: from the view of the whole map to the whole of the other one, and otherwise keeping the position at the centre, with blocks about the same size, at the nearest whole step. A point in the isometric view covers a whole line of blocks, so the viewer takes positions there on the top of the blocks at sea level (`seaLevel` in `map.json`), and it has no grid, coordinates or scale bar. Its zoom is a scale of screen pixels to tile pixels, so 1 : 1 is again the tiles' full detail. The address names a view other than the first: `#isometric/512,-512,1:2`.

`src/tiles/tiles.zig` is the pipeline every view shares, and a view only draws full-detail tiles into a fixed buffer. How the work is shared between workers:

- **Levels are built bottom up**, so nothing is read back from disk: a tile is its four children, each shrunk to half size. Shrinking averages 2 × 2 pixels with their colours weighted by how opaque they are, so the transparent edges of explored areas fade out instead of darkening. *(Verified (1.19, 1.22.7): every zoomed-out tile matches an independent rebuild from the tiles below, byte for byte.)*
- **Workers take whole subtrees:** a tile at the highest level with at least 4 tiles per core, and everything under it, so each keeps one tile buffer per level. Each subtree's tile at the cut level waits at half size until the levels above are built; those are built one level at a time, every worker taking tiles of that level. The tile list gives every level's size, so all the waiting halves are set aside before any work starts: one per subtree, plus one block the size of the level above the cut. The levels above take turns with the two, since a level only needs the halves of the level below it, and no level has more tiles than the one below it. The top-down view draws a tile from its 16 × 16 chunk columns plus a one-block ring around them from its neighbours, so hill shading and coastlines match across tile edges: stitched together, the tiles of both test saves are pixel for pixel the single image Storymap used to render. Every tile has a fixed size, which is what makes the memory goal below possible.

## Memory: no allocation at runtime (goal)

Following [TigerBeetle's style](https://github.com/tigerbeetle/tigerbeetle/blob/1a90d33bed174fac26ace95f4f43e51019bbb89d/docs/TIGER_STYLE.md#safety) ("All memory must be statically allocated at startup"): everything is allocated once at startup, sized from the save, the installed mods and configured limits, and nothing is allocated per chunk or per tile. Memory use is then known up front, a render can't run out of memory partway through, hot paths make no allocator calls, and error paths have nothing to free.

| What | Grows with | Bound |
| --- | --- | --- |
| Palette and bit planes per layer | the format | At most 2¹⁵ palette entries (128 KB) and 15 planes of 4 KB; already enforced by `src/vs/Compression.zig`. |
| zstd decompression context | nothing | Fixed size, built once per worker in a supplied buffer (`ZSTD_initStaticDCtx`). |
| Decompression output | the format | The same caps as the palette and planes. |
| A chunk record from SQLite | the chunk's contents | SQLite's memory; SQLite can run inside one fixed block (`SQLITE_ENABLE_MEMSYS5` with `SQLITE_CONFIG_HEAP`). |
| Block entity data | arbitrary (mods, full chests) | Not set by the format: a per-chunk limit, 2 MiB by default (`Chunk.Decoder.defaultBlockEntityBytes`), with entities over it skipped with a warning. Parsed, block entities take up to 4.6× their raw bytes; the busiest test chunk, a ruin with 659 chiseled blocks and 134 KB of raw data, needs 615 KB. |
| Block and item names (`gamedata`), later assets | the game version and mods | Read once at startup. |
| Tile height arrays and pixels | the tile size | Fixed per worker, reused for every tile. |
| PNG encoding (`lib/png`) | the tile size | Each worker's encoder sets up its buffers once, for a full tile; nothing is allocated per tile. |
| Blocks' pictures | the game and mods | Drawn when the blocks are prepared, and mapped from their file (`pictures.bin`), not allocated. |
| WebP encoding (`lib/webp`) | the tile size | Each worker's encoder sets up its buffers once, with the working memory libwebp allocates from, 16.6 MB for a full tile, where tiles took up to 11.6; what doesn't fit comes from `malloc`. |
| JPEG XL encoding (`lib/jxl`) | the tile size | The output buffer is set up once; libjxl allocates its working memory for every tile. |

Stages:

1. **No allocation per chunk** (done): each worker sets up one `Chunk.Decoder` (a zstd context in a fixed buffer, and the block entity buffer, reset before each chunk) and one `Chunk` with fixed-size layers, about 380 KB, and reuses both for every chunk. `Decoder.decode` takes no allocator. Collecting each tree's entries on the stack before copying them out once halved block entity memory (1.2 MB → 615 KB for the busiest chunk). Renders take the same time as before on the test worlds, since the PNG dominates; decoding-heavy work is much faster: a stress test of about 12 million damaged inputs went from about 14 minutes to just over a second, with identical results.
2. **No allocation per tile** (done): each worker sets up its tile buffers and its PNG encoder (`lib/png`) before any work starts, and the tiles written go into a list sized from the tile pyramid. The encoder replaced stb_image_write, whose zlib allocated for every tile; in the larger 1.22.7 world its tiles are 20% smaller (6.9 MB against 8.7 MB), with the same pixels, and the render 14% faster. *(Measured 2026-10-23, against v0.1.0 in one sitting, as in [performance.md](performance.md); deflate level 4, as level 1 was no faster within the noise for 2% larger files, and level 6 took 30% longer for 2% smaller.)*
3. **Enforcement:** an allocator that refuses to allocate after startup, and SQLite on its own fixed block.

## Performance

Each version's numbers are in [performance.md](performance.md); this section is where a render's time goes, and why.

*(Measured 2026-10-17 on a 14-thread Windows machine with `zig build bench -Doptimize=ReleaseFast -- <save-file> 7`: the median of 7 renders after one untimed one. The PNGs are encoded but not written to disk. Chunks/s counts all the save's chunks, so the stages compare.)*

Where a render's time goes, in the larger 1.22.7 test world (29,192 chunks in 3,649 chunk columns, 2,729 of them fully generated):

| Stage | Time | Chunks/s |
| --- | --- | --- |
| Opening the save, its block list and which tiles it has | 0.016 s | |
| Decoding every chunk, for comparison | 0.45 s | 64,800 |
| All 34 tiles in 5 levels: the stored heights, the 6,618 chunks they point into (including each tile's ring), pixels, the levels above and the PNGs | 0.30 s | 98,500 |
| End to end | 0.31 s | 93,500 |

And in a smaller 1.22.7 world, with two explored areas far apart (6,224 chunks, of which 530 are read for its 23 tiles):

| Stage | Time | Chunks/s |
| --- | --- | --- |
| Opening the save, its block list and which tiles it has | 0.007 s | |
| Decoding every chunk, for comparison | 0.07 s | 91,800 |
| All 23 tiles in 5 levels | 0.10 s | 62,800 |
| End to end | 0.11 s | 58,700 |

- **Only fully generated columns are drawn**, so fewer chunks are read: 6,618 instead of 8,701 in the larger world, 530 instead of 1,440 in the smaller one. A column's stage is read only when its tile is drawn, so tiles holding only partly generated columns are still drawn, for nothing. Finding them before drawing would mean reading every map chunk on one thread first, which cost more.
- **Tiles skip empty space.** The single image this replaced was 94% empty paper between the smaller world's two explored areas, and its PNG took 0.41 s of a 0.52 s render. Encoding PNGs is about 40% of the workers' time in the larger world and 65% in the smaller one.
- **Small worlds wait on their top levels.** Each level waits for the one below, and above level 0 these worlds have only 5, 5, 4 and 1 tiles: a chain of encodes that can't overlap. In a large world nearly all tiles are in the bottom levels, which spread over every core.

- **Only the chunks holding the surface are read.** Each column's map chunk names the chunk holding its surface block, and workers fetch those chunks by key (their position), along with every chunk below a stale height. The map's extent and columns come from `mapchunk` too, which has a row per chunk column instead of one per chunk, so nothing goes through the whole `chunk` table. Before, each worker read through all of it to pick out its share, and every chunk was decoded: finding top blocks took 0.17 s in the 1.22.7 world and 0.11 s in the 1.19 sample, now 0.11 s and 0.03 s. What's left in the 1.22.7 world is mostly the per-pixel arrays, which cover its empty space between the two explored areas.

- **The PNG dominates large maps.** It grows with map area, while decoding grows with the number of chunks. Tiles (above) bound it.
- **One zstd decompression context per worker,** reused for every layer (stage 1 above). Creating one per layer cost at most ~0.05 s of kernel time per render, so renders barely changed; a stress test with millions of tiny inputs, which had spent 83% of its time creating contexts, got much faster.
- **Decoding runs on every core**, one SQLite connection per worker, each worker taking whole chunk columns. On these small test worlds it barely helps in ReleaseFast (decode and scan 0.19 s → 0.16 s), because starting threads and connections is a fixed cost; in Debug the 1.19 sample renders 2.5× faster (2.56 s → 1.02 s). The gain should grow with world size, which hasn't been measured on a large world yet.
