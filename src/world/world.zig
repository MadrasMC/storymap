//! What a game tells the renderers and the viewer about its world, the same for every game:
//! for a tile's block columns, what's on top of each one, what each block is on a map, and
//! what the world is called. A game's reader (`vs` for Vintage Story) fills these in from its
//! save files; the renderers and the viewer know nothing of any save format.
const std = @import("std");
const tiles = @import("tiles");

/// What a block is on Storymap's maps, which picks its colour from a theme's style
/// (docs/themes.md#map-style). Each game's reader sorts its blocks into these. The names are
/// borrowed from Vintage Story's map colour codes, but the types are Storymap's. Seas are
/// `ocean`; lakes, rivers and springs `lake`.
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

/// A colour, red, green and blue.
pub const Rgb = [3]u8;

/// A colour for each map type, and the inks for water's edges and low ground: a theme's colours
/// for Storymap's styles, or a game's own for its maps.
pub const Palette = struct {
    colours: std.EnumArray(MapType, Rgb),
    ink: Rgb,
    wateredge: Rgb,
};

/// The game a world is from, e.g. "Vintage Story", and the version that last saved the world,
/// e.g. "1.22.7".
pub const Game = struct {
    name: []const u8,
    version: []const u8,
};

/// What a map of a world shows it as: its game, its name, and where its positions are counted
/// from.
pub const Description = struct {
    game: Game,
    name: []const u8,
    /// The block the game shows as position 0, 0, so a map can show positions as the game
    /// does: x east, z south.
    origin: struct { x: i64, z: i64 },
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

    pub fn init(allocator: std.mem.Allocator) !Surface {
        const top = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(top);
        const topBlock = try allocator.alloc(i32, side * side);
        errdefer allocator.free(topBlock);
        const liquidTop = try allocator.alloc(?u16, side * side);
        errdefer allocator.free(liquidTop);
        const liquidBlock = try allocator.alloc(i32, side * side);
        return .{ .top = top, .topBlock = topBlock, .liquidTop = liquidTop, .liquidBlock = liquidBlock };
    }

    pub fn deinit(self: Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.top);
        allocator.free(self.topBlock);
        allocator.free(self.liquidTop);
        allocator.free(self.liquidBlock);
    }

    pub fn clear(self: Surface) void {
        @memset(self.top, null);
        @memset(self.topBlock, 0);
        @memset(self.liquidTop, null);
        @memset(self.liquidBlock, 0);
    }

    /// What column `i` shows from above.
    pub fn columnTop(self: Surface, i: usize) ColumnTop {
        return .of(self.top[i], self.liquidTop[i]);
    }

    /// The block column `i` shows from above: its liquid, or else its highest solid block.
    pub fn shownBlock(self: Surface, i: usize) i32 {
        return if (self.columnTop(i) == .liquid) self.liquidBlock[i] else self.topBlock[i];
    }
};

/// What a column shows from above, and at what height.
pub const ColumnTop = union(enum) {
    /// No blocks at all, as far as the save goes.
    none,
    land: u16,
    /// Liquid at or above the highest solid block. Plants growing in water share their
    /// block with it, so the water still shows.
    liquid: u16,

    pub fn of(top: ?u16, liquidTop: ?u16) ColumnTop {
        const liquid = liquidTop orelse return if (top) |y| .{ .land = y } else .none;
        const land = top orelse return .{ .liquid = liquid };
        return if (liquid >= land) .{ .liquid = liquid } else .{ .land = land };
    }

    pub fn height(self: ColumnTop) ?u16 {
        return switch (self) {
            .none => null,
            .land, .liquid => |y| y,
        };
    }
};

test ColumnTop {
    try std.testing.expectEqual(ColumnTop.none, ColumnTop.of(null, null));
    try std.testing.expectEqual(ColumnTop{ .land = 90 }, ColumnTop.of(90, null));
    try std.testing.expectEqual(ColumnTop{ .liquid = 109 }, ColumnTop.of(90, 109));
    try std.testing.expectEqual(ColumnTop{ .liquid = 109 }, ColumnTop.of(109, 109)); // seaweed
    try std.testing.expectEqual(ColumnTop{ .land = 120 }, ColumnTop.of(120, 12)); // water in a cave
    try std.testing.expectEqual(ColumnTop{ .liquid = 109 }, ColumnTop.of(null, 109));
}
