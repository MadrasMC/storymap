# TODO

Storymap renders Vintage Story saves as a **top-down map** and a **Mapcrafter-style isometric render**. Format knowledge lives in [`docs/save-format/README.md`](docs/save-format/README.md) and renderer research in [`docs/rendering.md`](docs/rendering.md): record every finding there, with its source, as it's made.

## Top-down map

1. **Closer season tint.** Grassland in `style game:coloured` is 15–20% darker than the game's map, forest about 10%: the game's season colour is brighter than the season map's columns average, and how it picks it is closed ([`docs/rendering.md`](docs/rendering.md#climate-and-season-tint)). Also not followed: frost, the southern hemisphere, and block classes with their own colour (forest floor, water lilies, leaves coloured by their shape).
2. **Incremental rendering.** Re-render only the tiles whose chunks changed since the last render, and the zoomed-out tiles above them, instead of the whole world every time. The save has no change times, so a render compares hashes:
	- **Per tile:** a hash of the raw rows its pixels come from (the map chunks of its columns and their ring, the chunks holding its surface, its map region), with the style, the theme's colours, the prepared blocks and the season. A tile whose hash matches isn't decoded, drawn or encoded.
	- **Interrupted renders:** each tile is written to a temporary file and renamed into place, and its hash is recorded at once, not at the end (perhaps in a text chunk of the PNG itself). The next render then resumes where the last one stopped.
	- **Goal: an interrupted render's tiles are visible.** Every tile written before the interruption shows in the viewer. Today it doesn't: the page and `map.json` list the tiles that exist and the viewer asks only for those, but both are written when the render finishes.
	- **Zoomed-out tiles:** a parent with skipped children reads them back from their PNGs, which needs a PNG decoder in the tile pipeline.
	- **First:** measure what reading and hashing an unchanged world costs against a full render.
3. **Measure on a large world.** The largest test world has 29,192 chunks (2.79 km²), and a render's fixed cost of about 60 ms is still a quarter of its time there ([`docs/performance.md`](docs/performance.md)); confirm the threading scales on a save with many more chunks.

## Memory

No allocation at runtime, TigerBeetle style ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)). Stage 1, no allocation per chunk, is done.

4. **Buffers sized at startup.** Nothing is allocated per tile, but a render's buffers are sized and allocated when it starts; once a process renders more than once (incremental rendering), they should be set up once.
5. **Enforcement.** An allocator that refuses to allocate after startup; SQLite on a fixed block (`SQLITE_ENABLE_MEMSYS5`).

## Block entities

6. **Item stacks.** Decode what a stack's class and id refer to (needed for ground storage and containers).

## Isometric render

7. **Coloured cubes.** Every block drawn as a cube in its average colour, its top, left and right faces lit differently, from one direction. Builds the isometric view without block art: tiles defined in pixels, each a slanted strip through the world's height; drawing back to front; what the game's reader gives the renderer (blocks in 3D, where the top-down map has a surface); a second projection in the viewer; and how fast it is, as it reads every chunk under a tile. Left:
	- **Speed:** each tile now reads every chunk under it, at every height (109,168 reads for the larger world's 29,192 chunks at 32 pixels a block). Instead, follow lines of sight, as Mapcrafter does (`TileRenderer::renderBlocks`): from the top of the world, step through the blocks along each line into the world until the first one that isn't transparent, and read a chunk only when a line enters it. Underground chunks are then never read, except where a line reaches them, such as the walls at the explored area's edges, and transparent blocks in front come with it.
		- **Cache:** each worker keeps the chunks it has read, as one byte per block saying how it's drawn (32 KB a chunk), in a fixed number of slots set up at the start; workers take neighbouring tiles, so most chunks are read once. Measure how many chunks a worker's tiles need at once to size it.
		- **Map chunks:** whether a chunk column is fully generated is read once per column, not once per chunk.
	- **Review the command line:** whether the isometric view stays behind `--isometric` or views are chosen another way, and whether the block width (32 pixels) is an option.
	- **Review the viewer's switch between views:** where it sits in each theme, its wording, and keys for it.
8. **Textured cubes.** Cube-shaped blocks (rock, soil, planks, ores) drawn once, when preparing blocks, as an isometric image per block ID and direction, as Mapcrafter's Blockcrafter does; a render pastes them. Climate tint.
9. **Shapes.** A rasterizer for the game's shapes (boxes with rotations and per-face texture coordinates) draws the images of every other block: stairs, slabs, fences, plants, leaves and liquids.
10. **Block entities.** Chiseled blocks first, drawn per block at render time from their boxes and their materials' textures; then ground storage (needs item stacks and item models), then containers, displays and decorations.

## Output

11. **Packs for hosting.** Tiles written into packs instead of one file each, served by any static host with HTTP range requests, and updated by incremental renders (item 2). Copying or uploading a few packs is much faster than tens of thousands of small files.
	- **Packs:** each level split into packs of a block of its tiles (4 × 4, say: about 3 MB of top-down tiles), each the tiles' PNGs end to end. A pack's name holds a hash of its contents (`topdown/0/250_249.3fa9c2e1.tiles`), so it never changes once written and can be cached forever.
	- **Index:** each tile's pack, offset, length and input hash (item 2), in one index per level that the viewer fetches when it first shows that level. The viewer asks for a tile's bytes with a range request.
	- **Incremental renders:** a pack with a changed tile is written again under its new name, copying its unchanged tiles' bytes from the old one; then the index is replaced in one rename, and packs neither the new index nor the previous one names are deleted, so a viewer that loaded the previous index can finish. An update uploads only the changed packs and the indexes.
	- **Interrupted renders:** the index still names only finished packs, so the map stays whole, and a rerun reuses the packs already written. Writing the index after each pack shows an interrupted render's tiles too.
	- **Folder output stays the default:** browsers make no range requests from `file://` pages, so packs are for hosting.
	- **Open:** the pack size, measured on real updates.

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
- Tiles: the top-down map is written as 512 × 512 tiles by a pipeline every view shares (`src/tiles/tiles.zig`), seamless across tile edges, with zoomed-out levels up to a single tile.
- Only fully generated chunk columns (world-generation stage 6, Done) are drawn, like the game's own map: the rings of partly generated columns around them are left out ([save format §7](docs/save-format/README.md#world-generation-stages)).
- A viewer: `index.html` and `map.json` written beside the tiles; one page without libraries, panning and zooming with the mouse, touch and keyboard ([`docs/rendering.md`](docs/rendering.md#output-tiles-and-levels-of-detail)).
- The viewer's positions match the game's, relative to the world's centre: checked against a position the game showed and the player's position in the save ([save format §2](docs/save-format/README.md#2-positions)).
- Themes: the page around the map is drawn by a theme, chosen with `--theme`: `printed`, `plain` or a folder of your own ([`docs/themes.md`](docs/themes.md)).
- Chunk decoding on every core, one SQLite connection per worker; timings in [`docs/rendering.md`](docs/rendering.md#performance).
- Format checked against 1.22.7: schema, positions, chunk fields, block and liquid decoding and block entities all hold; differences are noted in the docs.
- Chiseled blocks and ground storage checked on 1.22.7, in the larger test world's ruins: every block entity parses, every cuboid decodes, and the new keys are documented ([save format §5](docs/save-format/README.md#chiseled-blocks-microblock-chisel)).
- Assets read in place from `--game`/`--data` (found in the standard locations by default): files read by path or listed by folder, mod zips read without unpacking, mods replacing the game's files ([`docs/rendering.md`](docs/rendering.md#reading-them)).
- Preparing blocks, as Mapcrafter's Blockcrafter does: every block type of the game and mods expanded into the block codes the game makes, exactly those in the test saves, kept in a blocks folder (`blocks` in the current folder by default), one set per game version and mods; a render prepares on demand (`--prepare` to force, `storymap prepare` alone) and reports blocks the save has that the game and mods don't ([`docs/rendering.md`](docs/rendering.md#preparing-blocks)).
- Map colours from the theme's `topdown/style.txt`: a colour per map type, drawn as a relief (Printed) or as the game draws its own map (plain), the game's style matching the game's own map cache on 99.65% of a test world's pixels ([`docs/themes.md`](docs/themes.md#map-style), [`docs/rendering.md`](docs/rendering.md#how-the-game-draws-its-own-world-map)).
- `style game:coloured`, the game's colour-accurate map without its tint: each block's texture colours worked out when preparing, with grain picked by the game's position hash, and its hill shading ([`docs/rendering.md`](docs/rendering.md#texture-colours)).
- Climate and season tint for `style game:coloured`, as the game's shader does it: the climate from the map regions, the colour maps prepared with the blocks, the season from the save's date or `--season`. Water matches the game's map ([`docs/rendering.md`](docs/rendering.md#climate-and-season-tint)).
- Command lines parsed and routed by `lib/args`, a library of our own, with each command's usage and help generated from what it takes.
- Each part of Storymap a module of its own, so `build.zig` enforces what each may import, and the renderer can't import the game's reader ([`CONVENTIONS.md`](CONVENTIONS.md#modules)).
- The game's own map styles drawn by the game's reader (`src/vs/MapPainter.zig`), in the game's own colours: `game` for the game's default, or `game:shaded` and `game:coloured`. The renderer draws only Storymap's relief, in the theme's colours. `--style` picks another style than the theme's ([`docs/themes.md`](docs/themes.md#map-style)).
- No allocation per tile (memory stage 2): PNGs written by an encoder of our own (`lib/png`) into buffers set up before any work starts, replacing stb_image_write; tiles 20% smaller and renders 14% faster ([`docs/rendering.md`](docs/rendering.md#memory-no-allocation-at-runtime-goal)).
- Chiseled blocks in the top-down map, one colour per block: the relief shows the material covering most of the block's top, and the `game:` styles show them as the game does, the coloured one in their first material's colour and their majority material's grain (`src/vs/ChiseledBlock.zig`, [`docs/rendering.md`](docs/rendering.md#how-the-game-draws-its-own-world-map)).
- Performance recorded per version, one table per save, by `scripts/benchmark.zig`, which builds each tag with the Zig release it names ([`docs/performance.md`](docs/performance.md)).
- A modded world: the larger 1.22.7 test world was created with Primitive Survival. Mods' block and item codes carry their domain, and their IDs follow the game's ([save format §6](docs/save-format/README.md#block-and-item-ids)).
