//! A Vintage Story save file, read for the renderers (see the `world` module): which tiles have
//! something in them, what the world is, and the top of every block column in a tile. Each
//! thread reads through a `Reader` of its own.
const SaveFile = @This();

const std = @import("std");
const DB = @import("sqlite");
const tiles = @import("tiles");
const world = @import("world");
const Chunk = @import("Chunk.zig");
const Compression = @import("Compression.zig");
const MapChunk = @import("MapChunk.zig");
const GameData = @import("GameData.zig");
const Prepared = @import("Prepared.zig");
const Tint = @import("Tint.zig");
const ProtoBuf = @import("protobuf");

path: []const u8,
/// Whether the save's -wal file holds changes the game hasn't written into the save yet,
/// because it's still running or it crashed. The map won't show them.
unsaved: bool,
db: DB,
gameData: GameData,
/// The tiles that may have something to draw.
tileList: []tiles.Tile,
/// What each block ID is on the map: from the prepared blocks (`useBlocks`), or else from
/// what its code says.
appearances: []world.Appearance,
/// How many chunk levels the world has: chunks have y 0 to `levels` − 1.
levels: usize,
/// The colour maps that tint each block ID, from the prepared blocks (`useBlocks`); none
/// without them.
tints: []BlockTint,
/// How far through the year the seasons are drawn, from 0 at the start of January: the
/// save's date, unless a season is chosen.
seasonProgress: f32,

/// Why a file can't be read as a save, for a message.
pub const Problem = struct {
    kind: Kind = .unopenable,
    /// The error behind it, if any.
    cause: ?anyerror = null,

    pub const Kind = enum {
        unopenable,
        /// Not an SQLite database, or one without a save's tables.
        notASave,
        /// No chunks at all, so nothing to draw.
        noChunks,
        /// The block list in `gamedata` can't be read.
        unreadableBlockList,
    };
};

/// Opens the save file at `path` for reading, never writing next to it, since it may be in
/// the game's own Saves folder. If it can't be read as a save, returns error.InvalidSaveFile
/// and `problem` says why.
pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, problem: *Problem) !SaveFile {
    // The immutable open ignores the save's -wal file. A non-empty one holds changes the
    // game hasn't written into the save yet, because it's still running or it crashed.
    const walPath = try std.mem.concat(allocator, u8, &.{ path, "-wal" });
    defer allocator.free(walPath);
    const unsaved = if (std.Io.Dir.cwd().statFile(io, walPath, .{})) |wal| wal.size > 0 else |_| false;

    const db = DB.initImmutable(allocator, path) catch |err| return fail(problem, .unopenable, err);
    errdefer db.deinit();

    // SQLite opens any file lazily, so this first query is where a wrong file shows up.
    const list = readTileList(allocator, db) catch |err| return fail(problem, .notASave, err);
    errdefer allocator.free(list);
    if (list.len == 0) return fail(problem, .noChunks, null);

    // Which block code each numeric block ID stands for, in this save.
    const gameData = GameData.read(allocator, db) catch |err| return fail(problem, .unreadableBlockList, err);
    errdefer gameData.deinit();
    const appearances = try appearancesByCode(allocator, gameData);
    errdefer allocator.free(appearances);
    const tints = try allocator.alloc(BlockTint, gameData.blockCodes.len);
    @memset(tints, .{});

    return .{
        .tints = tints,
        .seasonProgress = gameData.yearProgress(),
        .unsaved = unsaved,
        .path = path,
        .db = db,
        .gameData = gameData,
        .tileList = list,
        .appearances = appearances,
        // Chunk levels in the world: 8 for the default height of 256.
        .levels = std.math.divCeil(usize, gameData.worldHeight, 32) catch unreachable,
    };
}

fn fail(problem: *Problem, kind: Problem.Kind, cause: ?anyerror) error{InvalidSaveFile} {
    problem.* = .{ .kind = kind, .cause = cause };
    return error.InvalidSaveFile;
}

pub fn close(self: SaveFile, allocator: std.mem.Allocator) void {
    allocator.free(self.tints);
    allocator.free(self.appearances);
    self.gameData.deinit();
    allocator.free(self.tileList);
    self.db.deinit();
}

/// The world, for a map of it. The game shows positions relative to the world's centre
/// (docs/save-format/README.md#2-positions).
pub fn describe(self: *const SaveFile) world.Description {
    return .{
        .game = .{ .name = "Vintage Story", .version = self.gameData.gameVersion },
        .name = self.gameData.name,
        .origin = .{ .x = @intCast(self.gameData.worldWidth / 2), .z = @intCast(self.gameData.worldLength / 2) },
    };
}

/// The world's height and sea level.
pub fn heights(self: *const SaveFile) world.Heights {
    return .{ .world = @intCast(self.gameData.worldHeight), .sea = @intCast(self.gameData.seaLevel()) };
}

/// How many block IDs the save has; IDs run from 0 below it.
pub fn blockCount(self: *const SaveFile) usize {
    return self.gameData.blockCodes.len;
}

/// The block code for a block ID, e.g. "rock-granite".
pub fn blockName(self: *const SaveFile, id: i32) ?[]const u8 {
    return self.gameData.blockCode(id);
}

/// The game's own map colours (vsessentialsmod `ChunkMapLayer`), for what a theme's style
/// leaves out. Its edges are in the same ink as the rest of its lines.
pub const palette: world.Palette = .{
    .colours = .init(.{
        .land = .{ 0xAC, 0x88, 0x58 },
        .desert = .{ 0xC4, 0xA4, 0x68 },
        .forest = .{ 0x98, 0x84, 0x4C },
        .plant = .{ 0x80, 0x86, 0x50 },
        .settlement = .{ 0x85, 0x68, 0x44 },
        .road = .{ 0x80, 0x50, 0x30 },
        .devastation = .{ 0x75, 0x5C, 0x3C },
        .glacier = .{ 0xE0, 0xE0, 0xC0 },
        .lake = .{ 0xCC, 0xC8, 0x90 },
        .ocean = .{ 0xCC, 0xC8, 0x90 },
        .lava = .{ 0xCC, 0xC8, 0x90 },
    }),
    .ink = .{ 0x48, 0x30, 0x18 },
    .wateredge = .{ 0x48, 0x30, 0x18 },
};

/// The colour maps that tint a block (docs/rendering.md#climate-and-season-tint).
pub const BlockTint = struct {
    climate: ?*const Tint.ColourMap = null,
    season: ?*const Tint.ColourMap = null,
};

fn blockTint(self: *const SaveFile, id: i32) BlockTint {
    return if (id >= 0 and id < self.tints.len) self.tints[@intCast(id)] else .{};
}

/// The game's seasons (vsapi `EnumSeason`), to draw a map in rather than at the save's date.
pub const Season = enum {
    spring,
    summer,
    fall,
    winter,

    /// The middle of the season, through the year from the start of January, taking spring
    /// to be March to May, as in the northern hemisphere.
    pub fn progress(self: Season) f32 {
        const month: f32 = switch (self) {
            .winter => 0.5,
            .spring => 3.5,
            .summer => 6.5,
            .fall => 9.5,
        };
        return month / 12;
    }
};

/// How a block ID appears on the map. Anything unknown is land.
pub fn appearance(self: *const SaveFile, id: i32) world.Appearance {
    return if (id >= 0 and id < self.appearances.len) self.appearances[@intCast(id)] else .{ .mapType = .land };
}

/// Takes each block's appearance from the prepared blocks: its map type is its map colour code
/// (docs/rendering.md#block-colours), and it's drawn as a lake if it's water, or ice other
/// than glacier ice, and looked under if it's snow, as the game's map has it; its colour and
/// grain are its texture's. Blocks they don't have keep what their code says. The appearances
/// point into `prepared`, which must outlast rendering.
pub fn useBlocks(self: *SaveFile, prepared: *const Prepared) void {
    for (self.appearances, self.gameData.blockCodes) |*blockAppearance, maybeCode| {
        const code = maybeCode orelse continue;
        const block = prepared.blocks.get(code) orelse continue;
        const ice = std.mem.eql(u8, block.material, "Ice");
        blockAppearance.* = .{
            .mapType = std.meta.stringToEnum(world.MapType, block.colorCode) orelse .land,
            .lake = std.mem.eql(u8, block.material, "Water") or (ice and !std.mem.eql(u8, code, "glacierice")),
            .cover = std.mem.eql(u8, block.material, "Snow"),
            .colour = block.colour,
            .grain = block.grain,
        };
    }
    for (self.tints, self.gameData.blockCodes) |*tint, maybeCode| {
        const block = prepared.blocks.get(maybeCode orelse continue) orelse continue;
        tint.* = .{ .climate = block.climateColourMap, .season = block.seasonColourMap };
    }
}

/// A tile is 16 × 16 chunk columns, the same area as a map region.
const chunksPerTile = tiles.size / 32;

/// The tiles that may have something to draw: those holding a chunk column with a map chunk.
/// Every chunk column has one in the saves seen (docs/save-format/README.md#2-positions), and
/// the table has a row per column where `chunk` has one per chunk, so it's much quicker to go
/// through. Only fully generated columns are drawn, though (see Reader.readColumn), so a tile
/// holding only partly generated ones comes out empty and isn't written; telling them apart
/// here would mean reading every map chunk before starting. Columns in other dimensions than
/// the world itself, such as the time-switched alternate world, aren't part of the map.
fn readTileList(allocator: std.mem.Allocator, db: DB) ![]tiles.Tile {
    var set: std.AutoArrayHashMapUnmanaged(tiles.Tile, void) = .empty;
    defer set.deinit(allocator);
    const rows = try db.prepare("SELECT position FROM mapchunk;");
    defer rows.finalize();
    while (rows.step()) {
        const position: Chunk.Position = @bitCast(rows.column(u64, 0));
        if (position.dimension() != 0) continue;
        try set.put(allocator, .{ .x = position.x / chunksPerTile, .y = position.z / chunksPerTile }, {});
    }
    return allocator.dupe(tiles.Tile, set.keys());
}

/// Each block ID's appearance from its code alone, for when there are no prepared blocks:
/// saltwater is `ocean` and lava `lava` (docs/rendering.md#how-the-game-draws-its-own-world-map),
/// other water `lake`, snow layers `glacier` and looked under, and everything else `land`. A liquid surface that isn't one of those
/// is drawn as a lake.
fn appearancesByCode(allocator: std.mem.Allocator, gameData: GameData) ![]world.Appearance {
    const appearances = try allocator.alloc(world.Appearance, gameData.blockCodes.len);
    for (appearances, gameData.blockCodes) |*blockAppearance, code| {
        const name = code orelse "";
        blockAppearance.* = if (std.mem.startsWith(u8, name, "saltwater-"))
            .{ .mapType = .ocean, .lake = true }
        else if (std.mem.startsWith(u8, name, "lava-"))
            .{ .mapType = .lava }
        else if (std.mem.startsWith(u8, name, "water-") or std.mem.startsWith(u8, name, "boilingwater-"))
            .{ .mapType = .lake, .lake = true }
        else if (std.mem.startsWith(u8, name, "snowlayer-"))
            .{ .mapType = .glacier, .cover = true }
        else
            .{ .mapType = .land };
    }
    return appearances;
}

test appearancesByCode {
    const codes = [_]?[]const u8{ "air", "water-still-7", "saltwater-n-3", "lava-still-7", "boilingwater-still-7", "snowlayer-1", null };
    const gameData: GameData = .{ .arena = undefined, .blockCodes = &codes, .itemCodes = &.{}, .worldHeight = 256 };
    const appearances = try appearancesByCode(std.testing.allocator, gameData);
    defer std.testing.allocator.free(appearances);
    const expected = [_]world.Appearance{
        .{ .mapType = .land },
        .{ .mapType = .lake, .lake = true },
        .{ .mapType = .ocean, .lake = true },
        .{ .mapType = .lava },
        .{ .mapType = .lake, .lake = true },
        .{ .mapType = .glacier, .cover = true },
        .{ .mapType = .land },
    };
    try std.testing.expectEqualSlices(world.Appearance, &expected, appearances);
}

/// One thread's connection, decoder and buffers, reused for every tile it reads.
pub const Reader = struct {
    save: *const SaveFile,
    db: DB,
    mapChunkRow: DB.Stmt,
    chunkRow: DB.Stmt,
    mapRegionRow: DB.Stmt,
    decoder: Chunk.Decoder,
    chunk: *Chunk,
    mapChunk: *MapChunk,
    /// The climate map of the tile's map region, for tints.
    climate: Tint.ClimateMap,
    /// Chunks read: those holding a surface block, in each tile and the ring around it.
    chunksRead: usize = 0,

    pub fn init(save: *const SaveFile, allocator: std.mem.Allocator) !Reader {
        const db = try DB.initImmutable(allocator, save.path);
        errdefer db.deinit();
        const mapChunkRow = try db.prepare("SELECT data FROM mapchunk WHERE position = ?1;");
        errdefer mapChunkRow.finalize();
        const chunkRow = try db.prepare("SELECT data FROM chunk WHERE position = ?1;");
        errdefer chunkRow.finalize();
        const mapRegionRow = try db.prepare("SELECT data FROM mapregion WHERE position = ?1;");
        errdefer mapRegionRow.finalize();
        const climateValues = try allocator.alloc(i32, Tint.ClimateMap.maxSize * Tint.ClimateMap.maxSize);
        errdefer allocator.free(climateValues);
        var decoder: Chunk.Decoder = try .init(allocator, Chunk.Decoder.defaultBlockEntityBytes);
        errdefer decoder.deinit(allocator);
        const chunk = try allocator.create(Chunk);
        errdefer allocator.destroy(chunk);
        chunk.* = .{};
        const mapChunk = try allocator.create(MapChunk);
        return .{
            .save = save,
            .db = db,
            .mapChunkRow = mapChunkRow,
            .chunkRow = chunkRow,
            .mapRegionRow = mapRegionRow,
            .decoder = decoder,
            .chunk = chunk,
            .mapChunk = mapChunk,
            .climate = .{ .values = climateValues },
        };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.climate.values);
        allocator.destroy(self.mapChunk);
        allocator.destroy(self.chunk);
        self.decoder.deinit(allocator);
        self.mapRegionRow.finalize();
        self.chunkRow.finalize();
        self.mapChunkRow.finalize();
        self.db.deinit();
    }

    /// Fills `surface` with the tile's block columns and the ring around them, from the save.
    pub fn read(self: *Reader, tile: tiles.Tile, surface: *world.Surface) !void {
        surface.clear();
        // The surface's north-west corner, in blocks, and the chunk column holding it.
        const x0 = @as(i64, tile.x) * tiles.size - 1;
        const z0 = @as(i64, tile.y) * tiles.size - 1;
        const cx0 = @as(i64, tile.x) * chunksPerTile - 1;
        const cz0 = @as(i64, tile.y) * chunksPerTile - 1;
        for (0..chunksPerTile + 2) |j| for (0..chunksPerTile + 2) |i| {
            const cx = cx0 + @as(i64, @intCast(i));
            const cz = cz0 + @as(i64, @intCast(j));
            if (cx < 0 or cz < 0 or cx > Chunk.Position.maxXZ or cz > Chunk.Position.maxXZ) continue;
            try self.readColumn(surface.*, @intCast(cx), @intCast(cz), x0, z0);
        };
        if (surface.topTint.len > 0) try self.readTints(tile, surface.*);
    }

    /// Tints the top solid block and the top liquid of each of the tile's own columns by
    /// the climate there, from the tile's map region (the same area), and the season. A tile
    /// without a climate map stays untinted.
    fn readTints(self: *Reader, tile: tiles.Tile, surface: world.Surface) !void {
        const save = self.save;
        if (tile.x < 0 or tile.y < 0) return;
        const region: Chunk.Position = .{ .x = @intCast(tile.x), .z = @intCast(tile.y) };
        self.mapRegionRow.bind(1, region.position64());
        defer self.mapRegionRow.reset();
        if (!self.mapRegionRow.step()) return;
        var parser: ProtoBuf = .{ .buf = self.mapRegionRow.column([]const u8, 0) };
        const found = while (try parser.next()) |field| {
            if (field.field_number == 3 and field.data == .LEN) break try self.climate.decode(field.data.LEN);
        } else false;
        if (!found) return;

        const sea: i32 = @intCast(save.gameData.seaLevel());
        const side = world.Surface.side;
        for (0..tiles.size) |pz| for (0..tiles.size) |px| {
            const i = (pz + 1) * side + px + 1;
            const top = if (surface.top[i] != null) save.blockTint(surface.topBlock[i]) else BlockTint{};
            const liquid = if (surface.liquidTop[i] != null) save.blockTint(surface.liquidBlock[i]) else BlockTint{};
            if (top.climate == null and top.season == null and liquid.climate == null and liquid.season == null) continue;
            const here = self.climate.at(@as(f32, @floatFromInt(px)) / tiles.size, @as(f32, @floatFromInt(pz)) / tiles.size);
            if (top.climate != null or top.season != null) surface.topTint[i] = Tint.tint(top.climate, top.season, here, surface.top[i].?, sea, save.seasonProgress);
            if (liquid.climate != null or liquid.season != null) surface.liquidTint[i] = Tint.tint(liquid.climate, liquid.season, here, surface.liquidTop[i].?, sea, save.seasonProgress);
        };
    }

    /// Records one chunk column's block columns that fall in the tile or its ring: from their
    /// stored heights where they have them, reading only the chunks those point into, and by
    /// scanning down where they don't.
    fn readColumn(self: *Reader, surface: world.Surface, cx: u64, cz: u64, x0: i64, z0: i64) !void {
        // Keys in the world itself, dimension 0.
        const base: Chunk.Position = .{ .x = @intCast(cx), .z = @intCast(cz) };
        // Only fully generated chunk columns are drawn: the partly generated ones around
        // them lack trees and plants, and the game's own map leaves them out too
        // (docs/rendering.md#how-the-game-draws-its-own-world-map). Others stay
        // transparent, and in the ring around a tile they count as no blocks.
        self.mapChunkRow.bind(1, base.position64());
        defer self.mapChunkRow.reset();
        if (!self.mapChunkRow.step()) return;
        const stored = self.mapChunk;
        stored.decode(self.mapChunkRow.column([]const u8, 0)) catch |err| {
            // A finished column whose heights can't be read is scanned instead. One whose
            // stage can't be read either isn't drawn.
            if (stored.stage != .done) {
                if (stored.stage == .none) std.debug.print("storymap: skipping chunk column ({}, {}): {s}\n", .{ cx, cz, @errorName(err) });
                return;
            }
            std.debug.print("storymap: scanning chunk column ({}, {}) for heights: {s}\n", .{ cx, cz, @errorName(err) });
            @memset(&stored.rainHeight, MapChunk.unset);
        };
        if (stored.stage != .done) return;

        // The block columns, within the chunk column, that fall in the tile or its ring.
        const span: Span = .{
            .chunkX = cx,
            .chunkZ = cz,
            .x0 = @intCast(std.math.clamp(x0 - @as(i64, @intCast(cx * 32)), 0, 32)),
            .x1 = @intCast(std.math.clamp(x0 + world.Surface.side - @as(i64, @intCast(cx * 32)), 0, 32)),
            .z0 = @intCast(std.math.clamp(z0 - @as(i64, @intCast(cz * 32)), 0, 32)),
            .z1 = @intCast(std.math.clamp(z0 + world.Surface.side - @as(i64, @intCast(cz * 32)), 0, 32)),
            .areaX = x0,
            .areaZ = z0,
        };

        // The levels the surface heights point into. Chunks at or below `scanFrom` are all
        // read: for columns without a stored height, or whose stored height is stale.
        // Levels with no chunk saved are just a key that isn't found.
        const levels = self.save.levels;
        var needed: std.StaticBitSet(Chunk.Position.levels) = .empty;
        var scanFrom: ?usize = null;
        for (span.z0..span.z1) |z| for (span.x0..span.x1) |x| {
            const rain = &stored.rainHeight[z * 32 + x];
            // A height above the world is stale too.
            if (rain.* != MapChunk.unset and rain.* / 32 >= levels) rain.* = MapChunk.unset;
            if (rain.* == MapChunk.unset) scanFrom = levels - 1 else needed.set(rain.* / 32);
        };

        // Top down, so a stale height found in one chunk can still be scanned for below it.
        var level: usize = levels;
        while (level > 0) {
            level -= 1;
            if (!needed.isSet(level) and (scanFrom == null or level > scanFrom.?)) continue;
            var at = base;
            at.y = @intCast(level);
            const position = at.position64();
            self.chunkRow.bind(1, position);
            defer self.chunkRow.reset();
            if (!self.chunkRow.step()) {
                // No chunk here: heights pointing here are stale.
                if (forgetHeightsAt(stored, level)) scanFrom = @max(scanFrom orelse level, level);
                continue;
            }
            self.chunksRead += 1;
            decodeOrWarn(&self.decoder, self.chunk, position, self.chunkRow.column([]const u8, 0)) catch continue;
            if (recordChunk(surface, self.chunk, stored, span)) scanFrom = @max(scanFrom orelse level, level);
        }
    }
};

/// Records the block columns of `span` in one chunk: from their stored heights where they
/// have them, by scanning down where they don't. Returns whether a stored height turned out
/// stale, in which case its column needs the chunks below scanned too.
fn recordChunk(surface: world.Surface, chunk: *const Chunk, stored: *MapChunk, span: Span) bool {
    var stale = false;
    for (span.z0..span.z1) |z| for (span.x0..span.x1) |x| {
        const index = span.index(x, z);
        const rain = &stored.rainHeight[z * 32 + x];
        if (rain.* != MapChunk.unset) {
            if (rain.* / 32 != chunk.position.y) continue;
            if (recordStored(surface, chunk, x, rain.* % 32, z, rain.*, stored.terrainHeight[z * 32 + x], index)) continue;
            // The block there is gone: the column has no blocks at all (the game stores 0
            // then), or it changed after its height was stored. Scan it instead.
            rain.* = MapChunk.unset;
            stale = true;
        }
        // Plants growing in water, such as seaweed and reeds, share their place with it:
        // from above, the water shows, and its depth goes down to the ground below them.
        recordTop(&chunk.blocks, &chunk.liquids, chunk.position.y, x, z, &surface.top[index], &surface.topBlock[index]);
        recordTop(&chunk.liquids, null, chunk.position.y, x, z, &surface.liquidTop[index], &surface.liquidBlock[index]);
        if (surface.top[index]) |top| if (top / 32 == chunk.position.y) {
            surface.underBlock[index] = blockBelow(chunk, x, top % 32, z);
        };
    };
    return stale;
}

/// The block under local height `y` in a chunk, liquid first, as the game's map reads it; 0
/// if it's in the chunk below.
fn blockBelow(chunk: *const Chunk, x: usize, y: usize, z: usize) i32 {
    if (y == 0) return 0;
    const at = ((y - 1) * 32 + z) * 32 + x;
    const liquid = if (chunk.liquids.bits == 0) 0 else chunk.liquids.get(at);
    if (liquid != 0) return liquid;
    return if (chunk.blocks.bits == 0) 0 else chunk.blocks.get(at);
}

/// Records a column from its stored heights: the block at the rain height, in the chunk that
/// holds it. Rain stops at water, so a liquid there is the water surface, and the terrain
/// height is its bed. Returns false, recording nothing, if there's no block there.
fn recordStored(surface: world.Surface, chunk: *const Chunk, x: usize, y: usize, z: usize, rain: u16, terrain: u16, index: usize) bool {
    const block = (y * 32 + z) * 32 + x;
    const liquidId = if (chunk.liquids.bits == 0) 0 else chunk.liquids.get(block);
    const solid = if (chunk.blocks.bits == 0) 0 else chunk.blocks.get(block);
    if (liquidId == 0 and solid == 0) return false;
    if (liquidId != 0) {
        surface.liquidTop[index] = rain;
        surface.liquidBlock[index] = liquidId;
        // The block under the water isn't looked up; only its depth is drawn.
        surface.top[index] = if (terrain == MapChunk.unset) rain else @min(terrain, rain);
        surface.topBlock[index] = 0;
    } else {
        surface.top[index] = rain;
        surface.topBlock[index] = solid;
        surface.underBlock[index] = blockBelow(chunk, x, y, z);
        // Liquid under the top block, such as a lake under a tree's leaves: the highest
        // liquid in the column, though the solid block above it is what shows. It can only
        // be above the terrain height, the ground before trees and plants grew, which for
        // most columns is the top itself, so only the blocks between are looked at, within
        // the chunk.
        if (chunk.liquids.bits != 0 and terrain != MapChunk.unset and terrain < rain) {
            // The chunk's lowest height, and the terrain's within it.
            const base: usize = rain - y;
            const floor = @max(@as(usize, terrain), base) - base;
            var below = y;
            while (below > floor) {
                below -= 1;
                const liquidBelow = chunk.liquids.get((below * 32 + z) * 32 + x);
                if (liquidBelow == 0) continue;
                surface.liquidTop[index] = rain - @as(u16, @intCast(y - below));
                surface.liquidBlock[index] = liquidBelow;
                break;
            }
        }
    }
    return true;
}

/// The block columns of one chunk column that fall in a tile or its ring: x0..x1 and z0..z1
/// within it.
const Span = struct {
    chunkX: u64,
    chunkZ: u64,
    x0: usize,
    x1: usize,
    z0: usize,
    z1: usize,
    /// The surface's north-west corner, in blocks.
    areaX: i64,
    areaZ: i64,

    /// The index in the surface of block column (x, z) of the chunk column.
    fn index(self: Span, x: usize, z: usize) usize {
        const ax: usize = @intCast(@as(i64, @intCast(self.chunkX * 32 + x)) - self.areaX);
        const az: usize = @intCast(@as(i64, @intCast(self.chunkZ * 32 + z)) - self.areaZ);
        return az * world.Surface.side + ax;
    }
};

/// Decodes a chunk; one that can't be decoded is skipped with a warning, so it doesn't stop
/// the whole map.
fn decodeOrWarn(decoder: *Chunk.Decoder, chunk: *Chunk, position: u64, data: []const u8) !void {
    decoder.decode(chunk, position, data) catch |err| {
        const pos = chunk.position;
        std.debug.print("storymap: skipping chunk ({}, {}, {}): {s}\n", .{ pos.x, pos.y, pos.z, @errorName(err) });
        return err;
    };
}

/// Forgets the stored heights that point into chunk level `level`, so their columns are
/// scanned instead. Returns whether there were any.
fn forgetHeightsAt(stored: *MapChunk, level: usize) bool {
    var any = false;
    for (&stored.rainHeight) |*rain| if (rain.* != MapChunk.unset and rain.* / 32 == level) {
        rain.* = MapChunk.unset;
        any = true;
    };
    return any;
}

/// Records the highest block of a chunk's layer in one column, unless a chunk above has
/// already recorded a higher one. Blocks where `hiddenBy` has a block are skipped.
fn recordTop(layer: *const Compression.Layer, hiddenBy: ?*const Compression.Layer, chunkY: usize, x: usize, z: usize, top: *?u16, block: *i32) void {
    if (layer.bits == 0) return; // all air
    const mask = if (hiddenBy) |other| if (other.bits == 0) null else other else null;
    // Walk down from the top of the chunk and stop at the first block.
    for (0..32) |i| {
        const y = 31 - i;
        const index = (y * 32 + z) * 32 + x;
        const id = layer.get(index);
        if (id == 0) continue;
        if (mask) |other| if (other.get(index) != 0) continue;
        const worldY: u16 = @intCast(chunkY * 32 + y);
        if (top.* == null or top.*.? < worldY) {
            top.* = worldY;
            block.* = id;
        }
        return;
    }
}
