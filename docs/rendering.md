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

storymap's current heightmap reads only the solid layer (field 1) and scans blocks itself.

## Assets

Blocks are defined by data files, not code *(Wiki)*:

- **Block types:** JSON in `blocktypes/`, with variant groups and per-variant properties. *([Wiki: Asset Type – BlockTypes](https://wiki.vintagestory.at/Modding:Asset_Type_-_BlockTypes))*
- **Shapes:** JSON in `shapes/`, normally made with the official Model Creator: boxes with per-face texture references, rotations and nested children. *([Wiki: Asset Type – Shapes](https://wiki.vintagestory.at/Modding:Asset_Type_-_Shapes))*
- **Textures:** PNG in `textures/`, referenced from block types and shapes by name. *([Wiki: Asset Type – Textures](https://wiki.vintagestory.at/Modding:Asset_Type_-_Textures))*

These are the game developers' copyrighted assets, so storymap never ships them: every user points storymap at their own game install (and mods) and storymap extracts what it needs. That's also the only way modded blocks render correctly.

Where they live *(Verified (1.22.7): a fresh Windows install)*:

- **Game install** (`%APPDATA%\Vintagestory` on Windows): `assets/<domain>/` with one folder per domain, `creative`, `game` and `survival`, each containing `blocktypes/`, `shapes/`, `textures/` and more. `assets/version-1.22.7.txt` names the version. The install's own `Mods/` folder holds only the built-in code (`VSSurvivalMod.dll`, `VSEssentials.dll`, `VSCreativeMod.dll`) and a `do_not_add_mods_here.txt`.
- **Data folder** (`%APPDATA%\VintagestoryData`): `Saves/`, and `Mods/` with user mods as zip files (e.g. `primitivesurvival_5.1.4.zip`). How a mod zip lays out its assets is still to be checked. There's also a `Maps/` folder with one small `.db` file per world, probably the client's world-map cache; not looked into.

## Block entities that change how things look

From the sample save (class counts in [`save-format/README.md` §5](save-format/README.md#5-block-entities-field-8)):

- **Chiseled blocks** (`MicroBlock`, `Chisel`): the shape is fully in the save as 16³-voxel cuboids with block-ID materials. Top-down: take the top voxel of each 16 × 16 sub-column. Isometric: draw the boxes with each material's texture. No model files needed.
- **Ground storage** (`GroundStorage`): item stacks placed on the ground (firewood, planks, ingots…). Needs item stack parsing and item models.
- **Containers, displays and decorations** (`GenericTypedContainer`, `Crate`, `DisplayCase`, `Tapestry`, `TorchHolder`, …): the base look comes from the block's own shape; contents and variants come from the block entity.

## Isometric reference

[Mapcrafter](https://github.com/mapcrafter/mapcrafter) renders Minecraft worlds as isometric tiles for a web map. It's the model for storymap's isometric output; its approach hasn't been studied in detail here yet.
