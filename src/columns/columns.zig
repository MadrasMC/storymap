//! What a game tells the renderers about its world, the same for every game: for a tile's
//! block columns, what's on top of each one. A game's reader (src/vs/ for Vintage Story) fills
//! these in from its saves; the renderers draw from them and know nothing of any save format.
const std = @import("std");
const tiles = @import("tiles");

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
    /// The average colour of its texture, for a map coloured by what blocks look like, or
    /// null if the game's reader doesn't know it.
    colour: ?Rgb = null,
    /// Colours from across its texture, for grain: each column shows one of them, mixed in.
    grain: []const Rgb = &.{},
};

/// A colour, red, green and blue.
pub const Rgb = [3]u8;

/// How a game colours its own map, which a theme's style starts from: a colour for each map
/// type, and the ink for water's edges and low ground.
pub const Palette = struct {
    colours: std.EnumArray(MapType, Rgb),
    ink: Rgb,
    wateredge: Rgb,
};

/// The heights a map is coloured by: they depend only on the world, so every part of a map,
/// and every world, is coloured the same way.
pub const Heights = struct {
    /// How many blocks high the world is.
    world: u16,
    /// The height of the sea's surface.
    sea: u16,
};

/// The surface of a tile: what's on top of each of its block columns, and of a one-block ring
/// around them, so hill shading and coastlines match across tile edges. Column (x, z) is at
/// index `z * side + x`; the tile's own columns start at (1, 1).
pub const Surface = struct {
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
    /// What the game tints the highest solid block's colour and the highest liquid's by where
    /// they are, such as grass and leaves by climate and season, or white: multiplied into
    /// their colour. Only for the tile's own columns, and empty unless asked for (`init`).
    topTint: []Rgb = &.{},
    liquidTint: []Rgb = &.{},

    pub const Options = struct {
        /// Whether the game's reader fills in `topTint` and `liquidTint`.
        tints: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Surface {
        const top = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(top);
        const topBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(topBlock);
        const liquidTop = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(liquidTop);
        const liquidBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(liquidBlock);
        const underBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(underBlock);
        const topTint = try allocator.alloc(Rgb, if (options.tints) side * side else 0);
        errdefer allocator.free(topTint);
        const liquidTint = try allocator.alloc(Rgb, if (options.tints) side * side else 0);
        return .{ .top = top, .topBlock = topBlock, .liquidTop = liquidTop, .liquidBlock = liquidBlock, .underBlock = underBlock, .topTint = topTint, .liquidTint = liquidTint };
    }

    pub fn deinit(self: Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.top);
        allocator.free(self.topBlock);
        allocator.free(self.liquidTop);
        allocator.free(self.liquidBlock);
        allocator.free(self.underBlock);
        allocator.free(self.topTint);
        allocator.free(self.liquidTint);
    }

    pub fn clear(self: Surface) void {
        @memset(self.top, null);
        @memset(self.topBlock, 0);
        @memset(self.liquidTop, null);
        @memset(self.liquidBlock, 0);
        @memset(self.underBlock, 0);
        @memset(self.topTint, white);
        @memset(self.liquidTint, white);
    }
};

/// No tint.
pub const white: Rgb = .{ 255, 255, 255 };
