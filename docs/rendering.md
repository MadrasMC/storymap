# Rendering notes

Research for Storymap's two planned outputs: a **top-down map** and a **Mapcrafter-style isometric render**. The save format itself is documented in [`save-format/README.md`](save-format/README.md); sourcing conventions are the same as there.

## How the game draws its own world map

*(Source: [vsessentialsmod `Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs), the 1.22.7 code.)*

Per block column:

1. **Height:** `RainHeightMap[i]` from the column's map chunk: the top block that isn't rain-permeable.
2. **Block:** the block at that height, read from the fluid-or-solid layer, so water shows instead of the lake bed.
3. **Snow:** in the default mode, if the top block's material is snow, step one block down and use what's under it.
4. **Colour, default mode:** each block's `mapColorCode` attribute (falling back to a default per block material, then `land`) picks a colour from a small fixed palette (`hexColorsByCode`, e.g. `forest`, `lake`; [Block colours](#block-colours)). A lake is a block of water material, or of ice other than `glacierice`. It's drawn in `wateredge` if any of the four blocks beside it at the same height isn't a lake, unless one of their chunks isn't loaded, when it's drawn as lake.
5. **Colour, "accurate" mode** (the world setting `colorAccurateWorldmap`): the block's average colour (`block.GetColor`, the average of its `textureCodeForBlockColor`, `up` or first texture, tinted by climate and season) overlaid with one of 30 random texture colours (`GetRandomColor`, from its `particlesTextureCode`, `up` or first texture, likewise tinted, picked by `GameMath.MurmurHash3Mod` of the position) at weight 0.6 (`colorRandomizationWeight`), each channel rounded down. It doesn't look under snow, and lakes are shaded and have no edge. A block with no textures is white, and its grain black. *(Source: also vsapi [`Block.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/Collectible/Block/Block.cs), `GetColor`, `GetRandomColor` and `LoadTextureSubIdForBlockColor`, and [`GameMath.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Math/GameMath.cs).)* The average and the 30 colours are worked out by the texture atlas, in the closed engine, so how isn't known.
6. **Hill shading:** the column's height minus each of its north-west, west and north neighbours' (0 where a neighbour's map chunk isn't loaded). If the signs add up to more than 0, the shading is 128 × (1.08 + min(0.5, steepness / 10) / 1.25), where steepness is the largest difference; below 0, 128 × (0.92 − the same); otherwise 128, as for lakes. The shading is box-blurred within each chunk, 3 wide, across and then down. The colour is multiplied by 1 + the blurred shading, as a fraction above 128 times 5, rounded towards 0, divided by 5, + the unblurred one's remainder, divided by 5, and clamped. *(Source: `ChunkMapLayer.GenerateChunkImage` and [`BlurTool.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/BlurTool.cs).)*

The game's map cache keeps every pixel it drew, so it's a reference for drawing the same way: Storymap's `game:shaded` style ([themes.md](themes.md#vintage-storys-styles)) matches it on 99.65% of the larger 1.22.7 world's pixels, 2,748,998 of 2,758,656. Most of the rest are lit or shaded differently along chunk borders: the cache keeps pieces drawn while a neighbouring chunk hadn't loaded yet, whose border shading took that neighbour as level. *(Verified (1.22.7): the larger world's map cache, in default mode, against Storymap's tiles of the same world.)*

Storymap's `game:coloured` style draws accurate mode, with the tint as below ([Climate and season tint](#climate-and-season-tint)). Against the map cache of a 1.22.7 world in accurate mode, the shading matches, as do untinted blocks such as sand, gravel, rock, snow and glacier ice, and water within 2 levels of 255 on average. Grassland comes out 15–20% darker than the game's, and forest about 10%. Grain can't match pixel for pixel, as the game's 30 colours are picked at random, but averaged over 4 × 4 blocks, 97% of the map is within 25 levels of the game's. *(Measured (1.22.7): the cache against Storymap's tiles, by map type.)*

Chiseled blocks ([save format §5](save-format/README.md#chiseled-blocks-microblock-chisel)): in default mode, the game's map colours one as the chiseled block itself, by the chiseled block type's colour code (`land`). In accurate mode, the chiseled block passes both colours on to its materials: the average colour is its first material's, and the grain its majority material's, the one filling the most voxels, leaving out meta blocks such as colliders. Each is tinted as its own material. *(Source: vssurvivalmod [`BlockMicroBlock.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BlockMicroBlock.cs), `GetColorWithoutTint` and `GetRandomColor`, and `BEMicroBlock.cs`, `getMajorityMaterial`.)* Storymap's `game:` styles do the same. Its relief shows each chiseled block as the material covering most of its top: of the top voxels of its 16 × 16 columns of voxels, the material most of them have, looking through meta blocks. In the ruins of the larger 1.22.7 world, a sixth of the chiseled blocks on the surface have a meta block, `meta-selectablecollider`, as their first material, and a tenth have a different majority material from their first. *(Verified (1.22.7).)*

The game's map only shows chunk columns the client has received, all of them fully generated: in a 1.22.7 test world, every piece in its cache was a stage-6 (Done) column, and none were partly generated columns ([save format §7](save-format/README.md#the-games-map-cache)).

Seas and lakes are told apart by block: `saltwater` sets `mapColorCode: "ocean"`, while `water`, `rapidwater` and `boilingwater` set none and take the liquid default, and `lakeice` sets `"lake"`. *(Verified (1.22.7): `assets/survival/blocktypes/liquid/` in the install.)* All three test saves list `saltwater` in their block IDs but contain none: no test world reaches a sea.

Storymap's top-down map takes each column's height from its map chunk's rain height ([save format §7](save-format/README.md#7-map-chunks)), like the game, and looks up only the block there, in the solid layer (field 1) and the liquid layer (field 16). A liquid there is a water surface, and the map chunk's terrain height gives its bed. Rain falls through plants and loose stones, so the map shows the ground beneath them. The map covers only fully generated chunk columns: those whose map chunk says world generation is Done (stage 6; [save format §7](save-format/README.md#world-generation-stages)). The game rings everything it finishes with partly generated columns, which look unfinished (no trees or plants up to stage 3) and which its own map leaves out. A column that isn't Done stays transparent, and in the ring around a tile it counts as no blocks. Every chunk column has a map chunk in the test saves (§2 of the save format); one without wouldn't be drawn either. Block columns without a stored height, or whose stored height points at a block that's gone, are scanned instead: from the top down, a column shows liquid when its highest liquid is at or above its highest solid block, ignoring solid blocks that share their place with a liquid. Those are water plants *(Verified (1.19, 1.22.7): at the water surface they're `seaweed`, `aquatic-*` (milfoil, crowfoot), reeds and tule)*, so the water shows and its depth reaches down to the ground. Lily pads (`waterlily`) sit on top of the water instead and still show as land. Water under a solid top block, such as a lake under a tree's leaves, is looked for between the top and the map chunk's terrain height, the ground before trees and plants grew; for most columns the two are the same, so nothing is looked at. The block under the top is noted too, for looking under snow.

## Assets

Blocks are defined by data files, not code *(Wiki)*:

- **Block types:** JSON in `blocktypes/`, with variant groups and per-variant properties. *([Wiki: Asset Type – BlockTypes](https://wiki.vintagestory.at/Modding:Asset_Type_-_BlockTypes))*
- **Shapes:** JSON in `shapes/`, normally made with the official Model Creator: boxes with per-face texture references, rotations and nested children. *([Wiki: Asset Type – Shapes](https://wiki.vintagestory.at/Modding:Asset_Type_-_Shapes))*
- **Textures:** PNG in `textures/`, referenced from block types and shapes by name. *([Wiki: Asset Type – Textures](https://wiki.vintagestory.at/Modding:Asset_Type_-_Textures))*

These are the game developers' copyrighted assets, so Storymap never ships them: every user's own install and mods are read. That's also the only way modded blocks render correctly. They're read once, to prepare what a map needs, and a render reads only that ([Preparing blocks](#preparing-blocks)). Mapcrafter works the same way: a separate tool, Blockcrafter, renders every block's image from the game's assets once, and the renderer only loads those images.

Where they live *(Verified (1.22.7): a fresh Windows install)*:

- **Game install** (`%APPDATA%\Vintagestory` on Windows): `assets/` with three folders, `creative`, `game` and `survival`, each containing `blocktypes/`, `shapes/`, `textures/` and more. All three are the `game` domain: block types in `survival/blocktypes/` make codes without a domain, such as `rock-granite`, and refer to each other's files without one *(Verified (1.22.7): the block codes they make are those in the saves, [Block codes](#block-codes))*. `assets/version-1.22.7.txt` names the version. The install's own `Mods/` folder holds only the built-in code (`VSSurvivalMod.dll`, `VSEssentials.dll`, `VSCreativeMod.dll`) and a `do_not_add_mods_here.txt`.
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

### Block codes

A save names its blocks by code (`rock-granite`), and nothing in a code says which file defines it, so every block type is expanded into its codes as the game does it, by [`src/vs/BlockTypes.zig`](../src/vs/BlockTypes.zig) *(Source: vsessentialsmod's [`RegistryObjectTypeLoader.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Loading/RegistryObjectTypeLoader.cs) and [`RegistryObjectType.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Loading/RegistryObjectType.cs))*:

- **A block type** is a file in any domain's `blocktypes/`, with a `code` in the file's domain unless it names another. One with `enabled: false` (or `0`) makes no blocks. `inheritFrom` lays the file over another one first.
- **Variant groups** each give a list of states: their own `states`, or a world property's variants (`loadFromProperties: "block/rock"` is `worldproperties/block/rock.json`, in the `game` domain unless it names another; `loadFromPropertiesCombine` joins several). Groups that multiply (the default) give every combination of their states; groups that add give one block per state. A block's code is the type's code and its states, joined with `-`; an empty state adds nothing. `selectiveMultiply` splits one state of another group; nothing in 1.22.7 or Primitive Survival uses it.
- **`skipVariants` and `allowedVariants`** then filter the codes, by exact code or by wildcard, as `…ByType` keys are matched (below); none in 1.22.7 or Primitive Survival is a regular expression.
- **`…ByType` properties** take a value per variant: in `blockmaterialByType: { "*-snowy": "Snow", "*": "Soil" }`, the first key matching the block's code gives `blockmaterial` (an object merges into one already there), and `…ByType` properties inside are resolved the same way. Keys are wildcards, `*` matching any run of characters with letters in either case, or regular expressions after `@`, matching the whole code with case: the game's and Primitive Survival's use only groups of alternatives, `.` and `*` (`"@.*-(aged|veryaged)-.*"`), which is all Storymap supports. `{rock}` in a string is the variant's state of the `rock` group (`{wood|rock}`, either). *(Source: vsessentialsmod `RegistryObjectType.solveByType`, vsapi [`WildcardUtil.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Util/WildcardUtil.cs) and `RegistryObject.FillPlaceHolder`.)*
- **Patches aren't applied.** Mods can patch block types, but no patch in 1.22.7 or Primitive Survival changes which codes there are.

The result is exactly the block codes in the saves: the 14,089 of the 1.22.7 world, and the 14,781 of the larger one created with Primitive Survival, beside `air` and `mantle`, which the game registers itself. *(Verified (1.22.7): both worlds' `BlockIDs`, code by code.)*

### Block colours

The game's map, in its default mode, colours each block from a palette of a dozen colours, picked by a colour code (step 4 of [How the game draws its own world map](#how-the-game-draws-its-own-world-map)). A block's colour code is its `mapColorCode` attribute, or else its block material's default:

| Material | Colour code |
| --- | --- |
| Soil, Ore, Stone | `land` |
| Sand, Gravel | `desert` |
| Leaves, Wood | `forest` |
| Plant | `plant` |
| Snow, Ice | `glacier` |
| Water | `lake` |
| Lava | `lava` |
| anything else | `land` |

A block type that names no material is `Stone`. The palette, as the game has it: `land` #AC8858, `desert` #C4A468, `forest` #98844C, `plant` #808650, `lake`, `ocean` and `lava` #CCC890, `glacier` #E0E0C0, `settlement` #856844, `road` #805030, `devastation` #755C3C, and `ink` and `wateredge` #483018 for outlines. *(Source: vsessentialsmod [`ChunkMapLayer.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs), `defaultMapColorCodes` and `hexColorsByCode`; vsapi `Block.BlockMaterial`.)*

Both depend on the variant, through `blockmaterialByType`, `attributesByType` or a `mapColorCodeByType` inside `attributes` ([Block codes](#block-codes)). In 1.22.7 with Primitive Survival, of 14,781 blocks: `land` 5,400, `settlement` 4,010 (most building blocks set it), `forest` 3,634, `plant` 795, `desert` 444, `lake` 217, `glacier` 83, `ocean` 70 and `lava` 70 (the liquids), `devastation` 45 and `road` 13. Water and lake ice are `lake`, saltwater is `ocean`, glacier ice and snow are `glacier`. *(Verified (1.22.7): every block's material and colour code, against a separate implementation of the same rules.)*

### Texture colours

For accurate mode, each block's two textures are found as the game picks them (step 5 of [How the game draws its own world map](#how-the-game-draws-its-own-world-map)), from its `textures` and `particlesTextureCode` after `…ByType` and placeholders: a texture's `base`, in the block type's domain unless it names another, is `textures/<base>.png`. A base ending in `*` is the first file it starts, by name *(Source: vsapi [`CompositeTexture.Bake`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Client/Texture/CompositeTexture.cs))*; in which order the game lists them isn't checked. Overlays and alternates aren't used.

The game's atlas works out each texture's colours in closed code, so Storymap's are its own: the average weighs each pixel by how opaque it is, and the 30 grain colours are pixels picked at random, among those that aren't transparent, the same ones every time. In 1.22.7 with Primitive Survival, 1,716 textures colour 13,356 of the 14,781 blocks. The other 1,425, such as mushrooms, doors and multiblocks, have no texture Storymap could read; it colours them by their colour code instead of white.

### Climate and season tint

Grass, leaves and water have grey textures, which the game colours by where they are: a block type names a climate colour map and a season colour map (`climateColorMap` and `seasonColorMap`, by variant through `…ByType`; soil without grass has none), by their codes in the game's `config/colormaps.json`, which gives each an image in `textures/environment/` and its padding. In 1.22.7 there are 5 climate maps (264 × 264, a 256 × 256 map inside 4 pixels of padding, e.g. `climatePlantTint`, `climateWaterTint`) and 21 season maps (128 × 16, e.g. `seasonalGrass`, `seasonalOak`). The game's map tints in closed code (`ApplyColorMapOnRgba`); the game's shader for the world, `shaderincludes/colormap.vsh` and `colormap.fsh` in the install, does the same, and is what Storymap follows:

1. **The climate** at a column is its map region's climate map (§8 of the [save format](save-format/README.md#8-map-regions)), interpolated between its values 32 blocks apart, each channel rounded down: temperature and rainfall, each 0 to 255 *(Source: vsapi [`IntDataMap2D.GetUnpaddedColorLerped`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Datastructures/IntDataMap2D.cs))*.
2. **Height changes it:** the temperature falls by 1 for every 1.5 blocks above sea level, and rises below it; the rainfall changes by half the height above sea level, and gains 5 for each block closer than 8 above sea level, so 40 at sea level and below, each kept within 0 to 255 *(Source: vsapi [`Climate.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/Climate.cs), `GetAdjustedTemperature` and `GetRainFall`)*.
3. **The climate colour** is the climate map's pixel at the temperature across and the rainfall down, inside the padding.
4. **The season colour** is the season map's at how far through the year it is, across. The shader picks the row, and shifts the column a little, by noise at each place; Storymap takes the column's average over its rows. It's mixed into the climate colour by a weight that's higher where it's colder: with x the temperature at ground level, 0.5 − cos(x / 42) / 2.3 + max(0, 128 − x) / 512 − max(0, x − 130) / 200, within 0 to 1. A tropical season map (`extraFlags: 1`) is weighted by rainfall instead.
5. **The tint** multiplies the block's average colour and its grain colour each, channel by channel, rounded down (`ColorUtil.ColorMultiplyEach`).

How far through the year the save is comes from `gamedata`'s clock (§6): `TotalGameSeconds` over 3,600 and `HoursPerDay` gives the day, and a year is 12 months of the world config's `daysPerMonth`. 0 is the start of January. `--season` draws a season instead, at its middle: winter mid-January, spring mid-April, summer mid-July, fall mid-October, taking spring to be March to May. The southern hemisphere, which has its seasons half a year apart, isn't handled.

Measured against a 1.22.7 world's map cache in accurate mode, water, which has no season map, matches the climate colour within 0.01 per channel: its tint is the climate map's pixel. Over grassland, the game's tint fits a climate colour and a single season colour mixed by the shader's weight, the same season colour everywhere to within 0.04, but brighter than any column of `seasonalGrass` averages, so Storymap's grass is darker than the game's. Which row and column the game picks, and how it gets that colour, is an open question. Not followed either: frost, which lightens tinted blocks where it's cold; block classes with their own colour, such as forest floor, which mixes soil and grass by its grass level, and water lilies; and leaves whose colour maps come from their shape up close, other than those whose shape at a distance names them ([Cube faces](#cube-faces)). *(Measured (1.22.7): the cache divided by Storymap's untinted render, per 32-block cell, against the climate there.)*

### Cube faces

The isometric view's `game` style draws a block's top, south and east faces in its textures, for blocks the game draws as a plain cube:

- **Cubes:** drawtype `Cube` or `TopSoil`, or `JSON` (the default) with the shape `block/basic/cube` (the default) or `block/basic/cube-nozfight` (glacier ice's, its faces inset by 0.006 of a pixel), not rotated *(Source: vsapi [`Block`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/Collectible/Block/Block.cs), `DrawType` and `DefaultCubeShape`)*. Other shapes, such as plants', and other drawtypes, such as liquids, aren't drawn yet.
- **Leaves:** up close, leaves are crossed planes of large leaves, but the shape the game draws them in at a distance (`lod0Shape`, e.g. `block/plant/leaves/normal-lod0`) holds a plain cube, an element from 0 to 16 on every axis, in their small leaves. A block whose shape at a distance holds such a cube, unturned, is drawn as it, each face in the texture the element names for it. Branchy leaves name their colour maps on the element rather than the block type, and are tinted by those, in the coloured map too. The texture's holes take the block's average colour, tinted. 237 of 1.22.7's 245 leaves are cubes this way; narrow leaves, such as cypress's, have none.
- **A face's texture** is the one named for it (`up`, `south`, `east`), else its group's (`verticals` for top and bottom, `horizontals` for the sides), else `all`, found as for [Texture colours](#texture-colours). Its overlays are drawn over it, each stretched or shrunk to its size.
- **Variants:** a base ending in `*` has every file it starts as a variant, by name, so a field of one block doesn't repeat one picture (vsapi `CompositeTexture.Bake`, and `Block.FastTextureVariants` for cubes). A block shows the variant its position picks, by vsapi's position hash, [`GameMath.MurmurHash3Mod`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Math/GameMath.cs)`(x, y, z, count)`, the same for every face; a layer with fewer variants than the block's others counts round again. The game picks in closed code, so whether it hashes the same way isn't checked. A variant that can't be read is left out.
- **Tint:** a block with a climate or season colour map has every face tinted, except grassy soil (drawtype `TopSoil`: soil, forest floor, peat, clay), which is its soil's texture with grass over it. The grass is its `specialSecondTexture`, twice as wide as high: the right half is the top, the left half the sides' fringe. Only the grass is tinted.

In 1.22.7 with Primitive Survival, 2,040 of the 14,781 blocks are cubes, with 2,089 distinct face images; 544 cubes have variants, up to 10.

The renderer draws each cube once when a render starts, into a 32-pixel square ([`src/renderer/isometric.zig`](../src/renderer/isometric.zig), `pictureOf`): each pixel of a face averages its texture at 2 × 2 points across it, a 32-texel texture giving about 4 texels a pixel, and is lit as the relief style lights that face. The plain and tinted layers stay apart: where a block is drawn, its tinted layer is multiplied by the block's tint there ([Climate and season tint](#climate-and-season-tint), steps 1 to 4, at the block's own height) and drawn over the plain one by how much of each pixel it covers. Blocks that aren't cubes take their average colour times the tint.

### Preparing blocks

Everything a map needs from the assets is prepared once, by [`src/vs/Prepared.zig`](../src/vs/Prepared.zig), into a blocks folder: `blocks` in the current folder, beside a render's `out`, or the one given (`--blocks` when rendering, the folder argument of `storymap prepare`). For each block, that's its code, its material, its colour code ([Block colours](#block-colours)), its texture colours ([Texture colours](#texture-colours)), its colour maps ([Climate and season tint](#climate-and-season-tint)) and its cube faces ([Cube faces](#cube-faces)), in `<blocks folder>/<key>/blocks.txt`. The colour maps' images are beside it in `colormaps/`, and the face images in `textures.bin`, as RGBA pixels (8.6 MB for 1.22.7).

- **One set per game and mods:** the key changes with the game version and the mods (their names, sizes and times), so updating either prepares a new set, and switching back finds the old one.
- **On demand:** a render prepares the set it needs if it isn't there yet. `--prepare` prepares it again anyway, and `storymap prepare` does only that.
- **Without the game**, a render uses the newest set prepared before, so a set copied from another machine works.
- **A save's unknown blocks are reported:** those of mods that aren't installed, and any others the prepared set doesn't have.

Preparing 1.22.7 with Primitive Survival takes about 2 s, for 14,781 blocks, most of it reading and decoding textures.

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
- **Layout:** `<output>/<view>/<level>/<x>/<y>.png`, e.g. `out/topdown/0/1000/999.png`. Beside them, `map.json` describes the world and each view with the tiles it has, and `index.html` is the viewer.
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
