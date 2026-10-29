# Prepared blocks file (`.storyblk`)

A `.storyblk` file holds what a render needs to know about a game's blocks, prepared once from the game's and mods' assets ([Preparing blocks](../blocks.md#preparing-blocks)), with the isometric view's sprites of them. A render maps the file and reads its sprites in place, and [viewer.html](viewer.html) shows its sprites in a browser.

Storymap doesn't read or write this format yet; this is its specification.

## 1. Use

Storymap keeps one file, `prepared.storyblk` in the current folder, or the one given on the command line (`--blocks` when rendering, the argument of `storymap prepare`). Its hash (§6) tells Storymap whether the file was prepared from the game and mods it's running with, by a Storymap that prepares and draws the same way. Without the game, which the hash depends on, each section's `generator_version` (§7) and `sprites.block_width` still tell it whether the file was made the same way. When Storymap prepares the file again is Storymap's choice ([Preparing blocks](../blocks.md#preparing-blocks)), not the format's.

A writer writes a new file beside the old one, under the name `<file name>.<process id>.partial`, and renames it over the old file once it's complete, so an interrupted write leaves the old file whole. It removes the partial file if writing or renaming fails. It never replaces a file that doesn't start with the magic `STORYBLK`.

## 2. Conventions

All integers are little-endian. `[n]T` is n values of type T one after another. The types are in §4. Indexes count from 0. `part.field` is a field of one of the parts in §3, e.g. `blocks.count`.

Bits and fields this document doesn't describe are 0 when written and ignored when read. A new bit or field that readers must understand changes a layout version (§7).

`blocks.entries` has one Block for each block. The other sections are tables a Block points into: `materials`, `colour_codes`, `texture_colours`, `colour_maps` and `sprites` by index, and each Sprite into `sprite_layers` by offset. `domains` stands on its own.

A block's sprites come in variants of its textures ([Cube faces](../blocks.md#cube-faces)), in each of the shapes it picks one of, its own and then its shape's alternates, and in each of its turns if it's turned by where it is ([Shapes](../blocks.md#shapes)). Which variant, alternate and turn a block shows is picked by where it is, as those sections describe.

A cube's square is the square a cube's sprite is drawn in, `sprites.block_width` pixels wide: the cube's top is a diamond as wide as the square and half as tall, and its sides reach down the other half. A block at (x, y, z), with x east, y up and z south, has its square at ((x − z − 1) × w / 2, (x + z) × w / 4 − (y + 1) × w / 2) pixels, w being `sprites.block_width`, moved by its `draw_offset` ([Shapes](../blocks.md#shapes)). A pixel's depth in the world is (x + y + z) × 256 plus its value in `depths`: the larger, the nearer the viewer, who looks north-west from above.

## 3. Layout

`header`, `info` and `section_table` come first, in that order, from the start of the file. `header` is 24 bytes, so `header.hash` can be read without reading the rest. Each section starts on a multiple of 8 bytes from the start of the file, after `section_table`, and lies wholly within the file. A section's length doesn't count the bytes after it up to the next multiple of 8, which are 0. A file has each of the sections below once, and a reader skips sections whose names it doesn't know. They can be in any order; Storymap writes them in the order below, so the pixel data in `sprite_layers` comes last.

`sprites` and `sprite_layers` are read where the file is mapped: every integer in them lies at a multiple of its own size, and every Sprite and SpriteLayers at a multiple of 4. The other sections are read a field at a time: strings of any length put the integers after them anywhere.

### `header`

| Field | Type | Contents |
| --- | --- | --- |
| `magic` | [8]u8 | `STORYBLK` |
| `version` | u8 | the container's version, 1 (§7) |
| `reserved` | u8 | 0 |
| `section_count` | u16 | – |
| `info_length` | u32 | bytes in `info` |
| `hash` | u64 | §6 |

### `info`

| Field | Type | Contents |
| --- | --- | --- |
| `game` | [String](#string) | `vintagestory` |
| `game_version` | [String](#string) | e.g. `1.22.7`; empty if unknown |
| `mod_count` | u16 | – |
| `mods` | \[mod_count][Mod](#mod) | every zip in `Mods/` that can be read, and every folder in it with an `assets/` folder, in byte order of their names; a later one's assets replace an earlier one's |

### `section_table`

| Field | Type | Contents |
| --- | --- | --- |
| `entries` | \[header.section_count][Section](#section) | – |

### `blocks`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u32 | – |
| `entries` | \[count][Block](#block) | one for each block |

### `materials`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u8 | – |
| `entries` | \[count][String](#string) | the materials blocks are of, each once, e.g. `Stone`, `Plant` |

### `colour_codes`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u8 | – |
| `entries` | \[count][String](#string) | the codes that pick a block's colour on the game's map, each once, e.g. `land`, `forest` ([Block colours](../blocks.md#block-colours)) |

### `texture_colours`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u32 | – |
| `entries` | \[count][TextureColours](#texturecolours) | one for each texture a block takes its colour or grain from |

The section is 4 + 93 × `count` bytes long.

### `colour_maps`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u8 | – |
| `entries` | \[count][ColourMap](#colourmap) | – |

### `domains`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u16 | – |
| `entries` | \[count][String](#string) | the domains the game and mods have assets in ([Mods](../rendering.md#mods)), e.g. `game`, `primitivesurvival` |

### `sprites`

| Field | Type | Contents |
| --- | --- | --- |
| `count` | u32 | – |
| `block_width` | u16 | the width of a cube's square, in pixels: 32 |
| `reserved` | u16 | 0 |
| `entries` | \[count][Sprite](#sprite) | one for each image a block is drawn with |

The section is 8 + 16 × `count` bytes long.

### `sprite_layers`

| Field | Type | Contents |
| --- | --- | --- |
| `entries` | [SpriteLayers](#spritelayers), one for each [Sprite](#sprite) | each at its Sprite's `offset`, to the end of the section |

## 4. Types

### String

| Field | Type | Contents |
| --- | --- | --- |
| `length` | u16 | – |
| `text` | [length]u8 | UTF-8 |

### Mod

| Field | Type | Contents |
| --- | --- | --- |
| `file` | [String](#string) | its zip or folder name in `Mods/` ([Mods](../rendering.md#mods)), e.g. `primitivesurvival_5.1.4.zip` |
| `id` | [String](#string) | the `modid` in its `modinfo.json`, e.g. `primitivesurvival` |
| `name` | [String](#string) | the `name` in its `modinfo.json`, e.g. `Primitive Survival` |
| `version` | [String](#string) | the `version` in its `modinfo.json`, e.g. `5.1.4` |

`id`, `name` and `version` are empty where `modinfo.json` doesn't give them, or the mod has none.

### Section

| Field | Type | Contents |
| --- | --- | --- |
| `offset` | u64 | where the section starts, from the start of the file |
| `length` | u32 | bytes in the section |
| `layout_version` | u8 | the version of the section's layout (§7) |
| `generator_version` | u16 | the version of the code that made the section's contents (§7) |
| `name` | [String](#string) | one of the section names in §3, e.g. `blocks` |

### TextureColours

A texture's colours, which the game's colour-accurate map draws a block with ([Texture colours](../blocks.md#texture-colours)). 93 bytes.

| Field | Type | Contents |
| --- | --- | --- |
| `average` | [3]u8 | red, green and blue |
| `grain` | [30][3]u8 | red, green and blue of 30 of its pixels |

### ColourMap

A colour map that a block's colour is multiplied by, by climate or by season ([Climate and season tint](../blocks.md#climate-and-season-tint)). A colour map without an image, or whose image can't be decoded or isn't wider and taller than twice its padding, is left out, and blocks that name it name none.

| Field | Type | Contents |
| --- | --- | --- |
| `code` | [String](#string) | e.g. `climatePlantTint` |
| `padding` | u8 | pixels around the image's edge that aren't part of the map |
| `flags` | u8 | bit 0: a tropical season map, weighted by rainfall rather than temperature |
| `image_length` | u32 | – |
| `image` | [image_length]u8 | a PNG, wider and taller than twice `padding` |

### Block

| Field | Type | Contents |
| --- | --- | --- |
| `code` | [String](#string) | its code as a save names it, with its domain unless that's `game`, e.g. `rock-granite`, `primitivesurvival:…` ([Block codes](../blocks.md#block-codes)); each code appears once |
| `material` | u8 | its index in `materials.entries` |
| `colour_code` | u8 | its index in `colour_codes.entries` |
| `colour` | u32 | the index in `texture_colours.entries` of the TextureColours whose `average` is its colour; 0xFFFFFFFF for none |
| `grain` | u32 | the index in `texture_colours.entries` of the TextureColours whose `grain` is its grain; 0xFFFFFFFF for none |
| `climate_colour_map` | u8 | its index in `colour_maps.entries`; 0xFF for none |
| `season_colour_map` | u8 | its index in `colour_maps.entries`; 0xFF for none |
| `height` | u8 | how high its selection box reaches, in sixteenths of a block, at most 254 ([Cube faces](../blocks.md#cube-faces)); 0xFF where its block type gives none, taken as the whole block |
| `draw_offset` | u8 | its block type's `randomDrawOffset`, 1 for `true`: the larger, the less it's moved off the middle of its place by where it is; 0 for not moved ([Shapes](../blocks.md#shapes)) |
| `flags` | u8 | bit 0: the variant, alternate and turn of its sprite are picked by x and z alone, with y as 0 (`randomizeAxes: xz`); bit 1: it's turned by where it is (`randomizeRotations`); bit 2: it's drawn in its shape, rather than as a cube; bit 3: any of its sprites has a tinted layer |
| `first_sprite` | u32 | the index of its first Sprite in `sprites.entries` |
| `variants` | u16 | 0 for a block without sprites |
| `alternates` | u16 | at least 1 when `variants` isn't 0 |
| `turns` | u8 | at least 1 when `variants` isn't 0 |

A block's sprites are a run of `variants` × `alternates` × `turns` Sprites in `sprites.entries` (§2). The Sprite at index `first_sprite + (turn × alternates + alternate) × variants + variant` is that variant of that alternate, in that turn. Blocks drawn from the same textures, in the same shapes and turns, share their sprites: their `first_sprite`, `variants`, `alternates` and `turns` are the same. Blocks drawn from different textures have sprites of their own, even where those look the same.

### Sprite

16 bytes.

| Field | Type | Contents |
| --- | --- | --- |
| `offset` | u32 | where its SpriteLayers start, from the start of the `sprite_layers` section; a multiple of 4 |
| `left` | i16 | where its top left pixel is, from the top left of the cube's square |
| `top` | i16 | – |
| `width` | u16 | – |
| `height` | u16 | – |
| `flags` | u32 | bit 0: it has a tinted layer; bit 1: it shows every pixel a cube's top and sides cover, so nothing behind the block shows |

A sprite of a shape that reaches out of its block extends past the square, so `left` and `top` can be negative, and `width` and `height` larger than `sprites.block_width`. A shape with nothing to draw has a sprite 0 pixels wide and high.

### SpriteLayers

| Field | Type | Contents |
| --- | --- | --- |
| `plain` | [width × height][4]u8 | red, green, blue and alpha, row by row; opaque where the block is |
| `tinted` | [width × height][4]u8 | only with Sprite bit 0: lit but not yet tinted, its alpha how much of the pixel it covers |
| `depths` | [width × height]i16 | x + y + z of each pixel's point, the block being from 0 to 1, in 256ths (§2) |
| `padding` | [0 or 2]u8 | 0, to a multiple of 4 |

A render multiplies the tinted layer by the block's climate and season tint ([Climate and season tint](../blocks.md#climate-and-season-tint)) and draws it over the plain layer by its alpha.

## 5. Validity

A reader rejects the whole file when:

- it doesn't start with `STORYBLK`, or `header.version` is one the reader doesn't know
- `info` or `section_table` goes past the end of the file, or `info`'s fields go past `header.info_length` bytes
- a section the reader needs is missing, appears twice, has a `layout_version` the reader doesn't know, starts before the end of `section_table` or not on a multiple of 8, or doesn't lie wholly within the file
- a section's fields go past its length
- a Block's `material` isn't below `materials.count`, its `colour_code` isn't below `colour_codes.count`, its `colour` or `grain` isn't below `texture_colours.count` and isn't 0xFFFFFFFF, or its `climate_colour_map` or `season_colour_map` isn't below `colour_maps.count` and isn't 0xFF
- a Block has `variants` but no `alternates` or `turns`, or its sprites go past the last Sprite
- the length of `texture_colours` or `sprites` isn't the one §3 gives
- a Sprite's `offset` isn't a multiple of 4, or its SpriteLayers go past the end of `sprite_layers`

## 6. Hash

`header.hash` is a 64-bit hash of everything the file's contents depend on:

- the container's version, and each section's `layout_version` and `generator_version`
- the block width
- the game and its version
- each mod, in the order of `info.mods`: its zip or folder name in `Mods/`, and for a zip, its size and modification time, or for a folder, the modification time of each folder in its `assets/`

It depends on file times, so the same game and mods give a different hash on another machine: it's for checking, not for naming. Readers other than Storymap don't need it; `info` names the game and mods.

## 7. Versions

A layout version says how to read something, and a generator version how its contents were made:

- The container's version, `header.version`, changes when `header`, `info` or `section_table` change.
- A section's `layout_version` changes when that section's layout changes. In container version 1, every section's `layout_version` is 1.
- A section's `generator_version` changes when the code that makes its contents changes without the layout changing: a block read differently, or a sprite drawn differently. Storymap gives `blocks`, `materials`, `colour_codes`, `texture_colours`, `colour_maps` and `domains` the version of how it reads the game's assets, and `sprites` and `sprite_layers` the version of how it draws sprites.

A reader rejects a file with a layout version it doesn't know (§5). A `generator_version` other than the reader's own doesn't make the file invalid: the section was made by other code, and what to do with it is the reader's choice. Readers that only show the file go on reading it. Storymap, with the game, finds the hash different (§6) and prepares the file again; without it, it compares the generator versions themselves (§1).
