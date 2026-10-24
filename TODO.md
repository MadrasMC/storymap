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
	- **Speed:** tiles follow lines of sight now, reading 20,013 chunks for the larger world where reading every chunk under each tile took 109,168, with the same tiles. Target: the whole render of that world under 1 s on 12 cores, with textured blocks, at 32 pixels a block (16 pixels look too jagged). Now, with `storymap bench --isometric --folder` on AC power, the isometric view takes 8.6 s for its 4,439 tiles; summed over 14 threads, 13 s drawing, 48 s filtering PNG rows, 44 s compressing them, 7 s writing the files and 2 s shrinking tiles for the levels above (34 s filtering and 30 s compressing when the tiles aren't written). Filtering tries all five PNG filters on every row, a byte at a time.
		- **Cache size:** 128 chunks with blocks per worker (8 MB, 2 bytes a block for its look) and 4,096 without; measure how many a worker's tiles need at once, and how many chunks are read more than once.
		- **Experiments, once blocks are textured (item 8),** as textures change how tiles compress; measured with `scripts/benchmark.zig --current --isometric --write`:
			- **Faster filtering:** one filter picked by a cheap rule, or all five without branches and with vector instructions.
			- **Fewer files:** packs (item 11) or one file per level. Writing 4,439 files takes 7 s and slows encoding by about 40% while it runs.
			- **An encoder for these tiles:** deflate tuned for long repeats, as fpng does, measured on textured tiles.
			- **Larger tiles:** 1024 × 1024 pixels instead of 512 × 512, a quarter as many files, with fewer blocks drawn twice across tile edges, and larger runs for the encoder to find repeats in; each worker's tile buffers take 4 times the memory, and the viewer loads fewer, larger files.
			- **JPEG XL instead of PNG:** lossless, with transparency and a very fast lossless encoder; on by default in Chrome 155 and Firefox 158, partly supported in Safari since 17, and not in Edge or Samsung Internet (caniuse, October 2026). Tried once with flat-coloured cubes, before textures, so it needs measuring again on textured tiles:
				- **Encoder:** only libjxl 0.12.0's fast lossless encoder, `lib/jxl/enc_fast_lossless.cc`, one C++ file with 4 small headers, which builds unchanged with Zig's C++ compiler and adds 738 KB to the program. The full libjxl encoder is 4.13 MB of DLLs.
				- **Results on the larger world, flat-coloured cubes:** encoding took 7.4 CPU-s over 14 threads where PNG took 66, and the isometric view 1.35–1.54 s instead of 5.7 s, not written; both views end to end, written, about 2.5 s instead of 8.5 s. Full-detail tiles were 4% larger (78.9 MB against 75.7 MB), but all levels 46% larger (234 MB against 160 MB): shrunk tiles are gradients, which the fast encoder compresses poorly, so the zoomed-out levels may stay PNG or take a higher effort.
				- **Effort:** from effort 2 up, the encoder keeps a palette for a tile with few colours, and more effort samples more rows for better codes: effort 10 was fastest and smallest of 1, 2, 10 and 50. Textured tiles have many colours, so they should behave like effort 1, which took about 9 CPU-s and made all levels 351 MB; still about 7 times cheaper than PNG.
				- **To adopt it:** a fixed output buffer, as the encoder allocates its output for every tile; a viewer that handles browsers without JPEG XL; a C++ source in the build.
			- **Lossy formats for textured tiles:** WebP or JPEG encode faster and much smaller, but blur the edges between blocks.
			- **Cheaper zoomed-out levels:** 32 pixels a block only at full detail.
			- **Drawing in the browser:** the viewer draws the blocks with WebGL from exported block data and a texture atlas, so no tiles are encoded at all; a different viewer, a 3D renderer.
			- **The GPU for drawing:** drawing isn't what's slow, and encoding and writing stay on the CPU, so it doesn't help as long as tiles are PNGs.
	- **Review the command line:** whether the isometric view stays behind `--isometric` or views are chosen another way, and whether the block width (32 pixels) is an option.
	- **Review the viewer's switch between views:** where it sits in each theme, its wording, and keys for it.
8. **Textured cubes.** In `style game` (`isometric/style.txt`, the Plain theme's), blocks the game draws as plain cubes (`drawtype` `cube`, and grassy soil, `TopSoil`) drawn in their textures; other blocks as cubes in their textures' average colour until shapes (item 9). Done: preparing stores each cube block's top, south and east textures, with their overlays (`textures.bin`); the game's reader hands them to the renderer by block ID (`world.CubeFaces`), and the renderer draws each block's 32-pixel picture from them when the render starts. The climate and season tint, which the game's reader works out for each block where it is (`tint`), is multiplied into a picture's tinted layer (grass) and into the colours of leaves and water. Tinting adds 0.4–0.7 s to the larger world's isometric view: 2.6 s of drawing summed over the workers, working out a tint for every tinted block drawn, and 5.5 s of compressing, as tinted tiles have more colours.
	- **Textured tiles are larger:** 381 MB of isometric tiles for the larger world where relief makes 140 MB, and the whole render takes about 0.6 s longer, most of it encoding. `scripts/benchmark.zig --isometric` measures these textured tiles, with `game:coloured` top-down.
	- **Texture variants by position:** a texture named with `*` (`granite*`) has variants, one picked per block by its position. Done, by vsapi's `GameMath.MurmurHash3Mod`; the game picks in closed code, so that it hashes the same way isn't checked. Variants make the isometric tiles 21% larger (599 MB against 496 MB for the larger world) and its view about 0.5 s slower, all in compressing.
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
