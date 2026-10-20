# Vintage Story save format

The text reference for how a Vintage Story `.vcdbs` save is laid out, as far as Storymap has worked it out. [`index.html`](index.html) in this folder is an interactive explainer built from this file; when the two disagree, this file wins and the HTML needs updating.

## Versions

| Version | Status |
| --- | --- |
| 1.19.1, 1.19.2 | **Verified** against a sample save written by both versions (6,880 chunks: 4,928 by 1.19.1, 1,952 by 1.19.2). |
| 1.22.7 (current) | **Verified** against a new world (6,224 chunks, all written by 1.22.7): schema, positions, chunk fields, block and liquid decoding, and the block entity format; chiseled blocks and ground storage against a larger 1.22.7 world. Claims marked **Source** also come from the 1.22.7 code. |

Version-specific differences are noted inline, in the section they affect, as **1.19:** / **1.22:** notes. If a later version changes the format so much that inline notes stop being readable, split that version into its own file. The game's developer has said they'll look at how saves are stored and compressed, likely for 1.23. *([Forum](https://www.vintagestory.at/forums/topic/19778-understanding-and-improving-the-games-savefiles-serialization-and-compression/), Tyron's reply.)*

## How claims are sourced

Every section says where its information comes from:

- **Verified (1.19):** checked against a sample save written by 1.19.1 and 1.19.2, with how it was checked.
- **Verified (1.22.7):** checked against a fresh 1.22.7 world with two explored areas far apart (6,224 chunks), or, where it says "the larger 1.22.7 world", a more compact one of 3,649 chunk columns and 29,192 chunks.
- **Source:** read in Vintage Story's open-source code on GitHub ([vsapi](https://github.com/anegostudios/vsapi), [vssurvivalmod](https://github.com/anegostudios/vssurvivalmod), [vsessentialsmod](https://github.com/anegostudios/vsessentialsmod)). Links are pinned to the commits read on 2026-10-10, each repository's "Updated to Version 1.22.7" commit: vsapi `63d33f7`, vssurvivalmod `849fa8c`, vsessentialsmod `06673b6`. Pin new links to a commit or tag too, never `master`. The chunk storage code itself is in the closed engine library and isn't available.
- **Schema:** the names, numbers and types of every table's Protobuf fields, from [vs-proto](https://github.com/bluelightning32/vs-proto), which generates a Protobuf schema from the serialisation attributes on the game's own classes. Its [`schema-1.21.0.rc.3.proto`](https://github.com/bluelightning32/vs-proto/blob/80ff05afa98af324425ef6f3e5f12b4bea9e6a3f/schema-1.21.0.rc.3.proto) (commit `80ff05a`) is for 1.21.0-rc.3; fields 1.22.7 writes that it doesn't list are marked as such.
- **Wiki:** the [Vintage Story wiki](https://wiki.vintagestory.at/), above all its [VCDBS format](https://wiki.vintagestory.at/Modding:VCDBS_format) page (checked there for 1.19.8), which decodes each table with the schema above.
- **Forum:** [Understanding and improving the game's savefiles](https://www.vintagestory.at/forums/topic/19778-understanding-and-improving-the-games-savefiles-serialization-and-compression/), a modder's study of how the game stores chunks, with a reply from the game's developer.
- **Unverified:** an observation or guess that hasn't been confirmed.

The test saves aren't in the repo.

## 1. The save file

A `.vcdbs` file is an SQLite database. Saves live in the game's data folder under `Saves/`; on Windows that's `%APPDATA%\VintagestoryData\Saves`. *(Verified (1.22.7): a fresh Windows install.)*

Saves use SQLite's [write-ahead log](https://www.sqlite.org/wal.html): bytes 18 and 19 of the file header are 2 in both test saves. In that mode even a read-only connection creates `-shm` and `-wal` files next to the database, so a tool that opens a save in place writes into the game's `Saves` folder. Read a copy, or open the file with SQLite's [`immutable=1`](https://www.sqlite.org/uri.html) URI parameter, which creates nothing; Storymap does the latter. The catch: an immutable open ignores the `-wal` file, and while the game is running (or after a crash) that file holds changes not yet written into the save. A non-empty `-wal` next to a save means a map of it may be missing recent changes. *(Verified (1.19, 1.22.7): read-only opens of the copies created both files; `immutable=1` didn't, also with spaces, `%` and non-ASCII characters in the file name.)*

Schema, verbatim *(Verified (1.19, 1.22.7): identical `sqlite_master` in both saves)*:

```sql
CREATE TABLE chunk (position integer PRIMARY KEY, data BLOB)
CREATE TABLE mapchunk (position integer PRIMARY KEY, data BLOB)
CREATE TABLE mapregion (position integer PRIMARY KEY, data BLOB)
CREATE TABLE gamedata (savegameid integer PRIMARY KEY, data BLOB)
CREATE TABLE playerdata (playerid integer PRIMARY KEY AUTOINCREMENT, playeruid TEXT, data BLOB)
CREATE TABLE sqlite_sequence(name,seq)
CREATE INDEX index_playeruid on playerdata(playeruid)
```

| Table | Rows in sample | `data` message | Contents |
| --- | --- | --- | --- |
| `chunk` | 6,880 | `ServerChunk` | One 32 × 32 × 32 cube of blocks per row. "Chunks do not span the world height." *([Wiki: WorldGen Concept](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))* |
| `mapchunk` | 860 | `ServerMapChunk` | One row per chunk column: "information on a chunk column, such as the rain height or snow accumulation." *([Wiki](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))* |
| `mapregion` | 20 | `ServerMapRegion` | "Information over an area of 16x16 chunk columns, such as weather and maps required for world generation." *([Wiki](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))* (§8) |
| `gamedata` | 1 | `SaveGame` | The save's global data (429,515 bytes in the sample): the block and item names, world size and settings (§6). |
| `playerdata` | 1 | `ServerWorldPlayerData` | One row per player who has joined, keyed by `playeruid`: their inventories, game mode, death count and the player entity, which holds their position. Privileges aren't here but in JSON files in the data folder's `Playerdata` folder. *([Wiki: VCDBS format](https://wiki.vintagestory.at/Modding:VCDBS_format).)* |

`sqlite_sequence` is SQLite's own table for `AUTOINCREMENT`, not game data. The message names are the game's classes, from the schema; `gamedata` has a single row whose `savegameid` is 1. *(Schema; wiki.)*

**1.22.7:** the new world has 6,224 chunks, 778 map chunks, 32 map regions, and one row each in `gamedata` and `playerdata`.

### How the tables fit together

The world is a grid of blocks, stored at three scales:

| Scale | Size in blocks | Table | Dimensions | Key |
| --- | --- | --- | --- | --- |
| **Chunk** | 32 × 32 × 32 | `chunk` | 3D: x, z and y | chunk x, z and y (§2) |
| **Chunk column** | 32 × 32, the world's full height | `mapchunk` | 2D: x and z | chunk x and z, the same as its chunks' keys without y |
| **Map region** | 512 × 512 (16 × 16 chunk columns) | `mapregion` | 2D | region x and z *(inferred, §2)* |

- **A chunk column** is the stack of chunks with the same x and z: 8 chunks in a 256-block-high world (y 0–7). Only generated chunks are saved, so a column can have gaps.
- **`chunk` holds the blocks**, one row per cube (§3–§5). It's the only table with blocks in it.
- **`mapchunk` holds per-column summaries**, one row per chunk column (§7): for each of its 32 × 32 block columns, a few numbers, such as the height of the highest block rain can't fall through. It's a 2D layer over the 3D chunks.
- **`mapregion` holds coarser world generation data** over 16 × 16 chunk columns (§8).

Finding things from a block position (x, y, z), all in absolute block coordinates:

1. **Its chunk** is (x ÷ 32, y ÷ 32, z ÷ 32), rounded down; that's the `chunk` row's key (§2). Inside it, the block is at local (lx, ly, lz) = (x mod 32, y mod 32, z mod 32), index `(ly·32 + lz)·32 + lx` in the block arrays (§4).
2. **Its chunk column's map chunk** has the same key without y. The block column's values are at index `lz·32 + lx` in each per-column map (§7).

This is what makes a top-down map cheap: the map chunk gives each block column's surface height, which names the one chunk that holds the surface block, so only those chunks need reading. In the test saves, the surface lies in 1,074 of 6,224 chunks (1.22.7) and 1,345 of 6,880 (1.19): most chunk columns need one chunk, a few two or more. *(Verified (1.19, 1.22.7): the distinct chunks the rain heights of §7 fall in.)*

## 2. Positions

`chunk.position` is a 64-bit integer packing the chunk's coordinates and its dimension *([Wiki: VCDBS format](https://wiki.vintagestory.at/Modding:VCDBS_format#ChunkPos). Verified (1.19): decoding gives a contiguous block of chunks, and decoding the blocks with these coordinates renders continuous terrain. Verified (1.19, 1.22.7): in every test save, the guard, dimension and reserved bits are 0 in every `chunk`, `mapchunk` and `mapregion` position)*:

| Bits | Field |
| --- | --- |
| 0–20 | x (21 bits) |
| 21 | guard, 0 |
| 22–26 | dimension, low 5 bits |
| 27–47 | z (21 bits) |
| 48 | guard, 0 |
| 49–53 | dimension, high 5 bits |
| 54–62 | y (9 bits) |
| 63 | reserved, 0 |

```zig
const Position = packed struct(u64) {
    x: u21,
    guard1: u1,
    dimensionLow: u5,
    z: u21,
    guard2: u1,
    dimensionHigh: u5,
    y: u9,
    reserved: u1,
};
```

- These are chunk coordinates: chunk (x, y, z) holds blocks x·32 … x·32+31, and so on. The field widths are the game's limits: 2²⁶ blocks across (`MaxWorldSizeXZ`) is 2²¹ chunks, and 16,384 blocks high (`MaxWorldSizeY`) is 512 chunks. *(Source: [vsapi `GlobalConstants.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Config/GlobalConstants.cs).)*
- Bit 63 is never set, so positions are never negative, though SQLite integers are signed.
- **Dimensions** are separate block spaces stored in the same tables: 0 is the normal world, 1 holds mini-dimensions (WorldEdit previews, vehicles and the like, each a separate cube of blocks) and 2 the time-switched alternate world, such as the Devastation. *(Source: [vsapi `Dimensions.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Config/Dimensions.cs).)* A map of the world should only draw dimension 0. Reading the dimension bits as part of x and z, as a 27-bit split does, would put other dimensions' chunks millions of blocks away. The test saves have only dimension 0, though `gamedata` counts one mini-dimension created in the 1.22.7 worlds (§6).
- Coordinates are absolute. The game shows x and z shifted from these by half the world size (`gamedata` fields 1 and 3, §6), so that the world's centre, the default spawn point, is 0, 0; it shows y as it is. *(Verified (1.22.7): a player in a 1,024,000-block world noted the game showing 409, 111, −304 while standing on the ground. That column's rain height (§7) is 110, so their feet were at 111, and the save holds the player at block (512,409.0, 193.9, 511,699.3) after they flew up and moved a few blocks before it was saved: x is 512,409 − 512,000 = 409, and z −300.7. Storymap's viewer shifts positions the same way.)*

`mapchunk.position` uses the same packing with y = 0, one row per chunk column. *(Verified (1.19): the 860 `mapchunk` positions are exactly the 860 distinct (x, z) columns in `chunk`. Verified (1.22.7): likewise, 778 and 778.)*

**1.22.7:** the new world's chunks form two separate areas: a 15 × 15-column square centred on chunk (16000, 16000), which is block (512,000, 512,000), the middle of a 1,024,000-block world; and a round area centred on the player at block (514,605, 120, 515,605), chunk (16081, 3, 16112), 2,605 blocks east and 3,606 blocks south of the centre. The player didn't move after spawning. The world's `spawnRadius` is 5,000 (§6), so the game places a new player up to 5,000 blocks from the centre; this one is about 4,450 blocks away. The square is presumably generated at the default spawn point before the game picks the actual one. *(Observed: the player's position is the only triple of doubles in the world's coordinate range in `playerdata`, stored three times; the player format itself isn't decoded. The spawn radius is verified; why the square is generated isn't.)*

`mapregion.position` uses the same packing with the region's own coordinates: chunk coordinates ÷ 16, rounded down. In the sample it decodes to x 997–1001, z 998–1001, where the chunks are at x 15979–16010. *(Verified (1.19, 1.22.7): in every test save the region keys span the chunks' coordinates ÷ 16, plus one region on each side.)* The wiki describes the key as the position of the region's north-west chunk instead, which would be about 16,000 here.

## 3. Chunk data: Protobuf fields

`chunk.data` is a [Protobuf](https://protobuf.dev/programming-guides/encoding/) message: a sequence of `(field number, wire type, value)` entries with no schema in the file. Storymap parses it with [`lib/protobuf/ProtoBuf.zig`](../../lib/protobuf/ProtoBuf.zig).

The names are the schema's (`ServerChunk`).

| # | Wire type | Name | Chunks containing it (of 6,880) | Status |
| --- | --- | --- | --- | --- |
| 1 | bytes | `blocksCompressed` | 6,880 | **Decoded** (§4) |
| 2 | bytes | `lightCompressed` | 6,880 | **Light**, the bit planes (below) |
| 3 | bytes | `lightSatCompressed` | 6,880 | **Light**, the palette (below) |
| 5 | varint | `EntitiesCount` | 131 | Present in the chunks with field 6 |
| 6 | bytes, repeated | `EntitiesSerialized` | 131 (312 entries) | One entity per entry: two strings, the entity's class (`EntityAgent`, `EntityItem`, `EntityFish`, …) and the game version that wrote it, then its data, not decoded. Strings as in §5. |
| 7 | varint | `BlockEntitiesCount` | 539 | Present in the chunks with field 8 |
| 8 | bytes, repeated | `BlockEntitiesSerialized` | 539 (14,447 entries) | **Decoded** (§5) |
| 9 | | `moddata` | 0 | Mods' data, by mod |
| 10 | varint, repeated | `lightPositions` | 123 (27,951 entries) | Unknown |
| 11 | | `ServerSideModdata` | 0 | Mods' data kept on the server |
| 12 | bytes | `GameVersionCreated` | 6,880 | **Decoded:** UTF-8 text, e.g. `1.19.1`; by its name, the version that created the chunk, so one save can mix versions. |
| 13 | varint | `EmptyBeforeSave` | 1,528 | A bool, 1 wherever it's present. Only on chunks with light, nearly all of them sunlit throughout, so perhaps chunks of open air. *(Unverified.)* |
| 14 | bytes | `DecorsSerialized` | 6,880 | Decor: a sparse map keyed by block position and decor index, the face of the block it's on and, for cave art, a spot on a 16 × 16 grid on that face *([Wiki: VCDBS format](https://wiki.vintagestory.at/Modding:VCDBS_format#chunk))*. Not decoded. |
| 15 | varint | `savedCompressionVersion` | 6,880 | 2 in every chunk of every test save; `gamedata` field 37 is 2 as well (§6) |
| 16 | bytes | `liquidsCompressed` | 6,880 | **Liquids**, same format as field 1 (§4). Above a deep lake bed in the 1.22.7 world, chunks y 0–3 have the liquid palette `[0, 2966]`; 2966 is `water-still-7` (§6). |
| 17 | varint | `BlocksPlaced` | 8 | A count |
| 18 | varint | `BlocksRemoved` | 2 | A count |

*(Verified (1.19): counts and wire types from scanning every chunk in the sample. Verified (1.19, 1.22.7): fields 6 and 13 as described, in every chunk of every test save.)*

**1.22.7:** the same field numbers with the same wire types. Field 12 is `1.22.7` in every chunk. Field 14 appears in only 350 of 6,224 chunks (every chunk in 1.19), and fields 17 and 18 don't appear. *(Verified (1.22.7).)*

The wiki lists what a chunk contains: solid blocks, fluid blocks, block entities, entities, decor, mod data and format version metadata. *([Wiki: Chunk Data Storage](https://wiki.vintagestory.at/index.php/Modding:Chunk_Data_Storage))*

### Light: fields 2 and 3

Light is a layer of the same kind as blocks (§4), a palette and bit planes, but split across two fields, each one whole zstd frame with no length in front:

- **Field 3 is the palette:** `i32` light values, the first always 0. Despite its name, it holds nothing but the palette.
- **Field 2 is the bit planes:** planes of 1,024 `i32`s, as many as the palette needs by the same rule as blocks (§4), read the same way.

A light value packs several levels into one number:

| Bits | Value |
| --- | --- |
| 0–4 | Sunlight: 0–22 in the test saves, 22 under open sky |
| 5–9 | Light from blocks, such as torches: 0–18 |
| 10–14, 15–19 | Non-zero exactly where bits 5–9 are; probably the colour of that light *(Unverified)* |

When both fields are empty, the chunk stores no light. Chunk columns get light when world generation reaches stage 4 (§7): every column at stage 4 or later has light, and in the 1.22.7 world no column before it does. In the 1.19 sample, 16 earlier columns have light in their lowest chunks only (y 0–2). In columns with light, most chunks at the bottom levels store none, presumably being dark all through. A few chunks hold frames that decompress to nothing.

*(Verified (1.19, 1.22.7): in every chunk with light, 3,539 in the 1.19 sample and 2,519 in the 1.22.7 world, field 2 has exactly the planes field 3's palette needs, and the palette starts with 0. Stages checked column by column: in the 1.22.7 world the 490 columns with light are exactly those at stage 4 or later; in the sample, 624 at stage 4 or later and the 16 earlier ones.)*

**Earlier observations** (from an older sample save, no longer in the repo): fields seen were 1, 2, 3, 6, 8, 12, 14, 16; fields 6 and 8 repeat; changing one solid block changed fields 1, 2 and 3. The 1.19 sample shows that fields 5, 7, 13, 17 and 18 also appear, but only in some chunks.

## 4. Blocks: fields 1 and 16

*(Verified (1.19) unless noted: decoding the one-block chunk at chunk (15995, 4, 15999) finds exactly one non-air block, palette ID 164, at local (5, 7, 18); decoding the whole save renders a continuous heightmap. Decoding code: [`src/vs/Compression.zig`](../../src/vs/Compression.zig). Read side: `Chunk.getBlock` in [`src/vs/Chunk.zig`](../../src/vs/Chunk.zig), commit `a314adf`.)*

### Layout

```
[ i32 length ][ palette: |length| bytes ][ zstd frame: bit planes ]
```

All integers are little-endian.

- **`length`:** negative means the palette is stored raw, `-length` bytes. Positive means it's a zstd frame of `length` bytes. Zero means the chunk has no blocks.
- **Palette:** an array of `i32` block IDs, the distinct block types in this chunk. Entry 0 is air (ID 0). A palette with one entry (only air) means an empty chunk.
- **Bit planes:** the rest of the field is one zstd frame. It decompresses to `bits` planes of 1,024 `i32`s (4,096 bytes) each.

Real examples from the sample (both in chunk column x 15995, z 15999, written by 1.19.1):

| Chunk y | `length` | Palette | Planes |
| --- | --- | --- | --- |
| 4 | −8 (`f8 ff ff ff`) | raw, 2 entries: 0, 164 | 27 bytes → 4,096 bytes = 1 plane |
| 3 | 97 (`61 00 00 00`) | zstd, 97 → 88 bytes = 22 entries | 21 bytes → 20,480 bytes = 5 planes, all zero |

The y = 3 chunk shows that palettes aren't pruned: its blocks were removed, so every block is air, but the palette still lists 22 types.

### Palette rounding

The number of planes is `bits = ceil(log2(palette entries))`, and the palette is treated as having `2^bits` slots; `Layer.decode` in `src/vs/Compression.zig` computes this. Only the real entries are stored. Slots past them are never referenced in valid data, and a reader should treat them as air rather than read past the stored entries. (Storymap used to over-read here; fixed in commit `092de71`.)

### Block order and bit planes

Blocks are numbered x first, then z, then y:

```
n = (y * 32 + z) * 32 + x        // 0 … 32,767
```

Block `n`'s palette index is spread across the planes: bit `b` of the index is bit `n % 32` (counting from the least significant bit) of `i32` number `n / 32` in plane `b`.

```js
let index = 0;
for (let b = 0; b < bits; b++)
	index |= ((planes[b][n >> 5] >>> (n & 31)) & 1) << b;
return palette[index];     // block ID, 0 = air
```

A consequence: each `i32` holds one row of 32 blocks along x, at z = `word % 32`, y = `word / 32`.

Why bit planes rather than packing each block's bits side by side isn't documented. Likely reasons: adding a bit only appends a plane of zeros without moving existing bits, every block sits at the same bit position in every plane, and planes compress well. *(Inferred.)*

## 5. Block entities: field 8

Each field-8 entry is one block entity *(Verified (1.19): all 14,447 entries in the sample parse to exactly their last byte with the format below)*:

```
[ string: class name ][ tree attribute ]
```

Strings are .NET `BinaryWriter` strings: a 7-bit varint byte length, then UTF-8 bytes.

### Tree attribute format

*(Source: [vsapi `TreeAttribute.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Datastructures/AttributeTree/TreeAttribute.cs) and the attribute classes next to it in [`Datastructures/AttributeTree/`](https://github.com/anegostudios/vsapi/tree/63d33f70018c606fb0f70ead900fe90625fbd7b2/Datastructures/AttributeTree), confirmed against the sample.)*

A tree is a list of entries `[u8 type id][string key][value]`, ended by a single `0` byte. Values by type id:

| Id | Type | Encoding |
| --- | --- | --- |
| 1 | int | `i32` |
| 2 | long | `i64` |
| 3 | double | `f64` |
| 4 | float | `f32` |
| 5 | string | string |
| 6 | tree | nested tree, ends with `0` |
| 7 | item stack | `u8 isNull`; if 0: `i32 class`, `i32 id`, `i32 stackSize`, then a tree of stack attributes ([`ItemStack.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/Collectible/ItemStack.cs)) |
| 8 | byte array | `u16 length`, bytes |
| 9 | bool | `u8` |
| 10 | string array | `i32 count`, strings |
| 11 | int array | `i32 count`, `i32`s |
| 12 | float array | `i32 count`, `f32`s |
| 13 | double array | `i32 count`, `f64`s |
| 14 | tree array | `i32 count`, trees |
| 15 | long array | `i32 count`, `i64`s |
| 16 | bool array | `i32 count`, `u8`s |

Every block entity in the sample starts with `posx`, `posy`, `posz` (int, absolute block coordinates) and `blockCode` (string). Storymap parses the full format in [`src/vs/TreeAttribute.zig`](../../src/vs/TreeAttribute.zig) and [`src/vs/BlockEntity.zig`](../../src/vs/BlockEntity.zig); parsing the sample with it gives the same counts as the Python check above.

Classes in the 1.19 sample: MicroBlock 8,343 · Generic 4,364 · BerryBush 632 · GenericTypedContainer 370 · Crate 274 · GroundStorage 184 · Tapestry 59 · Chisel 39 · TorchHolder 33 · LocustNest 29 · Transient 24 · Mycelium 23 · Firepit 19 · Trough 15 · Bed 12 · Forge 8 · PlantContainer 8 · DynamicTreeBranch 4 · CoalPile 3 · DisplayCase 2 · Lantern 2.

**1.22.7:** all 684 block entities in the new world parse with the same format, in both the Python check and Storymap's Zig parser. Classes: WildFruitingBush 628 · Mycelium 43 · DynamicTreeBranch 10 · DynamicTreeFoliage 2 · Beehive 1. `WildFruitingBush` takes over from 1.19's `BerryBush`, which the 1.22.7 code still registers from a `Legacy/` folder for old saves. All 76,778 block entities of the larger 1.22.7 world parse too, in both parsers; its ruins give it most of the 1.19 sample's classes, led by MicroBlock 40,528 · Generic 22,933 · WildFruitingBush 5,598 · GenericTypedContainer 2,002 · Crate 1,340 · Mycelium 1,109 · GroundStorage 967 · Chisel 604, plus the Primitive Survival mod's tree hollows, `betreehollowgrown` 111, whose block codes carry the mod's domain (§6). *(Source: [`Systems/Core.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Core.cs#L797) registers `BerryBush` and, [further down](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Core.cs#L922), `WildFruitingBush`; [`Legacy/BlockEntity/BEBerryBush.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Legacy/BlockEntity/BEBerryBush.cs).)*

### Chiseled blocks (MicroBlock, Chisel)

Chiseled blocks are `BlockEntityMicroBlock` *(Source: [vssurvivalmod `Systems/Microblock/BEMicroBlock.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BEMicroBlock.cs))*. In the chunk's block data they're an ordinary block (code `microblock`); the shape is in the block entity. Most in the test saves are presumably from generated ruins. `Chisel` entries, block code `chiseledblock`, are [`BEChisel`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BEChisel.cs), the kind the chisel works on, with the same keys plus `availMaterialQuantities`; whether players or world generation made them isn't known. *(Unverified.)*

| Key | Type | Meaning |
| --- | --- | --- |
| `materials` | int array | Block IDs, same ID space as chunk palettes (§6); all 9,309 in the 1.19 sample and all 45,683 in the larger 1.22.7 world have codes. Older saves may store block codes as a string array; the source handles that, including a fallback for pre-1.13 codes. In the sample, a block named "Aged polished rock (Granite)" has the material `polishedrockold-full-andesite`; possibly world generation swapped a ruin's rock for the local one without renaming it. *(Unverified.)* |
| `cuboids` | int array | Boxes, one packed `u32` each (below). |
| `rotation` | int | `(rotationY + 360) << 10`; read back as `((rotation >> 10) & 1023) − 360`. In the larger 1.22.7 world all but 101 are multiples of 90°; those 101 are 0, which reads as −360°, a full turn. |
| `decorIds`, `decorRot` | int array, int | Decor on the block's faces. |
| `blockName` | string | Display name, e.g. "Aged polished rock (Granite)". Empty on 23,593 of the larger 1.22.7 world's 41,132. |
| `emitSideAo`, `sideSolid`, `sideAlmostSolid` | byte array | One byte of per-side flags. |
| `originalCuboids` | int array | Present on 24 sample entries and 98 in the larger 1.22.7 world. |
| `snowcuboids`, `groundSnowCuboids` | int array | Snow on and around the block, written by [`BEBehaviorMicroblockSnowCover.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BEBehaviorMicroblockSnowCover.cs). Present on 1,687 sample entries and 16,512 in the larger 1.22.7 world. |
| `availMaterialQuantities` | int array | `Chisel` only: a quantity per material, in voxels, where 4,096 (16³) is a whole block; a material without one counts as 4,096. Every one in the larger 1.22.7 world is 4,096. *(Source: `BEChisel.cs`.)* |
| `beams` | byte array | Support beams placed on the block, from [`BEBehaviorSupportBeam.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/SupportBeams/BEBehaviorSupportBeam.cs): a Protobuf list, field 1 repeated, of [`PlacedBeam`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/SupportBeams/PlacedBeam.cs) `{ 1: Start, 2: End, 3: BlockId, 4: FacingIndex }`, the ends as `{ 1: X, 2: Y, 3: Z }` floats. On 439 entries in the larger 1.22.7 world, 1,065 beams. |

Cuboid packing, 16 × 16 × 16 voxels per block (from `ToUint`/`FromUint`):

| Bits | Value |
| --- | --- |
| 0–3 | x1 |
| 4–7 | y1 |
| 8–11 | z1 |
| 12–15 | x2 − 1 |
| 16–19 | y2 − 1 |
| 20–23 | z2 − 1 |
| 24–31 | index into `materials` |

Every field is 4 bits except the material, so in hexadecimal each field is one digit and a box reads off directly, most significant first: material (two digits), z2 − 1, y2 − 1, x2 − 1, z1, y1, x1. `0x00F77000` is material `00`, far corner z `F`, y `7`, x `7` (each plus 1: 16, 8, 8) and near corner (0, 0, 0). Storing the far corner minus 1 lets a box that reaches the edge (16) fit in one digit. The cuboids are an int array, so a box with material index 128 or more is a negative number.

*(Verified (1.19, 1.22.7): all 20,407 cuboids in the sample and 101,400 in the larger 1.22.7 world decode to boxes with x1 < x2, y1 < y2, z1 < z2, whose material index is within `materials`. Keys and counts in the table above: verified (1.22.7) in the larger world. Example: `0x00F77000` is x 0–8, y 0–8, z 0–16, material 0. Note that a comment in the source describes a different layout; the code above is what runs.)*

### Ground storage

`GroundStorage` (items placed on the ground) holds an `inventory` tree with `qslots` and `slots`; the slots contain item stacks (type 7). Every entry also has keys for burning (`isBurning`, `burning`, `remainingBurnDuration`, `startDuration`, and the fire's and the fuel's positions, `fireposX` … `fuelposZ`) and a few for layout. *(Verified (1.19): the 184 ground storage entities hold 244 item stacks, all parsed with the format above; what the stack ids mean isn't decoded. Verified (1.22.7): in the larger world, 967 hold 1,267 item stacks, and every one has the keys above. Source: [vssurvivalmod `BlockEntity/BEGroundStorage.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/BlockEntity/BEGroundStorage.cs), not yet read.)*

## 6. Game data

`gamedata` has a single row whose `data` is one `SaveGame` message. *(Verified (1.19, 1.22.7): it parses completely in every test save.)* Names and types are the schema's; the values are from the test saves. *(Verified (1.19, 1.22.7).)*

| # | Name | 1.22.7 value (1.19 sample) | Meaning |
| --- | --- | --- | --- |
| 1, 2, 3 | `MapSizeX`, `MapSizeY`, `MapSizeZ` | 1,024,000 · 256 · 1,024,000 | World size in blocks: x, height, z |
| 4 | `PlayerDataByUID` | none | Players are in `playerdata` instead |
| 7 | `Seed` | a number | The world seed |
| 8 | `SimulationCurrentFrame` | none | |
| 10 | `LastEntityId` | 137 (422) | The last entity ID handed out |
| 11 | `ModData` | 23 entries | Named data entries `{ 1: key, 2: value }`, including the block and item IDs (below) |
| 12 | `TotalGameSeconds` | 3,140,135 (3,188,169) | The in-game clock, in game seconds |
| 13 | `WorldName` | `Gloomy Cave Valley` | |
| 14 | `TotalSecondsPlayed` | 101 (1,839) | Real time played |
| 16 | `WorldPlayStyle` | none | |
| 17 | `LastPlayed` | `2026-10-10T22:25:37.6821955+05:30` | |
| 18 | `CreatedGameVersion` | `1.22.7` (`1.19.1`) | |
| 19 | `GameTimeSpeed` | none | |
| 20 | `MiniDimensionsCreated` | 1 (none) | Mini-dimensions created so far (§2) |
| 21 | `LastSavedGameVersion` | `1.22.7` (`1.19.2`) | The sample's chunks were created by both versions |
| 22 | `CreatedByPlayerName` | a player name | |
| 23 | `EntitySpawning` | 1 | A bool |
| 25 | `HoursPerDay` | 24.0 | |
| 26 | `LastHerdId` | 77 (201) | |
| 27 | `LandClaims` | none (1) | Each a list of boxes, an owner and permissions |
| 28 | `TimeSpeedModifiers` | `baseline`: 60.0 | |
| 29 | `PlayStyle` | `homosapiens` (`surviveandbuild`) | |
| 30 | `WorldType` | `standard` | |
| 31 | `WorldConfigBytes` | a tree attribute | World configuration (below) |
| 32 | `PlayStyleLangCode` | `preset-homosapiens` (`preset-surviveandbuild`) | |
| 33 | `LastBlockItemMappingVersion` | 1 | |
| 34 | `SavegameIdentifier` | a UUID | Same as the file name of the world's map cache in the data folder's `Maps/` (§7, [the game's map cache](#the-games-map-cache)) |
| 35 | `CalendarSpeedMul` | 0.5 | |
| 36 | `RemappingsAppliedByCode` | 48 entries `{ 1: name, 2: 1 }`, e.g. `game:v1.12clayplanters` (30) | Remaps already applied to this world: keys in the game's `config/remaps.json`, each with `true` |
| 37 | `HighestChunkdataVersion` | 2 | Chunks' field 15 is 2 as well (§3) |
| 38 | `TotalGameSecondsStart` | 3,139,200 | The in-game clock when the world was created |
| 39 | `CreatedWorldGenVersion` | 3 (2) | Map chunks' field 16 matches it (§7) |
| 40 | `DefaultSpawn` | none | `{ x, y, z, yaw, pitch, roll, RemainingUses }`. The test saves' players spawned around the world's centre (§2). |

"None" means the field isn't in the test saves. Field 21 is the version Storymap's viewer shows.

### Block and item IDs

The field-11 entry with key `BlockIDs` maps every block ID to its block code. Its value is a list of entries `{ 1: id (varint), 2: code (string) }`; both saves write id 0 explicitly, though Protobuf would allow leaving it out. `ItemIDs` has the same format for items, starting at id 1. *(Verified (1.19, 1.22.7).)*

| ID | 1.22.7 world | 1.19 sample |
| --- | --- | --- |
| 0 | `air` | `air` |
| 1 | `mantle` | `mantle` |
| 164 | `creativeblock-2` | `creativeblock-12` (the sample's single placed block) |
| 2966 | `water-still-7` (the deep lake in §3) | `slantedroofingcornerinner-fireclay-south-snow` |
| 6769 | | `rock-granite` |

- **IDs are per save.** The same number means different blocks in different saves, so a reader must use each save's own list.
- **Sizes:** 14,091 block codes and 4,468 item codes in the 1.22.7 world; 9,312 and 3,318 in the 1.19 sample; 14,783 and 4,634 in the larger 1.22.7 world, which has a mod (below). Block IDs run from 0 with no gaps.
- **Completeness:** every ID in every solid and liquid palette (41,648 entries in the 1.22.7 world, 52,856 in the 1.19 sample) and every chiseled-block material (9,309 in the sample) has a code. *(Verified with Storymap's [`src/vs/GameData.zig`](../../src/vs/GameData.zig).)*
- **Domains:** the game's own codes are written without a domain (`rock-granite`, not `game:rock-granite`); a mod's codes carry theirs. The larger 1.22.7 world was created with the Primitive Survival mod: 692 of its block codes and 166 of its item codes start with `primitivesurvival:`, e.g. `primitivesurvival:treehollowgrown-…`.
- **Mods' IDs come last:** the game's blocks and items have the same IDs and codes in both 1.22.7 worlds, and the mod's follow in one unbroken run: blocks 14,091–14,782 and items 4,469–4,634. *(Verified (1.22.7): the two 1.22.7 worlds' lists compared ID by ID.)*
- **Modded blocks in chunks:** palettes hold mods' block IDs like any other. In the larger world, 111 chunks have a modded block in their palette, every one a tree hollow, matching its 111 block entities of class `betreehollowgrown` (§5). *(Verified (1.22.7): every palette in the world, raw and compressed.)*

The other field-11 keys (`worldeditworkspaces`, `ambient`, `temporalStormData`, `riftweather`, …) are mods' and game systems' own data, and aren't decoded.

### World configuration

Field 31 is a tree attribute (§5) whose values are mostly strings, e.g. `gameMode: "survival"`, `startingClimate: "temperate"`, `seasons: "enabled"`, `spawnRadius: "5000"`, `daysPerMonth: "9"`; a world with the colour-accurate map has `colorAccurateWorldmap` as the number 1. *(Verified (1.19, 1.22.7): it parses with Storymap's tree attribute format.)* `spawnRadius` is 50 in the 1.19 sample and 5000 in the 1.22.7 world, which explains where their players spawned (§2).

### The date

`TotalGameSeconds` (field 12) over 3,600 and `HoursPerDay` (field 25) gives the days since the start of the calendar, and a year is 12 months of `daysPerMonth` days, 108 by default, starting with January. The 1.22.7 worlds were created at 3,139,200 seconds (`TotalGameSecondsStart`, field 38): 872 hours, 36 days and 8 hours, so 08:00 on 1 May of the first year, which the calendar numbers 1386 (`StartYear`). *(Source: vsapi [`IGameCalendar.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/API/IGameCalendar.cs), which names the months and counts days from the first of January. Where in the year a day falls is unverified beyond that.)*

### Sea level

The save doesn't store a sea level; neither the fields above, the schema nor the world configuration has one. *(Verified (1.19, 1.22.7).)* The game derives it from the world height (field 2): the world height × 0.4313725490196078 (= 110 / 255), rounded down, so **110** for the default height of 256. *(Wiki: [Sea level](https://wiki.vintagestory.at/Sea_level), checked there for 1.20.12; the API only calls it "the currently configured sea level" ([vsapi `IWorldAccessor.cs`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/API/IWorldAccessor.cs)).)*

Water fills the blocks below sea level: the top water block of a sea or lake is at y = 109, so the water surface is at height 110. *(Verified (1.19, 1.22.7): both worlds are 256 high; the highest liquid block in each column is water at y = 109 in 84% of the 1.22.7 world's 177,045 water columns and 89% of the 1.19 sample's 219,284. The rest are lakes and springs above sea level.)*

## 7. Map chunks

`mapchunk.data` is one plain Protobuf message per chunk column, not compressed: ~10 KB per row in the 1.22.7 world, ~17 KB in the 1.19 sample. *(Verified (1.19, 1.22.7): every row parses completely.)* Its per-column maps hold 1,024 values, one per block column at index `z * 32 + x`, written as repeated varints (not packed). The message is `ServerMapChunk`; names and types are the schema's, and the meanings come from the game's [`IMapChunk`](https://github.com/anegostudios/vsapi/blob/63d33f70018c606fb0f70ead900fe90625fbd7b2/Common/API/IMapChunk.cs) interface.

| # | Wire type | Per row | Values (1.22.7 · 1.19) | Name |
| --- | --- | --- | --- | --- |
| 1 | bytes, repeated | some rows | keys such as `lastSnowAccumUpdateTotalHours`, `hotspringlocations` | `Moddata`, game systems' and mods' data by key |
| 3 | varint | 1,024 | 54–65,535 · 0–65,534 | `RainHeightMap` (below) |
| 4 | varint | 1 | 2–6 | `currentpass`, the world-generation stage (below) |
| 6 | varint | | none | `TopRockIdMapOld` |
| 7 | varint | 1,024 | 3–151 · 46–236 | `WorldGenTerrainHeightMap` (below) |
| 8 | bytes, repeated | some rows | | `ScheduledBlockUpdates`, block positions `{ X, InternalY, Z }` |
| 9 | bytes, repeated | some rows | | `NewBlockEntities`, block positions as in field 8 |
| 10 | varint | 1 | 109–166 · 109–236 | `YMax`, the highest non-air block |
| 11 | bytes | 1 | always 1,024 bytes | `CaveHeightDistort` (a byte array) |
| 12 | varint | 1,024 | always 0 | `SedimentaryThicknessMap`, unused *([Wiki: VCDBS format](https://wiki.vintagestory.at/Modding:VCDBS_format#mapchunk))* |
| 13 | varint | 1,024 | block IDs, e.g. 6,763–6,769 in the 1.19 sample (6,769 is `rock-granite`) | `TopRockIdMap`, the top rock layer's block |
| 15 | bytes, repeated | some rows (1.19 only) | | `SnowAccum`, `{ Key: { X, Y }, Value: float }` pairs |
| 16 | varint | 1 | 3 · 2 | `WorldGenVersion`, the same as `gamedata` field 39 (§6) |
| 17 | bytes, repeated | some rows | | `ScheduledBlockLightUpdates`, `{ X, Y, Z, W }` |
| 18 | | some rows (1.22.7 only) | | Not in the 1.21 schema; unknown |

*(Verified (1.19, 1.22.7): fields and values in every test save.)*

- **Field 3, the rain height:** "the last block that is not rain permeable before the first airblock" (`IMapChunk`). Rain stops at water but falls through plants and loose stones, so this is the water surface or the ground beneath them. A column with no blocks at all has 0. A few columns hold 65,531–65,535, far above the world (3 in the 1.22.7 world, 14 in the 1.19 sample): the game holds these heights as unsigned 16-bit numbers *([Forum](https://www.vintagestory.at/forums/topic/19778-understanding-and-improving-the-games-savefiles-serialization-and-compression/))*, so those are −5 to −1, perhaps heights that went below 0. A reader should treat a height above the column's chunks as unknown. It's what the game's own world map draws *(Source: [vsessentialsmod `ChunkMapLayer.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs))*. *(Verified (1.19, 1.22.7), against the highest block of every column: in the 1.22.7 world it's the highest solid block in 422,000 columns and the water surface in 166,000; in nearly all of the other 208,000 it's below the highest block, which there is tall grass, loose stones or flints, reeds, tule or horsetail. 777 columns (0.1%) point at a block that's gone, presumably changed afterwards. In the 1.19 sample, the 49,161 columns of a cleared area hold 0 and no blocks. The index order `x * 32 + z` matches far fewer columns.)*
- **Field 7, the terrain height:** "the last block before the first airblock before world gen pass Vegetation"; for seas and lakes, their bed (`IMapChunk`). Unlike the rain height, the game doesn't update it after generation *([Wiki](https://wiki.vintagestory.at/Modding:VCDBS_format#mapchunk))*. *(Verified (1.19, 1.22.7): it's never a water surface; it equals the highest solid block in 65% of the 1.22.7 world's columns and 49% of the 1.19 sample's, the rest being under plants, water or later changes.)*
- **Stale rows:** map chunks stay when their chunks' blocks are removed, so a reader should check the block at the stored height.

### World-generation stages

Field 4 is the column's world-generation stage, `IMapChunk.CurrentPass`, a value of `EnumWorldGenPass`. It's the column's **next** pass, not the last one finished. The passes *(Wiki: [WorldGen Concept](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))*:

| Value | Pass | Generates |
| --- | --- | --- |
| 0 | None | |
| 1 | Terrain | terrain, rock layers, caves |
| 2 | TerrainFeatures | deposits, structures, ponds |
| 3 | Vegetation | patches, shrubs, trees, rivulets |
| 4 | NeighbourSunLightFlood | the snow layer, light across chunks |
| 5 | PreDone | creatures; neighbours may still add things |
| 6 | Done | – |

Passes 2 to 5 need the neighbouring columns, so the game surrounds everything it finishes with rings of partly generated columns. In the larger 1.22.7 world they're concentric, each exactly one chunk column (32 blocks) wide:

| Stage | Chunk columns | Extent at this stage or later |
| --- | --- | --- |
| 6 Done | 2,729 | 1,824 × 1,600 blocks |
| 5 | 218 | 1,888 × 1,664 |
| 4 | 226 | 1,952 × 1,728 |
| 3 | 234 | 2,016 × 1,792 |
| 2 | 242 | 2,080 × 1,856 |

*(Verified (1.22.7): the larger world, 3,649 columns in all.)* Rendered, stage 2 and 3 columns are bare, with no trees or shrubs, while from stage 4 on they have trees and look like Done ones. That confirms the value is the next pass: 3 means Vegetation hasn't run. Whether snow appears from stage 5 on couldn't be checked: no edge of that world is snowy. The other test saves have the same rings: 266 of the 1.22.7 world's 778 columns are Done (152, 136, 120 and 104 at stages 2 to 5, around each of its two explored areas), and 420 of the 1.19 sample's 860 (122, 114, 106 and 98). *(Verified (1.19, 1.22.7).)*

### The game's map cache

The game's world map isn't drawn from the save. It's a cache on the client: `Maps/<id>.db` in the data folder, where `<id>` is `gamedata` field 34 (§6). It has two tables, `mappiece (position integer PRIMARY KEY, data BLOB)` and `blockidmapping` (empty in the larger world). `mappiece` positions use the map chunks' packing (§2, no y), one piece per chunk column. Each piece is a `MapPieceDB` message whose field 1, `Pixels`, is a repeated `int32`: the piece's 32 × 32 colours at index `z * 32 + x`, red in the lowest byte, then green and blue. *(Schema. Verified (1.22.7): decoded this way, the pieces line up with Storymap's tiles of the same worlds, and its shaded style matches 99.65% of a world's pixels; [rendering.md](../rendering.md#how-the-game-draws-its-own-world-map).)*

The larger world's cache has 2,694 pieces, all of them stage-6 columns. The other 35 Done columns have no piece: they're finished but were never sent to the client, so the game's map doesn't show them. *(Verified (1.22.7): the larger world's cache, copied out of the data folder.)* Matching the game's map exactly would take this per-player cache, which a server doesn't have, so Storymap draws the stage-6 columns instead.

## 8. Map regions

`mapregion.data` is a `ServerMapRegion` message: world-generation maps for one region of 16 × 16 chunk columns (512 × 512 blocks). Most fields are an `IntDataMap2D`, a square grid of numbers *(Schema; [Wiki: VCDBS format](https://wiki.vintagestory.at/Modding:VCDBS_format#mapregion))*:

| # | Name | Type |
| --- | --- | --- |
| 1 | `Data` | `int32`, packed: `Size × Size` values |
| 2 | `Size` | `int32`, the side of the grid |
| 3 | `TopLeftPadding` | `int32`, extra rows above and columns to the left |
| 4 | `BottomRightPadding` | `int32`, extra rows below and columns to the right |

The padding repeats values that belong to the neighbouring regions, so world generation blends across region borders. What's left, the inner size, can be more than 16 for a finer grid than one value per chunk column; the game interpolates between values. *(Wiki.)*

| # | Name | Size (padding) | Inner size |
| --- | --- | --- | --- |
| 1 | `LandformMap` | 40 (4, 4) | 32 |
| 2 | `ForestMap` | 17 (0, 1) | 16 |
| 3 | `ClimateMap` | 20 (2, 2) | 16 |
| 4 | `GeologicProvinceMap` | 14 (3, 3) | 8 |
| 5 | `BushMap` | 33 (0, 1) | 32 |
| 6 | `FlowerMap` | 17 (0, 1) | 16 |
| 8 | `OreMaps` | one map per ore, keyed by name: 31 ores, `alum` to `sulfur` | |
| 9 | `ModData` | game systems' and mods' data by key: `weatherState`, `clothSystems`, `dungeonPlaceTasks` | |
| 10 | `ModMaps` | mods' maps by key; none in the test saves | |
| 11 | `GeneratedStructures` | structures placed by world generation (below) | |
| 12 | `RockStrata` | one map per rock stratum, 16 in all, the variants in the game's `worldgen/rockstrata.json`: 36 (2, 2) | 32 |
| 13, 14 | `OreMapVerticalDistortTop`, `…Bottom` | 260 (2, 2) | 256 |
| 15 | `BeachMap` | 33 (0, 1) | 32 |
| 16 | `BlockPatchMaps` | one map per block patch, keyed by name: 15 (7 in the 1.19 sample), e.g. `mush1`, `hornwort` | |
| 17 | `UpheavelMap` | 22 (3, 3) | 16 |
| 18 | `OceanMap` | 26 (5, 5) | 16 |
| 19, 20, 21 | | not in the 1.21 schema; in 1.22.7 only. Field 21 repeats nine times per region. | |

*(Verified (1.19, 1.22.7): the sizes and keys in every test save.)*

Each `ClimateMap` value packs the climate at a point, 32 blocks apart: temperature in bits 16–23 and rainfall in bits 8–15, each 0 to 255, at sea level. The game interpolates between them, and adjusts them for height. *(Verified (1.22.7): the game's map tints water by its climate colour map at this temperature and rainfall, within 0.01 per channel; [rendering.md](../rendering.md#climate-and-season-tint).)* Bits 0–7 hold something else, not interpreted; nothing is above bit 23. The test saves' temperatures are 84–139 and rainfalls 4–255. *(Verified (1.19, 1.22.7): every climate value in the four test saves; bits 0–7 are set in about 30% of them.)*

Each generated structure is `{ 1: Code, 2: Group, 3: Location, 4: SuppressRivulets, 5: SuppressTreesAndShrubs }`. `Location` is the structure's box in absolute block coordinates, `{ X1, Y1, Z1, X2, Y2, Z2 }`. Codes are file names, such as `lakes/small5.json` in 1.19 and `small5.json/lakes` in 1.22.7, and include lakes, gates, ruins, traders and villages, so a map could label them. A structure is stored in the region its box starts in, nearly always: 87 of the larger 1.22.7 world's 2,524 start outside it. *(Schema. Verified (1.19, 1.22.7): the larger 1.22.7 world has 2,524 structures and the 1.19 sample 437; the other 1.22.7 world has none.)*

## 9. Open questions

- **Other chunk fields:** entities' data (6), field 10, the empty flag (13), decor (14), and the two light fields that are probably colour (§3).
- **`playerdata`:** not decoded, though the schema names its fields. **`mapchunk`:** field 18 isn't in the schema. **`mapregion`:** fields 19–21 aren't in the schema, and the maps' values aren't interpreted, except the climate map's. **`gamedata`:** the field-11 entries other than the ID lists aren't decoded.
- **Other dimensions.** No test save has chunks outside dimension 0 (§2); a world with a time-switched alternate world or a vehicle would show how they're stored.
- **Mods.** Block and item codes are settled (§6). Structures carry no domain in their codes, so which of the larger 1.22.7 world's come from its mod isn't known; its one entity of class `entitypsagent` is probably the mod's.
