//! A Minecraft world's overworld, opened for reading: a `Source` for the top-down view
//! (`topdown.zig`). A tile is exactly a region file. Heights are from the world's bottom, as
//! `world` has them, so a world from −64 up has its sea at 127.
const World = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const tiles = @import("tiles");
const world = @import("world");
const Region = @import("Region.zig");
const Chunk = @import("Chunk.zig");

comptime {
    std.debug.assert(tiles.size == Region.side * Chunk.side);
}

/// The most sections high a world can be: 4,064 blocks, the game's limit.
const maxSections = 254;
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
/// The height of the world's bottom, in blocks.
bottom: i32,
/// How many blocks high the world is.
height: u16,
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
    const tileList = try list.toOwnedSlice(allocator);
    errdefer allocator.free(tileList);
    const names = try allocator.create(Names);
    names.* = .{ .arena = .init(allocator) };
    return .{ .io = io, .regions = regions, .tileList = tileList, .bottom = bottom, .height = height, .names = names };
}

pub fn close(self: *World, allocator: std.mem.Allocator) void {
    self.names.ids.deinit(allocator);
    self.names.arena.deinit();
    allocator.destroy(self.names);
    allocator.free(self.tileList);
    self.regions.close(self.io);
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
    sections: *SectionBlocks,
    /// Chunks holding a surface block, in each tile and the ring around it.
    chunksRead: usize = 0,

    /// Each of a chunk's sections, ready to look blocks up in.
    const SectionBlocks = struct {
        /// By section from the bottom of the world.
        present: [maxSections]bool,
        indexes: [maxSections][Chunk.blocks]u16,
        /// By section, each palette entry's ID, and whether it's waterlogged.
        ids: [maxSections][maxPalette]i32,
        logged: [maxSections][maxPalette]bool,
    };

    /// The most palette entries kept for a section; blocks past them are passed over. The largest
    /// palette seen is 47.
    const maxPalette = 512;

    pub fn init(source: *const World, allocator: std.mem.Allocator, _: ?MapStyle) !Reader {
        const buffer = try allocator.alloc(u8, maxChunkBytes);
        errdefer allocator.free(buffer);
        return .{ .world = source, .buffer = buffer, .sections = try allocator.create(SectionBlocks) };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        for (&self.regions) |*slot| if (slot.*) |*mapped| mapped.close(self.world.io);
        allocator.destroy(self.sections);
        allocator.free(self.buffer);
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
        const side: i64 = Region.side;
        const tile: tiles.Tile = .{ .x = @intCast(@divFloor(cx, side)), .y = @intCast(@divFloor(cz, side)) };
        const mapped = try self.regionAt(tile) orelse return;
        const text = try mapped.region().chunk(self.buffer, @intCast(@mod(cx, side)), @intCast(@mod(cz, side))) orelse return;
        const chunk = try Chunk.parse(text);
        if (!chunk.full or chunk.surface == null) return;
        self.chunksRead += 1;
        try self.loadSections(chunk);

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
        var y: usize = top;
        while (y > 0) {
            y -= 1;
            const section = y / Chunk.side;
            if (section >= maxSections or !self.sections.present[section]) continue;
            const index = self.sections.indexes[section][((y % Chunk.side) * Chunk.side + z) * Chunk.side + x];
            if (index >= maxPalette) continue;
            const id = self.sections.ids[section][index];
            if (id < 0) continue;
            if (names.liquids[@intCast(id)]) {
                if (surface.liquidTop[i] == null) {
                    surface.liquidTop[i] = @intCast(y);
                    surface.liquidBlock[i] = id;
                }
                continue;
            }
            if (self.sections.logged[section][index] and surface.liquidTop[i] == null) {
                surface.liquidTop[i] = @intCast(y);
                surface.liquidBlock[i] = self.world.idOf("minecraft:water") catch 0;
            }
            surface.top[i] = @intCast(y);
            surface.topBlock[i] = id;
            return;
        }
    }

    /// Unpacks the chunk's sections, with an ID for each palette entry; air is −1.
    fn loadSections(self: *Reader, chunk: Chunk) !void {
        @memset(&self.sections.present, false);
        var sections = chunk.sections.iterator();
        while (try sections.next()) |value| {
            const section = try Chunk.Section.of(value.compound) orelse continue;
            const at = @as(i32, section.y) - chunk.bottom;
            if (at < 0 or at >= maxSections) continue;
            const slot: usize = @intCast(at);
            try section.unpackBlocks(&self.sections.indexes[slot]);
            self.sections.present[slot] = true;
            var palette = section.blockPalette.iterator();
            var entry: usize = 0;
            while (try palette.next()) |item| : (entry += 1) {
                if (entry >= maxPalette) break;
                const block: Chunk.Block = try .of(item);
                self.sections.ids[slot][entry] = if (isAir(shortName(block.id))) -1 else try self.world.idOf(block.id);
                self.sections.logged[slot][entry] = try isWaterlogged(block);
            }
        }
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
