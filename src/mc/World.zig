//! A Minecraft world's overworld, opened for reading: a `Source` for the top-down and isometric
//! views (`topdown.zig`, `isometric.zig`). A tile is exactly a region file. Heights are from the world's bottom, as
//! `world` has them, so a world from −64 up has its sea at 127.
const World = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const tiles = @import("tiles");
const world = @import("world");
const nbt = @import("nbt");
const Region = @import("Region.zig");
const Chunk = @import("Chunk.zig");

comptime {
    std.debug.assert(tiles.size == Region.side * Chunk.side);
    std.debug.assert(world.Chunk.side == cubeColumns * Chunk.side);
}

/// The game's chunk columns along a side of a `world.Chunk`, and the sections up one.
const cubeColumns = 2;
/// The most block names a world can have before the rest count as one.
const maxBlocks = 4096;
/// The sea's height, in blocks from 0.
const seaLevel = 63;
/// The largest chunk read, decompressed.
const maxChunkBytes = 16 << 20;

/// The folders a world keeps its overworld's regions in: from 26.1, and before it.
const regionFolders = [_][]const u8{ "dimensions/minecraft/overworld/region", "region" };

io: Io,
regions: Dir,
/// The tiles that may have something on them, one for each region file.
tileList: []tiles.Tile,
/// The `world.Chunk` columns that may have blocks. A region's table doesn't say which chunks are
/// finished, so some of them have none.
chunkColumns: []world.ChunkColumn,
/// The chunks in the regions, finished or not.
chunkCount: usize,
/// The height of the world's bottom, in blocks.
bottom: i32,
/// How many blocks high the world is.
height: u16,
/// The world's name, and the version of the game that last saved it, from `level.dat`; empty
/// without one.
name: []const u8,
version: []const u8,
names: *Names,

/// The block names met so far, each with an ID, shared by every thread's `Reader`.
const Names = struct {
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    ids: std.StringHashMapUnmanaged(i32) = .empty,
    /// By ID, from 1. 0 stands for any name past `maxBlocks`.
    mapTypes: [maxBlocks]world.MapType = @splat(.land),
    liquids: [maxBlocks]bool = @splat(false),
    list: [maxBlocks][]const u8 = @splat(""),
};

pub const MapStyle = enum { default };

/// The game's own map styles aren't read yet.
pub const MapPainter = struct {
    pub fn init(_: *const World, _: std.mem.Allocator, _: MapStyle) !MapPainter {
        return error.UnknownStyle;
    }

    pub fn deinit(_: MapPainter, _: std.mem.Allocator) void {}

    pub fn paint(_: *MapPainter, _: *const Reader, _: tiles.Tile, _: *const world.Surface, _: *tiles.Pixels) void {}
};

/// The world in folder `path`. error.NotAWorld for a folder without regions.
pub fn open(allocator: std.mem.Allocator, io: Io, path: []const u8) !World {
    var folder = try Dir.cwd().openDir(io, path, .{});
    defer folder.close(io);
    const regions = for (regionFolders) |name| {
        break folder.openDir(io, name, .{ .iterate = true }) catch continue;
    } else return error.NotAWorld;
    errdefer regions.close(io);

    var list: std.ArrayList(tiles.Tile) = .empty;
    defer list.deinit(allocator);
    var files = regions.iterate();
    while (try files.next(io)) |entry| {
        if (regionOf(entry.name)) |tile| try list.append(allocator, tile);
    }
    if (list.items.len == 0) return error.NotAWorld;

    const buffer = try allocator.alloc(u8, maxChunkBytes);
    defer allocator.free(buffer);
    const bottom, const height = try findHeights(regions, io, list.items, buffer);
    const chunkColumns, const chunkCount = try findColumns(allocator, regions, io, list.items);
    errdefer allocator.free(chunkColumns);
    const tileList = try list.toOwnedSlice(allocator);
    errdefer allocator.free(tileList);
    const names = try allocator.create(Names);
    names.* = .{ .arena = .init(allocator) };
    errdefer {
        names.arena.deinit();
        allocator.destroy(names);
    }
    const name, const version = try readLevel(names.arena.allocator(), io, folder, buffer);
    return .{
        .io = io,
        .regions = regions,
        .tileList = tileList,
        .chunkColumns = chunkColumns,
        .chunkCount = chunkCount,
        .bottom = bottom,
        .height = height,
        .name = name,
        .version = version,
        .names = names,
    };
}

/// The world's name and its game version from `level.dat`, kept in `arena`; empty where it
/// can't be read.
fn readLevel(arena: std.mem.Allocator, io: Io, folder: Dir, buffer: []u8) !struct { []const u8, []const u8 } {
    const compressed = folder.readFileAlloc(io, "level.dat", arena, .limited(64 << 20)) catch return .{ "", "" };
    var input: Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var output: Io.Writer = .fixed(buffer);
    const length = inflate.reader.streamRemaining(&output) catch return .{ "", "" };
    const root = nbt.parse(buffer[0..length]) catch return .{ "", "" };
    const data = (root.get("Data") catch null) orelse return .{ "", "" };
    if (data != .compound) return .{ "", "" };
    const name = stringIn(data.compound, "LevelName");
    const version: []const u8 = if (data.compound.get("Version") catch null) |value| (if (value == .compound) stringIn(value.compound, "Name") else "") else "";
    return .{ try arena.dupe(u8, name), try arena.dupe(u8, version) };
}

fn stringIn(compound: nbt.Compound, key: []const u8) []const u8 {
    const value = (compound.get(key) catch null) orelse return "";
    return if (value == .string) value.string else "";
}

/// The game shows positions as they are, so the origin is (0, 0).
pub fn describe(self: *const World) world.Description {
    return .{
        .game = .{ .name = "Minecraft", .version = self.version },
        .name = self.name,
        .origin = .{ .x = 0, .z = 0 },
        .seaLevel = self.heights().sea,
    };
}

pub fn countChunks(self: *const World) error{}!usize {
    return self.chunkCount;
}

pub fn close(self: *World, allocator: std.mem.Allocator) void {
    // `ids` is in the arena too.
    self.names.arena.deinit();
    allocator.destroy(self.names);
    allocator.free(self.chunkColumns);
    allocator.free(self.tileList);
    self.regions.close(self.io);
}

/// The `world.Chunk` columns holding any chunk in the regions, and the chunks, from their tables
/// alone.
fn findColumns(allocator: std.mem.Allocator, regions: Dir, io: Io, tileList: []const tiles.Tile) !struct { []world.ChunkColumn, usize } {
    var columns: std.AutoArrayHashMapUnmanaged(world.ChunkColumn, void) = .empty;
    defer columns.deinit(allocator);
    var count: usize = 0;
    for (tileList) |tile| {
        var mapped = try MappedRegion.open(regions, io, tile) orelse continue;
        defer mapped.close(io);
        for (0..Region.side) |z| for (0..Region.side) |x| {
            if (!mapped.region().holds(x, z)) continue;
            count += 1;
            try columns.put(allocator, .{
                .x = @divFloor(tile.x * Region.side + @as(i32, @intCast(x)), cubeColumns),
                .z = @divFloor(tile.y * Region.side + @as(i32, @intCast(z)), cubeColumns),
            }, {});
        };
    }
    return .{ try allocator.dupe(world.ChunkColumn, columns.keys()), count };
}

/// The region a file holds, from its name, `r.<x>.<z>.mca`; null for any other file.
fn regionOf(name: []const u8) ?tiles.Tile {
    if (!std.mem.startsWith(u8, name, "r.") or !std.mem.endsWith(u8, name, ".mca")) return null;
    var parts = std.mem.splitScalar(u8, name[2 .. name.len - 4], '.');
    const x = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
    const z = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
    return if (parts.next() == null) .{ .x = x, .y = z } else null;
}

/// The world's bottom and height, from the first full chunk found.
fn findHeights(regions: Dir, io: Io, tileList: []const tiles.Tile, buffer: []u8) !struct { i32, u16 } {
    for (tileList) |tile| {
        var mapped = try MappedRegion.open(regions, io, tile) orelse continue;
        defer mapped.close(io);
        for (0..Region.side * Region.side) |i| {
            const text = mapped.region().chunk(buffer, i % Region.side, i / Region.side) catch continue orelse continue;
            const chunk = Chunk.parse(text) catch continue;
            if (!chunk.full) continue;
            var sections = chunk.sections.iterator();
            var count: u16 = 0;
            while (try sections.next()) |value| {
                if (try Chunk.Section.of(value.compound) != null) count += 1;
            }
            return .{ chunk.bottom * Chunk.side, count * Chunk.side };
        }
    }
    return error.NotAWorld;
}

pub fn heights(self: *const World) world.Heights {
    return .{ .world = self.height, .sea = @intCast(seaLevel - self.bottom) };
}

pub fn blockCount(_: *const World) usize {
    return maxBlocks;
}

pub fn mapType(self: *const World, id: i32) world.MapType {
    return if (id >= 0 and id < maxBlocks) self.names.mapTypes[@intCast(id)] else .land;
}

pub fn isVisible(_: *const World, id: i32) bool {
    return id > 0;
}

pub fn isLow(_: *const World, _: i32) bool {
    return false;
}

pub fn isLiquid(self: *const World, id: i32) bool {
    return id >= 0 and id < maxBlocks and self.names.liquids[@intCast(id)];
}

/// What the isometric view's `game` style asks of a block, until the prepared blocks say: every
/// block a cube in its map type's colour, in one place.
pub fn colour(self: *const World, id: i32) world.Rgb {
    return switch (self.mapType(id)) {
        .land, .road, .devastation => .{ 0x7A, 0x6A, 0x4F },
        .desert => .{ 0xD8, 0xC8, 0x8A },
        .forest => .{ 0x3A, 0x5F, 0x2E },
        .plant => .{ 0x6A, 0x9A, 0x4A },
        .settlement => .{ 0x8A, 0x6A, 0x48 },
        .glacier => .{ 0xE8, 0xF0, 0xF4 },
        .lake, .ocean => .{ 0x3A, 0x5A, 0xA8 },
        .lava => .{ 0xD8, 0x5A, 0x10 },
    };
}

pub fn spritesOf(_: *const World, _: i32) ?world.BlockSprites {
    return null;
}

pub fn isTinted(_: *const World, _: i32) bool {
    return false;
}

pub fn isSeeThrough(_: *const World, _: i32) bool {
    return false;
}

pub fn variant(_: *const World, _: i32, _: i64, _: i64, _: i64, _: u32) u32 {
    return 0;
}

pub fn drawOffset(_: *const World, _: i32, _: i64, _: i64, _: i64) ?[2]f32 {
    return null;
}

pub fn isPlacedByPosition(_: *const World, _: i32) bool {
    return false;
}

/// The name of block `id`, e.g. "minecraft:stone", once a reader has met it.
pub fn blockName(self: *const World, id: i32) ?[]const u8 {
    if (id <= 0 or id >= maxBlocks) return null;
    const name = self.names.list[@intCast(id)];
    return if (name.len == 0) null else name;
}

/// The ID of the block named `name`, given one the first time it's met.
fn idOf(self: *const World, name: []const u8) !i32 {
    const names = self.names;
    names.mutex.lockUncancelable(self.io);
    defer names.mutex.unlock(self.io);
    if (names.ids.get(name)) |id| return id;
    const next: i32 = @intCast(names.ids.count() + 1);
    const id: i32 = if (next < maxBlocks) next else 0;
    const allocator = names.arena.allocator();
    const kept = try allocator.dupe(u8, name);
    try names.ids.put(allocator, kept, id);
    if (id != 0) {
        const short = shortName(kept);
        names.list[@intCast(id)] = kept;
        names.mapTypes[@intCast(id)] = mapTypeOf(short);
        names.liquids[@intCast(id)] = isLiquidName(short);
    }
    return id;
}

/// `name` without its domain, if that's the game's.
fn shortName(name: []const u8) []const u8 {
    const prefix = "minecraft:";
    return if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else name;
}

fn isLiquidName(name: []const u8) bool {
    return std.mem.eql(u8, name, "water") or std.mem.eql(u8, name, "lava");
}

fn isAir(name: []const u8) bool {
    return std.mem.eql(u8, name, "air") or std.mem.eql(u8, name, "cave_air") or std.mem.eql(u8, name, "void_air");
}

/// What a block is on a map, from its name, until the prepared blocks say.
fn mapTypeOf(name: []const u8) world.MapType {
    const has = struct {
        fn any(text: []const u8, parts: []const []const u8) bool {
            for (parts) |part| if (std.mem.indexOf(u8, text, part) != null) return true;
            return false;
        }
    }.any;
    if (std.mem.eql(u8, name, "water")) return .lake;
    if (std.mem.eql(u8, name, "lava")) return .lava;
    if (has(name, &.{ "seagrass", "kelp" })) return .lake;
    if (has(name, &.{ "ice", "snow" })) return .glacier;
    if (has(name, &.{ "leaves", "_log", "_wood", "mangrove_roots" })) return .forest;
    if (has(name, &.{ "sand", "terracotta" })) return .desert;
    if (has(name, &.{ "short_grass", "tall_grass", "fern", "bush", "flower", "tulip", "poppy", "dandelion", "orchid", "allium", "bluet", "daisy", "cornflower", "lily", "vine", "sugar_cane", "bamboo", "cactus", "mushroom", "wheat", "carrots", "potatoes", "beetroots", "melon", "pumpkin" })) return .plant;
    if (has(name, &.{"dirt_path"})) return .road;
    if (has(name, &.{ "planks", "bricks", "door", "fence", "stairs", "slab", "glass", "wool", "torch", "bed", "chest", "furnace", "crafting_table" })) return .settlement;
    return .land;
}

/// A region file, mapped.
const MappedRegion = struct {
    tile: tiles.Tile,
    file: Io.File,
    map: Io.File.MemoryMap,

    /// Null where there's no region file, or an empty one.
    fn open(regions: Dir, io: Io, tile: tiles.Tile) !?MappedRegion {
        var name: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&name, "r.{d}.{d}.mca", .{ tile.x, tile.y }) catch unreachable;
        const file = regions.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer file.close(io);
        const size = (try file.stat(io)).size;
        if (size == 0) {
            file.close(io);
            return null;
        }
        return .{ .tile = tile, .file = file, .map = try .create(io, file, .{ .len = @intCast(size), .protection = .{ .read = true }, .populate = false }) };
    }

    fn close(self: *MappedRegion, io: Io) void {
        self.map.destroy(io);
        self.file.close(io);
    }

    fn region(self: *const MappedRegion) Region {
        return .{ .bytes = self.map.memory };
    }
};

/// One thread's buffers, reused for every tile it reads.
pub const Reader = struct {
    world: *const World,
    buffer: []u8,
    /// The tile's region and those around it, as a tile's ring reads into them.
    regions: [9]?MappedRegion = @splat(null),
    /// The slot the next region opened goes into.
    nextRegion: usize = 0,
    allocator: std.mem.Allocator,
    /// The column the top-down view reads into.
    column: Column,
    /// The columns `readChunk` has read last, made the first time it's called: its lines of sight
    /// move between them, and come back for the sections above and below.
    cubes: []Cube = &.{},
    /// The slot the next cube read goes into.
    nextCube: usize = 0,
    /// The ID of water, for a block standing in it.
    water: i32,
    /// Chunks read: those holding a surface block in each tile and the ring around it, or for
    /// `readChunk`, each with blocks to draw.
    chunksRead: usize = 0,

    /// How many cubes of columns `readChunk` keeps.
    const cubeCount = 16;

    /// A chunk's sections, ready to look blocks up in, each by its place from the world's bottom.
    const Column = struct {
        present: []bool,
        indexes: [][Chunk.blocks]u16,
        /// Each palette entry's ID, or −1 for air, and whether it's waterlogged.
        ids: [][maxPalette]i32,
        logged: [][maxPalette]bool,

        fn init(allocator: std.mem.Allocator, sections: usize) !Column {
            const present = try allocator.alloc(bool, sections);
            errdefer allocator.free(present);
            const indexes = try allocator.alloc([Chunk.blocks]u16, sections);
            errdefer allocator.free(indexes);
            const ids = try allocator.alloc([maxPalette]i32, sections);
            errdefer allocator.free(ids);
            return .{ .present = present, .indexes = indexes, .ids = ids, .logged = try allocator.alloc([maxPalette]bool, sections) };
        }

        fn deinit(self: Column, allocator: std.mem.Allocator) void {
            allocator.free(self.logged);
            allocator.free(self.ids);
            allocator.free(self.indexes);
            allocator.free(self.present);
        }
    };

    /// The columns of a `world.Chunk` column, with whether each is there and finished.
    const Cube = struct {
        x: i32 = 0,
        z: i32 = 0,
        read: bool = false,
        columns: [cubeColumns * cubeColumns]Column,
        full: [cubeColumns * cubeColumns]bool = @splat(false),
    };

    /// The most palette entries kept for a section; blocks past them are passed over. The largest
    /// palette seen is 47.
    const maxPalette = 512;

    pub fn init(source: *const World, allocator: std.mem.Allocator, _: ?MapStyle) !Reader {
        const buffer = try allocator.alloc(u8, maxChunkBytes);
        errdefer allocator.free(buffer);
        return .{
            .world = source,
            .buffer = buffer,
            .allocator = allocator,
            .column = try .init(allocator, source.height / Chunk.side),
            .water = try source.idOf("minecraft:water"),
        };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        for (&self.regions) |*slot| if (slot.*) |*mapped| mapped.close(self.world.io);
        for (self.cubes) |cube| for (cube.columns) |column| column.deinit(allocator);
        allocator.free(self.cubes);
        self.column.deinit(allocator);
        allocator.free(self.buffer);
    }

    /// Fills `out` with `world.Chunk` (x, y, z), y counting up from the world's bottom. Returns
    /// false, leaving `out` as it was, where there are no blocks to draw.
    pub fn readChunk(self: *Reader, x: i32, y: i32, z: i32, out: *world.Chunk) !bool {
        const sections = self.column.present.len;
        if (y < 0 or @as(usize, @intCast(y)) * cubeColumns >= sections) return false;
        const cube = try self.cubeAt(x, z);
        const first = @as(usize, @intCast(y)) * cubeColumns;
        @memset(&out.solid, 0);
        @memset(&out.liquid, 0);
        var any = false;
        for (cube.columns, cube.full, 0..) |column, full, place| {
            if (!full) continue;
            const left = (place % cubeColumns) * Chunk.side;
            const top = (place / cubeColumns) * Chunk.side;
            for (0..cubeColumns) |level| {
                const section = first + level;
                if (section >= sections or !column.present[section]) continue;
                if (self.copySection(column, section, out, left, level * Chunk.side, top)) any = true;
            }
        }
        if (any) self.chunksRead += 1;
        return any;
    }

    /// Copies a section's blocks into `out`, from its corner (x0, y0, z0). Returns whether it
    /// had any.
    fn copySection(self: *const Reader, column: Column, section: usize, out: *world.Chunk, x0: usize, y0: usize, z0: usize) bool {
        const side = world.Chunk.side;
        const indexes = &column.indexes[section];
        const ids = &column.ids[section];
        const logged = &column.logged[section];
        const liquids = &self.world.names.liquids;
        var any = false;
        var at: usize = 0;
        for (0..Chunk.side) |y| for (0..Chunk.side) |z| for (0..Chunk.side) |x| {
            const index = indexes[at];
            at += 1;
            if (index >= maxPalette) continue;
            const id = ids[index];
            if (id < 0) continue;
            const target = ((y0 + y) * side + z0 + z) * side + x0 + x;
            any = true;
            if (liquids[@intCast(id)]) {
                out.liquid[target] = id;
                continue;
            }
            out.solid[target] = id;
            if (logged[index]) out.liquid[target] = self.water;
        };
        return any;
    }

    /// The columns of `world.Chunk` column (x, z), read if they aren't kept.
    fn cubeAt(self: *Reader, x: i32, z: i32) !*Cube {
        if (self.cubes.len == 0) try self.makeCubes();
        for (self.cubes) |*cube| {
            if (cube.read and cube.x == x and cube.z == z) return cube;
        }
        const cube = &self.cubes[self.nextCube];
        self.nextCube = (self.nextCube + 1) % self.cubes.len;
        cube.x = x;
        cube.z = z;
        cube.read = true;
        for (&cube.columns, &cube.full, 0..) |column, *full, place| {
            const cx = @as(i64, x) * cubeColumns + @as(i64, @intCast(place % cubeColumns));
            const cz = @as(i64, z) * cubeColumns + @as(i64, @intCast(place / cubeColumns));
            full.* = false;
            const chunk = try self.readGameChunk(cx, cz) orelse continue;
            try self.loadColumn(column, chunk);
            full.* = true;
        }
        return cube;
    }

    fn makeCubes(self: *Reader) !void {
        const cubes = try self.allocator.alloc(Cube, cubeCount);
        var made: usize = 0;
        errdefer {
            for (cubes[0..made]) |cube| for (cube.columns) |column| column.deinit(self.allocator);
            self.allocator.free(cubes);
        }
        const sections = self.column.present.len;
        for (cubes) |*cube| {
            cube.* = .{ .columns = undefined };
            for (&cube.columns) |*column| column.* = try .init(self.allocator, sections);
            made += 1;
        }
        self.cubes = cubes;
    }

    /// The game's chunk (cx, cz), decompressed into `buffer`; null where it's missing or unfinished.
    fn readGameChunk(self: *Reader, cx: i64, cz: i64) !?Chunk {
        const side: i64 = Region.side;
        const tile: tiles.Tile = .{ .x = @intCast(@divFloor(cx, side)), .y = @intCast(@divFloor(cz, side)) };
        const mapped = try self.regionAt(tile) orelse return null;
        const text = try mapped.region().chunk(self.buffer, @intCast(@mod(cx, side)), @intCast(@mod(cz, side))) orelse return null;
        const chunk = try Chunk.parse(text);
        return if (chunk.full) chunk else null;
    }

    /// Fills `surface` with the tile's block columns and the ring around them.
    pub fn read(self: *Reader, tile: tiles.Tile, surface: *world.Surface) !void {
        surface.clear();
        const chunks: i32 = Region.side;
        const firstX = @as(i64, tile.x) * chunks - 1;
        const firstZ = @as(i64, tile.y) * chunks - 1;
        for (0..Region.side + 2) |j| for (0..Region.side + 2) |i| {
            const cx = firstX + @as(i64, @intCast(i));
            const cz = firstZ + @as(i64, @intCast(j));
            try self.readColumns(surface.*, cx, cz, firstX * Chunk.side + Chunk.side - 1, firstZ * Chunk.side + Chunk.side - 1);
        };
    }

    /// The mapped region of `tile`, opened if it isn't yet; null where there's none.
    fn regionAt(self: *Reader, tile: tiles.Tile) !?*MappedRegion {
        for (&self.regions) |*slot| if (slot.*) |*mapped| {
            if (mapped.tile.x == tile.x and mapped.tile.y == tile.y) return mapped;
        };
        const mapped = try MappedRegion.open(self.world.regions, self.world.io, tile) orelse return null;
        const slot = &self.regions[self.nextRegion];
        if (slot.*) |*old| old.close(self.world.io);
        slot.* = mapped;
        self.nextRegion = (self.nextRegion + 1) % self.regions.len;
        return &slot.*.?;
    }

    /// Records chunk (cx, cz) in `surface`, whose north-west corner is block (x0, z0).
    fn readColumns(self: *Reader, surface: world.Surface, cx: i64, cz: i64, x0: i64, z0: i64) !void {
        const chunk = try self.readGameChunk(cx, cz) orelse return;
        if (chunk.surface == null) return;
        self.chunksRead += 1;
        try self.loadColumn(self.column, chunk);

        var tops: [Chunk.side * Chunk.side]u16 = undefined;
        try chunk.unpackSurface(&tops, self.world.height);
        for (0..Chunk.side) |z| for (0..Chunk.side) |x| {
            const ax = cx * Chunk.side + @as(i64, @intCast(x)) - x0;
            const az = cz * Chunk.side + @as(i64, @intCast(z)) - z0;
            if (ax < 0 or az < 0 or ax >= world.Surface.side or az >= world.Surface.side) continue;
            const i: usize = @intCast(az * world.Surface.side + ax);
            self.recordColumn(surface, i, x, z, tops[z * Chunk.side + x]);
        };
    }

    /// Finds the column's highest block, going down past any liquid for the ground under it.
    fn recordColumn(self: *const Reader, surface: world.Surface, i: usize, x: usize, z: usize, top: u16) void {
        const names = self.world.names;
        const column = self.column;
        var y: usize = top;
        while (y > 0) {
            y -= 1;
            const section = y / Chunk.side;
            if (section >= column.present.len or !column.present[section]) continue;
            const index = column.indexes[section][((y % Chunk.side) * Chunk.side + z) * Chunk.side + x];
            if (index >= maxPalette) continue;
            const id = column.ids[section][index];
            if (id < 0) continue;
            if (names.liquids[@intCast(id)]) {
                if (surface.liquidTop[i] == null) {
                    surface.liquidTop[i] = @intCast(y);
                    surface.liquidBlock[i] = id;
                }
                continue;
            }
            if (column.logged[section][index] and surface.liquidTop[i] == null) {
                surface.liquidTop[i] = @intCast(y);
                surface.liquidBlock[i] = self.water;
            }
            surface.top[i] = @intCast(y);
            surface.topBlock[i] = id;
            return;
        }
    }

    /// Unpacks the chunk's sections into `column`.
    fn loadColumn(self: *const Reader, column: Column, chunk: Chunk) !void {
        @memset(column.present, false);
        var sections = chunk.sections.iterator();
        while (try sections.next()) |value| {
            const section = try Chunk.Section.of(value.compound) orelse continue;
            const at = @as(i32, section.y) - chunk.bottom;
            if (at < 0 or at >= column.present.len) continue;
            const slot: usize = @intCast(at);
            try section.unpackBlocks(&column.indexes[slot]);
            column.present[slot] = true;
            var palette = section.blockPalette.iterator();
            var entry: usize = 0;
            while (try palette.next()) |item| : (entry += 1) {
                if (entry >= maxPalette) break;
                const block: Chunk.Block = try .of(item);
                column.ids[slot][entry] = if (isAir(shortName(block.id))) -1 else try self.world.idOf(block.id);
                column.logged[slot][entry] = try isWaterlogged(block);
            }
        }
    }

    /// The colour multiplied into a block's: none yet, as biomes aren't read.
    pub fn tint(_: *Reader, _: i32, _: i64, _: i64, _: i64) !world.Rgb {
        return @splat(255);
    }

    fn isWaterlogged(block: Chunk.Block) !bool {
        const properties = block.properties orelse return false;
        const value = try properties.get("waterlogged") orelse return false;
        return value == .string and std.mem.eql(u8, value.string, "true");
    }
};

test regionOf {
    try std.testing.expectEqual(tiles.Tile{ .x = -1, .y = 2 }, regionOf("r.-1.2.mca").?);
    try std.testing.expectEqual(null, regionOf("r.0.mca"));
    try std.testing.expectEqual(null, regionOf("r.0.0.0.mca"));
    try std.testing.expectEqual(null, regionOf("level.dat"));
}

test mapTypeOf {
    try std.testing.expectEqual(world.MapType.lake, mapTypeOf("water"));
    try std.testing.expectEqual(world.MapType.forest, mapTypeOf("oak_leaves"));
    try std.testing.expectEqual(world.MapType.desert, mapTypeOf("red_sandstone"));
    try std.testing.expectEqual(world.MapType.land, mapTypeOf("stone"));
}
