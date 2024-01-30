## Information we have so far

.vcdbs is an SQLite database that contains all the save data for Vintage Story. It's located in the game's data directory under the `Saves/` folder. Opening the database reveals the following tables (with descriptions adapted from [[🡕]](https://wiki.vintagestory.at/index.php/Modding:WorldGen_Concept)):

-   chunk

    > A data structure that holds 32x32x32 blocks. It is of note that chunks do not span the world height.

-   mapchunk
    > A data structure that holds information on a chunk column, such as the rain height or snow accumulation
-   mapregion
    > A data structure that holds information over an area of 16x16 chunk columns, such as weather and maps required for world generation
-   gamedata
-   playerdata

### Chunk

This is likely the only table we want to read. It contains `position` and `data` columns.

Position is an u64 which parses into chunk coordinates with a Zig packed struct of the definition:

```zig
const Position = packed struct(u64) {
    x: u27,
    z: u27,
    y: u10,
};

const position: Position = @bitcast(value);
```

Chunk coordinates are /32 of block coordinates. So a chunk at (0, 0, 0) would contain blocks (0, 0, 0) to (31, 31, 31).

Chunk coordinates are absolute, and not relative to spawn. In-game coordinates are shifted by half the world size to make the spawn point the center of the world.

The data column is a binary blob encoded as a Protobuf message. We've implemented part of the [Protobuf spec](../src/ProtoBuf.zig) to be able to parse chunks. Important to note that Protobuf messages are not tagged, so all we get is a list of fields. To get any further, we need more information on what each field is.

Additional info from the Wiki [[🡕]](https://wiki.vintagestory.at/index.php/Modding:Chunk_Data_Storage):

> Each chunk contains the following information:
>
> -   Every block in the solid layer
> -   Every block in the fluid layer
> -   Sparse map of block positions to block entities
> -   List of entities
> -   Sparse map of decor blocks. The map is indexed by both the block position and decor index. The decor index includes which face of the parent block the decor is attached to, and optionally a location on a 16x16 grid on that block face (used by caveart).
> -   Map of modid to a byte array of custom moddata
> -   Format version metadata
