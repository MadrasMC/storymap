# Vintage Story save format

The text reference for how a Vintage Story `.vcdbs` save is laid out, as far as storymap has worked it out. [`index.html`](index.html) in this folder is an interactive explainer built from this file; when the two disagree, this file wins and the HTML needs updating.

## Versions

| Version | Status |
| --- | --- |
| 1.19.1, 1.19.2 | **Verified** against a sample save written by both versions (6,880 chunks: 4,928 by 1.19.1, 1,952 by 1.19.2). |
| 1.22.7 (current) | **Verified** against a new world (6,224 chunks, all written by 1.22.7): schema, positions, chunk fields, block and liquid decoding, and the block entity format. That world has no chiseled blocks or ground storage, so those are verified on 1.19 only. Claims marked **Source** also come from the 1.22.7 code. |

Version-specific differences are noted inline, in the section they affect, as **1.19:** / **1.22:** notes. If a later version changes the format so much that inline notes stop being readable, split that version into its own file.

## How claims are sourced

Every section says where its information comes from:

- **Verified (1.19):** checked against the sample save `content/sample-one-block-spawn.vcdbs` (not in the repo; `content/` is git-ignored), with how it was checked.
- **Verified (1.22.7):** checked against `content/gloomy-cave-valley-1.22.7.vcdbs`, a copy of a fresh 1.22.7 world (also not in the repo).
- **Source:** read in Vintage Story's open-source code on GitHub ([vsapi](https://github.com/anegostudios/vsapi), [vssurvivalmod](https://github.com/anegostudios/vssurvivalmod), [vsessentialsmod](https://github.com/anegostudios/vsessentialsmod)). Links are pinned to the commits read on 2026-10-10, each repository's "Updated to Version 1.22.7" commit: vsapi `63d33f7`, vssurvivalmod `849fa8c`, vsessentialsmod `06673b6`. Pin new links to a commit or tag too, never `master`. The chunk storage code itself is in the closed engine library and isn't available.
- **Wiki:** the [Vintage Story wiki](https://wiki.vintagestory.at/).
- **Unverified:** an observation or guess that hasn't been confirmed.

## 1. The save file

A `.vcdbs` file is an SQLite database. Saves live in the game's data folder under `Saves/`; on Windows that's `%APPDATA%\VintagestoryData\Saves`. *(Verified (1.22.7): a fresh Windows install.)*

Saves use SQLite's [write-ahead log](https://www.sqlite.org/wal.html): bytes 18 and 19 of the file header are 2 in both test saves. In that mode even a read-only connection creates `-shm` and `-wal` files next to the database, so a tool that opens a save in place writes into the game's `Saves` folder. Read a copy, or open the file with SQLite's `immutable=1` URI parameter, which creates nothing. *(Verified (1.19, 1.22.7): read-only opens of the copies created both files; `immutable=1` didn't.)*

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

| Table | Rows in sample | What it holds |
| --- | --- | --- |
| `chunk` | 6,880 | One 32 × 32 × 32 cube of blocks per row. "Chunks do not span the world height." *([Wiki: WorldGen Concept](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))* |
| `mapchunk` | 860 | One row per chunk column: "information on a chunk column, such as the rain height or snow accumulation." *([Wiki](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))* |
| `mapregion` | 20 | "Information over an area of 16x16 chunk columns, such as weather and maps required for world generation." *([Wiki](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept))* |
| `gamedata` | 1 | The save's global data (429,515 bytes in the sample). Not decoded. |
| `playerdata` | 1 | Per-player data. Not decoded. |

`sqlite_sequence` is SQLite's own table for `AUTOINCREMENT`, not game data.

**1.22.7:** the new world has 6,224 chunks, 778 map chunks, 32 map regions, and one row each in `gamedata` and `playerdata`.

## 2. Positions

`chunk.position` is a 64-bit integer packing the chunk's coordinates *(Verified (1.19): decoding gives a contiguous block of chunks, and decoding the blocks with these coordinates renders continuous terrain; see [`src/Chunk.zig`](../../src/Chunk.zig))*:

| Bits | Field |
| --- | --- |
| 0–26 | x (27 bits) |
| 27–53 | z (27 bits) |
| 54–63 | y (10 bits) |

```zig
const Position = packed struct(u64) {
    x: u27,
    z: u27,
    y: u10,
};
```

- These are chunk coordinates: chunk (x, y, z) holds blocks x·32 … x·32+31, and so on.
- SQLite integers are signed, so a chunk with y ≥ 512 (top bit set) is stored as a negative number. *(Inferred from SQLite's integer type; the sample has no chunks that high, max y = 7.)*
- Coordinates are absolute. The game shows coordinates shifted from these. *(Unverified: the original notes say the shift is half the world size, centring spawn; not confirmed.)*

`mapchunk.position` uses the same packing with y = 0, one row per chunk column. *(Verified (1.19): the 860 `mapchunk` positions are exactly the 860 distinct (x, z) columns in `chunk`. Verified (1.22.7): likewise, 778 and 778.)*

**1.22.7:** the new world's chunks form two separate areas: a 15 × 15-column square centred on chunk (16000, 16000), which is block (512,000, 512,000), the middle of a 1,024,000-block world; and a round area around the player, centred about 2,600 blocks east and 3,600 blocks south of it. *(Observed. Why the square exists isn't confirmed; possibly the game generates the world centre before choosing a spawn point.)*

`mapregion.position` decodes to x 997–1001, z 998–1001 with the same packing, consistent with one region per 16 × 16 chunk columns (chunk x 15979–16010 ÷ 16). *(Inferred from the sample; the exact mapping isn't confirmed.)*

## 3. Chunk data: Protobuf fields

`chunk.data` is a [Protobuf](https://protobuf.dev/programming-guides/encoding/) message: a sequence of `(field number, wire type, value)` entries with no schema in the file. storymap parses it with [`src/ProtoBuf.zig`](../../src/ProtoBuf.zig).

Field names come from the `fieldNames` list in [`src/Chunk.zig`](../../src/Chunk.zig), whose origin isn't recorded; treat them as best guesses unless the status says decoded.

| # | Wire type | Name | Chunks containing it (of 6,880) | Status |
| --- | --- | --- | --- | --- |
| 1 | bytes | `compressed_blocks` | 6,880 | **Decoded** (§4) |
| 2 | bytes | `compressed_light` | 6,880 | Unknown |
| 3 | bytes | `compressed_light_sat` | 6,880 | Unknown |
| 5 | varint | `entities_count` | 131 | Unknown; same chunk count as field 6 |
| 6 | bytes, repeated | `entities_serialized` | 131 (312 entries) | Unknown |
| 7 | varint | `block_entities_count` | 539 | Unknown; same chunk count as field 8 |
| 8 | bytes, repeated | `block_entities` | 539 (14,447 entries) | **Decoded** (§5) |
| 10 | varint, repeated | `lights` | 123 (27,951 entries) | Unknown |
| 12 | bytes | `game_version` | 6,880 | **Decoded:** UTF-8 text, e.g. `1.19.1`. The version that last wrote this chunk, so one save can mix versions. |
| 13 | varint | `empty` | 1,528 | Unknown |
| 14 | bytes | `decors` | 6,880 | Unknown |
| 15 | varint | `saved_compression_version` | 6,880 | Unknown |
| 16 | bytes | `compressed_liquids` | 6,880 | **Liquids**, same format as field 1 (§4). Above a deep lake bed in the 1.22.7 world, chunks y 0–3 have the liquid palette `[0, 2966]`; 2966 is probably water, but IDs aren't named yet. |
| 17 | varint | `blocks_placed` | 8 | Unknown |
| 18 | varint | `blocks_removed` | 2 | Unknown |

*(Verified (1.19): counts and wire types from scanning every chunk in the sample.)*

**1.22.7:** the same field numbers with the same wire types. Field 12 is `1.22.7` in every chunk; field 15 is 2 in every chunk of both saves. Field 14 appears in only 350 of 6,224 chunks (every chunk in 1.19), and fields 17 and 18 don't appear. *(Verified (1.22.7).)*

The wiki lists what a chunk contains: solid blocks, fluid blocks, block entities, entities, decor, mod data and format version metadata. *([Wiki: Chunk Data Storage](https://wiki.vintagestory.at/index.php/Modding:Chunk_Data_Storage))*

**Earlier observations** (from an older sample save, deleted in commit `ec646a7`): fields seen were 1, 2, 3, 6, 8, 12, 14, 16; fields 6 and 8 repeat; changing one solid block changed fields 1, 2 and 3. The 1.19 sample shows that fields 5, 7, 13, 17 and 18 also appear, but only in some chunks.

## 4. Blocks: fields 1 and 16

*(Verified (1.19) unless noted: decoding the one-block chunk at chunk (15995, 4, 15999) finds exactly one non-air block, palette ID 164, at local (5, 7, 18); decoding the whole save renders a continuous heightmap. Decompression code: [`src/Compression.zig`](../../src/Compression.zig), a port of the game's own C# routine, judging by its names. Read side: `Chunk.getBlock` in [`src/Chunk.zig`](../../src/Chunk.zig), commit `f9dc6e3`.)*

### Layout

```
[ i32 length ][ palette: |length| bytes ][ zstd frame: bit planes ]
```

All integers are little-endian.

- **`length`:** negative means the palette is stored raw, `-length` bytes. Positive means it's a zstd frame of `length` bytes. Zero means the chunk has no blocks.
- **Palette:** an array of `i32` block IDs, the distinct block types in this chunk. Entry 0 is air (ID 0). A palette with one entry (only air) means an empty chunk.
- **Bit planes:** the rest of the field is one zstd frame. It decompresses to `bits` planes of 1,024 `i32`s (4,096 bytes) each.

Real examples from the sample (both in chunk column x 15995, z 15999, written by 1.19.1):

| Chunk y | length | Palette | Planes |
| --- | --- | --- | --- |
| 4 | −8 (`f8 ff ff ff`) | raw, 2 entries: 0, 164 | 27 bytes → 4,096 bytes = 1 plane |
| 3 | 97 (`61 00 00 00`) | zstd, 97 → 88 bytes = 22 entries | 21 bytes → 20,480 bytes = 5 planes, all zero |

The y = 3 chunk shows that palettes aren't pruned: its blocks were removed, so every block is air, but the palette still lists 22 types.

### Palette rounding

The number of planes is `bits = ceil(log2(palette entries))`, and the palette is treated as having `2^bits` slots; storymap's `GetRoundedUpSize` (ported from the game) computes this. Only the real entries are stored. Slots past them are never referenced in valid data, and a reader should treat them as air rather than read past the stored entries. (storymap used to over-read here; fixed in commit `12219e3`.)

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

Every block entity in the sample starts with `posx`, `posy`, `posz` (int, absolute block coordinates) and `blockCode` (string). storymap parses the full format in [`src/TreeAttribute.zig`](../../src/TreeAttribute.zig) and [`src/BlockEntity.zig`](../../src/BlockEntity.zig); parsing the sample with it gives the same counts as the Python check above.

Classes in the 1.19 sample: MicroBlock 8,343 · Generic 4,364 · BerryBush 632 · GenericTypedContainer 370 · Crate 274 · GroundStorage 184 · Tapestry 59 · Chisel 39 · TorchHolder 33 · LocustNest 29 · Transient 24 · Mycelium 23 · Firepit 19 · Trough 15 · Bed 12 · Forge 8 · PlantContainer 8 · DynamicTreeBranch 4 · CoalPile 3 · DisplayCase 2 · Lantern 2.

**1.22.7:** all 684 block entities in the new world parse with the same format, in both the Python check and storymap's Zig parser. Classes: WildFruitingBush 628 · Mycelium 43 · DynamicTreeBranch 10 · DynamicTreeFoliage 2 · Beehive 1. `WildFruitingBush` takes over from 1.19's `BerryBush`, which the 1.22.7 code still registers from a `Legacy/` folder for old saves. *(Source: [`Systems/Core.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Core.cs#L797) registers `BerryBush` and, [further down](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Core.cs#L922), `WildFruitingBush`; [`Legacy/BlockEntity/BEBerryBush.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Legacy/BlockEntity/BEBerryBush.cs).)*

### Chiseled blocks (MicroBlock, Chisel)

Chiseled blocks are `BlockEntityMicroBlock` *(Source: [vssurvivalmod `Systems/Microblock/BEMicroBlock.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BEMicroBlock.cs))*. In the chunk's block data they're an ordinary block (code `microblock` in the sample); the shape is in the block entity. Most in the sample are presumably from generated ruins. The 39 `Chisel` entries are likely player-chiseled ([`BEChisel.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BEChisel.cs)). *(Unverified.)*

| Key | Type | Meaning |
| --- | --- | --- |
| `materials` | int array | Block IDs, same ID space as chunk palettes. Older saves may store block codes as a string array; the source handles that, including a fallback for pre-1.13 codes. |
| `cuboids` | int array | Boxes, one packed `u32` each (below). |
| `rotation` | int | `(rotationY + 360) << 10`. |
| `decorIds`, `decorRot` | int array, int | Decor on the block's faces. |
| `blockName` | string | Display name, e.g. "Aged polished rock (Granite)". |
| `emitSideAo`, `sideSolid`, `sideAlmostSolid` | byte array | One byte of per-side flags. |
| `originalCuboids` | int array | Present on 24 sample entries. |
| `snowcuboids`, `groundSnowCuboids` | int array | **1.19:** present on 1,687 sample entries. Not written by `ToTreeAttributes` in the 1.22.7 source; possibly by [`BEBehaviorMicroblockSnowCover.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/Systems/Microblock/BEBehaviorMicroblockSnowCover.cs). *(Unverified.)* |

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

*(Verified (1.19): all 20,407 cuboids in the sample decode to boxes with x1 < x2, y1 < y2, z1 < z2. Example: `0x00F77000` is x 0–8, y 0–8, z 0–16, material 0. Note that a comment in the source describes a different layout; the code above is what runs.)*

### Ground storage

`GroundStorage` (items placed on the ground) holds an `inventory` tree with `qslots` and `slots`; the slots contain item stacks (type 7). *(Verified (1.19): the 184 ground storage entities hold 244 item stacks, all parsed with the format above; what the stack ids mean isn't decoded. Source: [vssurvivalmod `BlockEntity/BEGroundStorage.cs`](https://github.com/anegostudios/vssurvivalmod/blob/849fa8cad9e392368566efc7474e73db6404a145/BlockEntity/BEGroundStorage.cs), not yet read.)*

## 6. Map chunks

`mapchunk.data` averages ~17 KB per row in the sample and isn't decoded. The game's world map reads a per-column `RainHeightMap` from map chunks *(Source: [vsessentialsmod `ChunkMapLayer.cs`](https://github.com/anegostudios/vsessentialsmod/blob/06673b67318e002332b6aa8b3d0308f11d2aba99/Systems/WorldMap/ChunkLayer/ChunkMapLayer.cs))*, so the stored rows probably include it; if so, a top-down map wouldn't need to scan blocks. *(Unverified.)*

## 7. Open questions

- **Block ID → block code mapping.** Palettes and chiseled-block materials hold numeric IDs. The mapping is probably in `gamedata`. Everything that needs names, colours or models depends on it.
- **Liquid IDs.** Field 16 holds liquids, but which ID is which liquid needs the ID mapping above.
- **Other chunk fields:** light (2, 3), entities (5, 6), field 10, decor (14), and the small varint fields.
- **`mapchunk`, `mapregion`, `gamedata`, `playerdata`:** not decoded.
- **In-game coordinates:** the offset from absolute coordinates isn't confirmed.
- **Chiseled blocks and ground storage on 1.22.7.** The 1.22.7 test world has neither; a world with ruins or a placed chiseled block, and items on the ground, would cover them.
- **Mods.** How modded blocks appear in palettes and `gamedata` needs a world created with a mod enabled.
