//! What a game tells the renderers about its world, the same for every game: for an area of
//! block columns, what's on top of each one. A game's reader (src/vs/ for Vintage Story) fills
//! these in from its saves; the renderers draw from them and know nothing of any save format.
const std = @import("std");
const tiles = @import("tiles.zig");

/// What a block is on a map, which picks its colour from a theme's style
/// (docs/themes.md#map-colours). The names are Vintage Story's map colour codes; a game's
/// reader says which each of its blocks is. Seas are `ocean`; lakes, rivers and springs `lake`.
pub const MapType = enum {
    land,
    desert,
    forest,
    plant,
    settlement,
    road,
    devastation,
    glacier,
    lake,
    ocean,
    lava,

    /// Whether blocks of this type are liquids, shown by depth rather than by height.
    pub fn isLiquid(self: MapType) bool {
        return self == .lake or self == .ocean or self == .lava;
    }
};

/// What the map needs to know about a block.
pub const Look = struct {
    mapType: MapType,
    /// Drawn as water by a shaded map: unshaded, with an edge where it meets anything else. In
    /// Vintage Story, water and ice other than glacier ice.
    lake: bool = false,
    /// A thin layer a shaded map looks under, showing the block beneath it instead, as the
    /// game's map does with snow.
    cover: bool = false,
};

/// The heights a map is coloured by: they depend only on the world, so every part of a map,
/// and every world, is coloured the same way.
pub const Heights = struct {
    /// How many blocks high the world is.
    world: u16,
    /// The height of the sea's surface.
    sea: u16,
};

/// A tile's block columns and a one-block ring around them, so hill shading and coastlines
/// match across tile edges. Column (x, z) of the area is at index `z * side + x`; the tile's
/// own columns start at (1, 1).
pub const Area = struct {
    pub const side = tiles.size + 2;

    /// Height of the highest solid block in each column, or null if there is none. Under
    /// liquid, the ground the liquid stands on.
    top: []?u16,
    /// The game's ID of that block, or 0 where it isn't known, such as under liquid.
    topBlock: []i32,
    /// The same for the highest liquid block. Plants growing in water, such as seaweed and
    /// reeds, share their place with it, so from above the liquid shows. Liquid under a solid
    /// block, such as a lake under a tree's leaves, is here too, though the solid block shows.
    liquidTop: []?u16,
    liquidBlock: []i32,
    /// The block right under the highest solid one, liquid or solid, or 0 where it isn't
    /// known: what a shaded map shows under a cover such as snow (`Look.cover`).
    underBlock: []i32,

    pub fn init(allocator: std.mem.Allocator) !Area {
        const top = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(top);
        const topBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(topBlock);
        const liquidTop = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(liquidTop);
        const liquidBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(liquidBlock);
        const underBlock = try allocator.alloc(i32, side * side);
        return .{ .top = top, .topBlock = topBlock, .liquidTop = liquidTop, .liquidBlock = liquidBlock, .underBlock = underBlock };
    }

    pub fn deinit(self: Area, allocator: std.mem.Allocator) void {
        allocator.free(self.top);
        allocator.free(self.topBlock);
        allocator.free(self.liquidTop);
        allocator.free(self.liquidBlock);
        allocator.free(self.underBlock);
    }

    pub fn clear(self: Area) void {
        @memset(self.top, null);
        @memset(self.topBlock, 0);
        @memset(self.liquidTop, null);
        @memset(self.liquidBlock, 0);
        @memset(self.underBlock, 0);
    }
};
