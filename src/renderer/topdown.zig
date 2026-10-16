//! The top-down map: one pixel per block column, coloured by what's on top, in tiles of
//! 512 × 512 blocks (see tiles.zig).
const std = @import("std");
const Io = std.Io;
const DB = @import("../sqlite.zig");
const Chunk = @import("../Chunk.zig");
const Compression = @import("../Compression.zig");
const MapChunk = @import("../MapChunk.zig");
const GameData = @import("../GameData.zig");
const tiles = @import("../tiles.zig");

/// What a render covered and how long it took.
pub const Stats = struct {
    /// Tiles written, at every level.
    tiles: usize = 0,
    levels: usize = 0,
    /// Chunks read: those holding a surface block, in each tile and the ring around it.
    chunksRead: usize = 0,
    /// Opening the save and reading its block list and which tiles it has.
    open: Io.Duration = .zero,
    /// Rendering the tiles, start to finish.
    render: Io.Duration = .zero,
    /// Time the workers spent drawing tiles, and encoding and writing them, added up.
    draw: Io.Duration = .zero,
    encode: Io.Duration = .zero,
};

/// Renders the save's top-down tiles into `output`. With `stats`, records the stages' times
/// instead of printing a summary of the map.
pub fn render(allocator: std.mem.Allocator, io: Io, dbPath: []const u8, output: tiles.Output, stats: ?*Stats) !void {
    const start: Io.Timestamp = .now(io, .awake);

    // Never write next to the save: it may be in the game's own Saves folder.
    const db = DB.initImmutable(allocator, dbPath) catch |err| {
        std.debug.print("storymap: can't open {s} ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer db.deinit();

    const list = tileList(allocator, db) catch |err| {
        // SQLite opens any file lazily, so this first query is where a wrong file shows up.
        std.debug.print("storymap: {s} isn't a Vintage Story save ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(list);
    if (list.len == 0) return error.NoChunks;

    // Which block code each numeric block ID stands for, in this save.
    const gameData = GameData.read(allocator, db) catch |err| {
        std.debug.print("storymap: can't read the block list in {s} ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer gameData.deinit();

    var view: View = try .init(allocator, dbPath, gameData);
    defer view.deinit(allocator);
    const opened: Io.Timestamp = .now(io, .awake);

    const rendered = try tiles.render(View, allocator, io, &view, list, output);

    if (stats) |out| {
        out.* = .{
            .tiles = rendered.tiles,
            .levels = rendered.levels,
            .chunksRead = view.chunksRead,
            .open = start.durationTo(opened),
            .render = opened.untilNow(io, .awake),
            .draw = rendered.draw,
            .encode = rendered.encode,
        };
        return;
    }
    std.debug.print("{} tiles in {} levels, surface y {}..{}\n", .{ rendered.tiles, rendered.levels, view.lowest, view.highest });
    printSurfaceBlocks(gameData, view.surface);
}

/// A top-down tile is 16 × 16 chunk columns, the same area as a map region.
const chunksPerTile = tiles.size / 32;

/// The tiles that may have something to draw: those holding a chunk column with a map chunk.
/// Every chunk column has one in the saves seen (docs/save-format/README.md#2-positions), and
/// the table has a row per column where `chunk` has one per chunk, so it's much quicker to go
/// through. Only fully generated columns are drawn, though (see Worker.readColumn), so a tile
/// holding only partly generated ones comes out empty and isn't written; telling them apart
/// here would mean reading every map chunk before starting. Chunk x is the low 27 bits of
/// `position` and z the next 27 (see Chunk.Position).
fn tileList(allocator: std.mem.Allocator, db: DB) ![]tiles.Tile {
    var set: std.AutoArrayHashMapUnmanaged(tiles.Tile, void) = .empty;
    defer set.deinit(allocator);
    const rows = try db.prepare("SELECT position FROM mapchunk;");
    defer rows.finalize();
    while (rows.step()) {
        const position = rows.column(u64, 0);
        try set.put(allocator, .{
            .x = @intCast((position & 134217727) / chunksPerTile),
            .y = @intCast(((position >> 27) & 134217727) / chunksPerTile),
        }, {});
    }
    return allocator.dupe(tiles.Tile, set.keys());
}

/// What every worker shares, read-only while they draw, and their totals once they're done.
const View = struct {
    pub const name = "topdown";

    dbPath: []const u8,
    /// How many chunk levels the world has: chunks have y 0 to `levels` − 1.
    levels: usize,
    heights: Heights,
    /// The kind of liquid each block ID stands for.
    kinds: []Liquid,

    chunksRead: usize = 0,
    /// How many columns show each block ID from above.
    surface: []usize,
    /// The lowest and highest solid surface.
    lowest: u16 = std.math.maxInt(u16),
    highest: u16 = 0,

    fn init(allocator: std.mem.Allocator, dbPath: []const u8, gameData: GameData) !View {
        const kinds = try liquidKinds(allocator, gameData);
        errdefer allocator.free(kinds);
        const surface = try allocator.alloc(usize, gameData.blockCodes.len);
        @memset(surface, 0);
        return .{
            .dbPath = dbPath,
            // Chunk levels in the world: 8 for the default height of 256.
            .levels = std.math.divCeil(usize, gameData.worldHeight, 32) catch unreachable,
            .heights = .of(gameData),
            .kinds = kinds,
            .surface = surface,
        };
    }

    fn deinit(self: View, allocator: std.mem.Allocator) void {
        allocator.free(self.kinds);
        allocator.free(self.surface);
    }

    pub fn collect(self: *View, worker: *const Worker) void {
        self.chunksRead += worker.chunksRead;
        for (self.surface, worker.surface) |*total, count| total.* += count;
        self.lowest = @min(self.lowest, worker.lowest);
        self.highest = @max(self.highest, worker.highest);
    }

    /// One thread's connection, decoder and buffers, reused for every tile it draws.
    pub const Worker = struct {
        view: *const View,
        db: DB,
        mapChunkRow: DB.Stmt,
        chunkRow: DB.Stmt,
        decoder: Chunk.Decoder,
        chunk: *Chunk,
        mapChunk: *MapChunk,
        area: Area,

        chunksRead: usize = 0,
        surface: []usize,
        lowest: u16 = std.math.maxInt(u16),
        highest: u16 = 0,

        pub fn init(view: *const View, allocator: std.mem.Allocator) !Worker {
            const db = try DB.initImmutable(allocator, view.dbPath);
            errdefer db.deinit();
            const mapChunkRow = try db.prepare("SELECT data FROM mapchunk WHERE position = ?1;");
            errdefer mapChunkRow.finalize();
            const chunkRow = try db.prepare("SELECT data FROM chunk WHERE position = ?1;");
            errdefer chunkRow.finalize();
            var decoder: Chunk.Decoder = try .init(allocator, Chunk.Decoder.defaultBlockEntityBytes);
            errdefer decoder.deinit(allocator);
            const chunk = try allocator.create(Chunk);
            errdefer allocator.destroy(chunk);
            chunk.* = .{};
            const mapChunk = try allocator.create(MapChunk);
            errdefer allocator.destroy(mapChunk);
            var area: Area = try .init(allocator);
            errdefer area.deinit(allocator);
            const surface = try allocator.alloc(usize, view.surface.len);
            @memset(surface, 0);
            return .{
                .view = view,
                .db = db,
                .mapChunkRow = mapChunkRow,
                .chunkRow = chunkRow,
                .decoder = decoder,
                .chunk = chunk,
                .mapChunk = mapChunk,
                .area = area,
                .surface = surface,
            };
        }

        pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
            allocator.free(self.surface);
            self.area.deinit(allocator);
            allocator.destroy(self.mapChunk);
            allocator.destroy(self.chunk);
            self.decoder.deinit(allocator);
            self.chunkRow.finalize();
            self.mapChunkRow.finalize();
            self.db.deinit();
        }

        /// Reads the tile's block columns and the ring around them from the save, then
        /// colours its pixels. Returns false if it has nothing on it.
        pub fn draw(self: *Worker, tile: tiles.Tile, pixels: *tiles.Pixels) !bool {
            self.area.clear();
            // The area's north-west corner, in blocks, and the chunk column holding it.
            const x0 = @as(i64, tile.x) * tiles.size - 1;
            const z0 = @as(i64, tile.y) * tiles.size - 1;
            const cx0 = @as(i64, tile.x) * chunksPerTile - 1;
            const cz0 = @as(i64, tile.y) * chunksPerTile - 1;
            for (0..chunksPerTile + 2) |j| for (0..chunksPerTile + 2) |i| {
                const cx = cx0 + @as(i64, @intCast(i));
                const cz = cz0 + @as(i64, @intCast(j));
                if (cx < 0 or cz < 0 or cx > 134217727 or cz > 134217727) continue;
                try self.readColumn(@intCast(cx), @intCast(cz), x0, z0);
            };
            return self.paint(pixels);
        }

        /// Records one chunk column's block columns that fall in the area: from their stored
        /// heights where they have them, reading only the chunks those point into, and by
        /// scanning down where they don't.
        fn readColumn(self: *Worker, cx: u64, cz: u64, x0: i64, z0: i64) !void {
            const base = cx | cz << 27;
            // Only fully generated chunk columns are drawn: the partly generated ones around
            // them lack trees and plants, and the game's own map leaves them out too
            // (docs/rendering.md#how-the-game-draws-its-own-world-map). Others stay
            // transparent, and in the ring around a tile they count as no blocks.
            self.mapChunkRow.bind(1, base);
            defer self.mapChunkRow.reset();
            if (!self.mapChunkRow.step()) return;
            const heights = self.mapChunk;
            heights.decode(self.mapChunkRow.column([]const u8, 0)) catch |err| {
                // A finished column whose heights can't be read is scanned instead. One whose
                // stage can't be read either isn't drawn.
                if (heights.stage != .done) {
                    if (heights.stage == .none) std.debug.print("storymap: skipping chunk column ({}, {}): {s}\n", .{ cx, cz, @errorName(err) });
                    return;
                }
                std.debug.print("storymap: scanning chunk column ({}, {}) for heights: {s}\n", .{ cx, cz, @errorName(err) });
                @memset(&heights.rainHeight, MapChunk.unset);
            };
            if (heights.stage != .done) return;

            // The block columns, within the chunk column, that fall in the area.
            const span: Span = .{
                .chunkX = cx,
                .chunkZ = cz,
                .x0 = @intCast(std.math.clamp(x0 - @as(i64, @intCast(cx * 32)), 0, 32)),
                .x1 = @intCast(std.math.clamp(x0 + Area.side - @as(i64, @intCast(cx * 32)), 0, 32)),
                .z0 = @intCast(std.math.clamp(z0 - @as(i64, @intCast(cz * 32)), 0, 32)),
                .z1 = @intCast(std.math.clamp(z0 + Area.side - @as(i64, @intCast(cz * 32)), 0, 32)),
                .areaX = x0,
                .areaZ = z0,
            };

            // The levels the surface heights point into. Chunks at or below `scanFrom` are all
            // read: for columns without a stored height, or whose stored height is stale.
            // Levels with no chunk saved are just a key that isn't found.
            const levels = self.view.levels;
            var needed: std.StaticBitSet(1024) = .empty;
            var scanFrom: ?usize = null;
            for (span.z0..span.z1) |z| for (span.x0..span.x1) |x| {
                const rain = &heights.rainHeight[z * 32 + x];
                // A height above the world is stale too.
                if (rain.* != MapChunk.unset and rain.* / 32 >= levels) rain.* = MapChunk.unset;
                if (rain.* == MapChunk.unset) scanFrom = levels - 1 else needed.set(rain.* / 32);
            };

            // Top down, so a stale height found in one chunk can still be scanned for below it.
            var level: usize = levels;
            while (level > 0) {
                level -= 1;
                if (!needed.isSet(level) and (scanFrom == null or level > scanFrom.?)) continue;
                const position = base | @as(u64, level) << 54;
                self.chunkRow.bind(1, position);
                defer self.chunkRow.reset();
                if (!self.chunkRow.step()) {
                    // No chunk here: heights pointing here are stale.
                    if (forgetHeightsAt(heights, level)) scanFrom = @max(scanFrom orelse level, level);
                    continue;
                }
                self.chunksRead += 1;
                decodeOrWarn(&self.decoder, self.chunk, position, self.chunkRow.column([]const u8, 0)) catch continue;
                if (self.area.recordChunk(self.chunk, heights, span)) scanFrom = @max(scanFrom orelse level, level);
            }
        }

        /// Colours the tile's pixels from the area, and counts what it shows. Returns false
        /// if nothing is drawn.
        fn paint(self: *Worker, pixels: *tiles.Pixels) bool {
            const area = &self.area;
            const view = self.view;
            const side = Area.side;
            var any = false;
            for (0..tiles.size) |py| for (0..tiles.size) |px| {
                const i = (py + 1) * side + px + 1;
                const pixel = &pixels[py * tiles.size + px];
                const here = Surface.of(area.top[i], area.liquidTop[i]);
                const y = here.height() orelse {
                    pixel.* = tiles.transparent;
                    continue;
                };
                any = true;
                const west: Surface = .of(area.top[i - 1], area.liquidTop[i - 1]);
                const north: Surface = .of(area.top[i - side], area.liquidTop[i - side]);
                const east: Surface = .of(area.top[i + 1], area.liquidTop[i + 1]);
                const south: Surface = .of(area.top[i + side], area.liquidTop[i + side]);

                if (area.top[i]) |solid| {
                    self.lowest = @min(self.lowest, solid);
                    self.highest = @max(self.highest, solid);
                }
                const block = if (here == .liquid) area.liquidBlock[i] else area.topBlock[i];
                if (block >= 0 and block < self.surface.len) self.surface[@intCast(block)] += 1;

                if (here == .liquid) {
                    // A coastline in ink where water meets land, as on an old map.
                    const shore = west == .land or north == .land or east == .land or south == .land;
                    const kind = if (block >= 0 and block < view.kinds.len) view.kinds[@intCast(block)] else .water;
                    pixel.* = if (shore and kind != .lava) ink else liquidColour(kind, if (area.top[i]) |ground| y - ground else maxDepth);
                    continue;
                }
                // Neighbours without blocks count as level ground.
                const slope = @as(i32, y) * 2 - (west.height() orelse y) - (north.height() orelse y);
                pixel.* = colour(y, view.heights, slope);
            };
            return any;
        }
    };
};

/// A tile's block columns and a one-block ring around them, so hill shading and coastlines
/// match across tile edges. Filled in from the save one chunk column at a time.
const Area = struct {
    const side = tiles.size + 2;

    /// Height of the highest non-air block in each column, or null if there is none.
    top: []?u16,
    /// The block ID at that height.
    topBlock: []i32,
    /// The same for liquids, which the save keeps in a layer of their own.
    liquidTop: []?u16,
    liquidBlock: []i32,

    fn init(allocator: std.mem.Allocator) !Area {
        const top = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(top);
        const topBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(topBlock);
        const liquidTop = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(liquidTop);
        const liquidBlock = try allocator.alloc(i32, side * side);
        return .{ .top = top, .topBlock = topBlock, .liquidTop = liquidTop, .liquidBlock = liquidBlock };
    }

    fn deinit(self: Area, allocator: std.mem.Allocator) void {
        allocator.free(self.top);
        allocator.free(self.topBlock);
        allocator.free(self.liquidTop);
        allocator.free(self.liquidBlock);
    }

    fn clear(self: Area) void {
        @memset(self.top, null);
        @memset(self.topBlock, 0);
        @memset(self.liquidTop, null);
        @memset(self.liquidBlock, 0);
    }

    /// Records the block columns of `span` in one chunk: from their stored heights where they
    /// have them, by scanning down where they don't. Returns whether a stored height turned
    /// out stale, in which case its column needs the chunks below scanned too.
    fn recordChunk(self: Area, chunk: *const Chunk, heights: *MapChunk, span: Span) bool {
        var stale = false;
        for (span.z0..span.z1) |z| for (span.x0..span.x1) |x| {
            const index = span.index(x, z);
            const rain = &heights.rainHeight[z * 32 + x];
            if (rain.* != MapChunk.unset) {
                if (rain.* / 32 != chunk.position.y) continue;
                if (self.recordStored(chunk, x, rain.* % 32, z, rain.*, heights.terrainHeight[z * 32 + x], index)) continue;
                // The block there is gone: the column has no blocks at all (the game stores 0
                // then), or it changed after its height was stored. Scan it instead.
                rain.* = MapChunk.unset;
                stale = true;
            }
            // Plants growing in water, such as seaweed and reeds, share their place with it:
            // from above, the water shows, and its depth goes down to the ground below them.
            recordTop(&chunk.blocks, &chunk.liquids, chunk.position.y, x, z, &self.top[index], &self.topBlock[index]);
            recordTop(&chunk.liquids, null, chunk.position.y, x, z, &self.liquidTop[index], &self.liquidBlock[index]);
        };
        return stale;
    }

    /// Records a column from its stored heights: the block at the rain height, in the chunk
    /// that holds it. Rain stops at water, so a liquid there is the water surface, and the
    /// terrain height is its bed. Returns false, recording nothing, if there's no block there.
    fn recordStored(self: Area, chunk: *const Chunk, x: usize, y: usize, z: usize, rain: u16, terrain: u16, index: usize) bool {
        const block = (y * 32 + z) * 32 + x;
        const liquid = if (chunk.liquids.bits == 0) 0 else chunk.liquids.get(block);
        const solid = if (chunk.blocks.bits == 0) 0 else chunk.blocks.get(block);
        if (liquid == 0 and solid == 0) return false;
        if (liquid != 0) {
            self.liquidTop[index] = rain;
            self.liquidBlock[index] = liquid;
            // The block under the water isn't looked up; only its depth is drawn.
            self.top[index] = if (terrain == MapChunk.unset) rain else @min(terrain, rain);
            self.topBlock[index] = 0;
        } else {
            self.top[index] = rain;
            self.topBlock[index] = solid;
        }
        return true;
    }
};

/// The block columns of one chunk column that fall in an area: x0..x1 and z0..z1 within it.
const Span = struct {
    chunkX: u64,
    chunkZ: u64,
    x0: usize,
    x1: usize,
    z0: usize,
    z1: usize,
    /// The area's north-west corner, in blocks.
    areaX: i64,
    areaZ: i64,

    /// The area index of block column (x, z) of the chunk column.
    fn index(self: Span, x: usize, z: usize) usize {
        const ax: usize = @intCast(@as(i64, @intCast(self.chunkX * 32 + x)) - self.areaX);
        const az: usize = @intCast(@as(i64, @intCast(self.chunkZ * 32 + z)) - self.areaZ);
        return az * Area.side + ax;
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
fn forgetHeightsAt(heights: *MapChunk, level: usize) bool {
    var any = false;
    for (&heights.rainHeight) |*rain| if (rain.* != MapChunk.unset and rain.* / 32 == level) {
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

/// The five most common blocks seen from above, by name.
fn printSurfaceBlocks(gameData: GameData, surface: []const usize) void {
    var columns: usize = 0;
    for (surface) |count| columns += count;
    if (columns == 0) return;
    var shown: [5]usize = undefined;
    var count: usize = 0;
    std.debug.print("most common surface blocks:", .{});
    while (count < shown.len) : (count += 1) {
        // The most common block not shown yet.
        var best: ?usize = null;
        for (surface, 0..) |n, id| {
            if (n == 0 or std.mem.indexOfScalar(usize, shown[0..count], id) != null) continue;
            if (best == null or n > surface[best.?]) best = id;
        }
        const id = best orelse break;
        shown[count] = id;
        const percent = surface[id] * 100 / columns;
        const separator = if (count == 0) "" else ",";
        if (gameData.blockCode(@intCast(id))) |code| {
            std.debug.print("{s} {s} {}%", .{ separator, code, percent });
        } else {
            std.debug.print("{s} #{} {}%", .{ separator, id, percent });
        }
    }
    std.debug.print("\n", .{});
}

/// Coastlines.
const ink = rgb(0x5C, 0x46, 0x2E);

/// What a column shows from above, and at what height.
const Surface = union(enum) {
    /// No blocks at all, as far as the save goes.
    none,
    land: u16,
    /// Liquid at or above the highest solid block. Plants growing in water share their
    /// block with it, so the water still shows.
    liquid: u16,

    fn of(top: ?u16, liquidTop: ?u16) Surface {
        const liquid = liquidTop orelse return if (top) |y| .{ .land = y } else .none;
        const land = top orelse return .{ .liquid = liquid };
        return if (liquid >= land) .{ .liquid = liquid } else .{ .land = land };
    }

    fn height(self: Surface) ?u16 {
        return switch (self) {
            .none => null,
            .land, .liquid => |y| y,
        };
    }
};

test Surface {
    try std.testing.expectEqual(Surface.none, Surface.of(null, null));
    try std.testing.expectEqual(Surface{ .land = 90 }, Surface.of(90, null));
    try std.testing.expectEqual(Surface{ .liquid = 109 }, Surface.of(90, 109));
    try std.testing.expectEqual(Surface{ .liquid = 109 }, Surface.of(109, 109)); // seaweed
    try std.testing.expectEqual(Surface{ .land = 120 }, Surface.of(120, 12)); // water in a cave
    try std.testing.expectEqual(Surface{ .liquid = 109 }, Surface.of(null, 109));
}

/// The liquids the map tells apart. Seas are saltwater; lakes, rivers and hot springs are
/// the other kinds of water (docs/rendering.md#how-the-game-draws-its-own-world-map).
const Liquid = enum { water, saltwater, lava };

/// The kind of liquid each block ID stands for, by its block code. Anything that isn't
/// saltwater or lava, including liquids from mods, is drawn as water.
fn liquidKinds(allocator: std.mem.Allocator, gameData: GameData) ![]Liquid {
    const kinds = try allocator.alloc(Liquid, gameData.blockCodes.len);
    for (kinds, gameData.blockCodes) |*kind, code| {
        const name = code orelse "";
        kind.* = if (std.mem.startsWith(u8, name, "saltwater-"))
            .saltwater
        else if (std.mem.startsWith(u8, name, "lava-"))
            .lava
        else
            .water;
    }
    return kinds;
}

test liquidKinds {
    const codes = [_]?[]const u8{ "air", "water-still-7", "saltwater-n-3", "lava-still-7", "boilingwater-still-7", null };
    const gameData: GameData = .{ .arena = undefined, .blockCodes = &codes, .itemCodes = &.{}, .worldHeight = 256 };
    const kinds = try liquidKinds(std.testing.allocator, gameData);
    defer std.testing.allocator.free(kinds);
    try std.testing.expectEqualSlices(Liquid, &.{ .water, .water, .saltwater, .lava, .water, .water }, kinds);
}

/// Shallowest and deepest colour of each liquid: faded washes, as on an old map.
const liquidColours = std.EnumArray(Liquid, [2][3]u8).init(.{
    .water = .{ .{ 0xB8, 0xC8, 0xB8 }, .{ 0x6C, 0x8A, 0x8A } },
    .saltwater = .{ .{ 0xB0, 0xC2, 0xC6 }, .{ 0x5A, 0x76, 0x88 } },
    .lava = .{ .{ 0xB8, 0x5A, 0x30 }, .{ 0x80, 0x30, 0x18 } },
});
/// Water this deep or deeper takes the deepest colour.
const maxDepth = 16;

/// The colour of a liquid `depth` blocks above the ground below it.
fn liquidColour(kind: Liquid, depth: u16) u32 {
    const colours = liquidColours.get(kind);
    const fraction = @as(usize, @min(depth, maxDepth)) * 256 / maxDepth;
    const mixed = mix(colours[0], colours[1], fraction);
    return rgb(mixed[0], mixed[1], mixed[2]);
}

test liquidColour {
    try std.testing.expectEqual(rgb(0xB8, 0xC8, 0xB8), liquidColour(.water, 0));
    try std.testing.expectEqual(rgb(0x6C, 0x8A, 0x8A), liquidColour(.water, maxDepth));
    try std.testing.expectEqual(rgb(0x6C, 0x8A, 0x8A), liquidColour(.water, 200));
    try std.testing.expectEqual(rgb(0x5A, 0x76, 0x88), liquidColour(.saltwater, maxDepth));
}

/// `from` blended towards `to` by `fraction` 256ths.
fn mix(from: [3]u8, to: [3]u8, fraction: usize) [3]u8 {
    var mixed: [3]u8 = undefined;
    for (&mixed, from, to) |*channel, a, b| {
        channel.* = @intCast((@as(usize, a) * (256 - fraction) + @as(usize, b) * fraction) / 256);
    }
    return mixed;
}

/// Ink by height, lowest first: an old map's sepia, from dark brown to pale yellow.
const ramp = [_][3]u8{
    .{ 0x4A, 0x30, 0x1A },
    .{ 0x8A, 0x64, 0x38 },
    .{ 0xC4, 0xA4, 0x6C },
    .{ 0xE4, 0xD2, 0xA0 },
    .{ 0xF6, 0xEE, 0xD2 },
};
/// The ramp entry for ground level, so most of the map is pale and only low ground is dark.
const groundStep = 3;

/// The surface heights the ramp is spread over. They depend only on the world, so every
/// part of a map, and every world, is coloured the same way.
const Heights = struct {
    /// The ramp's darkest end, and everything below it.
    low: u16,
    /// Sea level: the ground-level colour.
    ground: u16,
    /// The ramp's palest end, and everything above it.
    high: u16,

    /// For a world: in a default 256-block world, 70, 110 (sea level) and 174. The test worlds'
    /// surfaces have a median of 112. The ends are fractions of the world height, on the guess
    /// that taller worlds have taller terrain too.
    fn of(gameData: GameData) Heights {
        const sea = gameData.seaLevel();
        return .{
            .low = @intCast(sea -| gameData.worldHeight * 40 / 256),
            .ground = @intCast(sea),
            .high = @intCast(sea + gameData.worldHeight * 64 / 256),
        };
    }
};

test "Heights.of" {
    const gameData: GameData = .{ .arena = undefined, .blockCodes = &.{}, .itemCodes = &.{}, .worldHeight = 256 };
    try std.testing.expectEqual(Heights{ .low = 70, .ground = 110, .high = 174 }, Heights.of(gameData));
}

/// The colour of a column at height `y`. `slope` is how much higher it is than its west and
/// north neighbours together: slopes facing the north-west light are brightened, the others
/// darkened, as on a hand-shaded relief map.
fn colour(y: u16, heights: Heights, slope: i32) u32 {
    // Where y falls on the ramp, in 1/256ths of a step: low..ground covers the steps up
    // to ground level, ground..high the rest.
    const steps = ramp.len - 1;
    const clamped = std.math.clamp(y, heights.low, heights.high);
    const position: usize = if (clamped <= heights.ground)
        stretch(clamped - heights.low, heights.ground - heights.low, groundStep)
    else
        groundStep * 256 + stretch(clamped - heights.ground, heights.high - heights.ground, steps - groundStep);
    const step: usize = @min(position / 256, steps - 1);
    const fraction = position - step * 256;
    // Light in 1/256ths: each block of slope changes the brightness by 1/16, up to ±3/8.
    const light: i32 = 256 + std.math.clamp(slope * 16, -96, 96);

    var channels = mix(ramp[step], ramp[step + 1], fraction);
    for (&channels) |*channel| {
        channel.* = @intCast(std.math.clamp(@divTrunc(@as(i32, channel.*) * light, 256), 0, 255));
    }
    return rgb(channels[0], channels[1], channels[2]);
}

/// `offset` out of `span` heights, as a distance along `steps` ramp steps in 1/256ths.
fn stretch(offset: u16, span: u16, steps: usize) usize {
    if (span == 0) return steps * 256;
    return @as(usize, offset) * steps * 256 / span;
}

/// An opaque pixel.
fn rgb(r: u8, g: u8, b: u8) u32 {
    return tiles.rgba(r, g, b, 0xFF);
}

test colour {
    const heights: Heights = .{ .low = 10, .ground = 60, .high = 110 };
    // Level ground takes the ramp's colour for its height.
    try std.testing.expectEqual(rgb(0x4A, 0x30, 0x1A), colour(10, heights, 0));
    try std.testing.expectEqual(rgb(0xE4, 0xD2, 0xA0), colour(60, heights, 0));
    try std.testing.expectEqual(rgb(0xF6, 0xEE, 0xD2), colour(110, heights, 0));
    try std.testing.expectEqual(rgb(0xF6, 0xEE, 0xD2), colour(200, heights, 0));
    // A slope facing the light is brighter, one facing away darker.
    const level = colour(40, heights, 0);
    try std.testing.expect(colour(40, heights, 2) & 0xFF > level & 0xFF);
    try std.testing.expect(colour(40, heights, -2) & 0xFF < level & 0xFF);
}
