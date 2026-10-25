//! What a game's reader (`vs` for Vintage Story) tells the renderers and the viewer about a
//! world, the same for every game: what's on top of each block column, what each block is on a
//! map, and the world's name and heights.
const std = @import("std");
const tiles = @import("tiles");

/// What a block is on a map, which picks its colour (docs/themes.md#map-style). Storymap's types,
/// which each game's reader sorts its blocks into; named after Vintage Story's map colour codes.
/// Seas are `ocean`; lakes, rivers and springs `lake`.
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

    /// Liquids are shown by depth rather than by height.
    pub fn isLiquid(self: MapType) bool {
        return self == .lake or self == .ocean or self == .lava;
    }
};

pub const Rgb = [3]u8;

/// A colour for each map type, and the inks for low ground and water's edges.
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

pub const Description = struct {
    game: Game,
    name: []const u8,
    /// The block the game shows as position 0, 0, so a map can show positions as the game
    /// does: x east, z south.
    origin: struct { x: i64, z: i64 },
    /// The height of the sea's surface. A view that shows heights places positions at it, as
    /// one point on its screen covers a whole line of blocks.
    seaLevel: u16,
};

/// The heights a map is coloured by.
pub const Heights = struct {
    /// How many blocks high the world is.
    world: u16,
    /// The height of the sea's surface.
    sea: u16,
};

/// A cube of the world's blocks, 32 on each side, as the game's block IDs; 0 is air. Chunk
/// (x, y, z) holds blocks x · 32 to x · 32 + 31, and likewise for y and z; within it, block
/// (x, y, z) is at index `(y * side + z) * side + x`. Every game's reader fills them, whatever
/// the game itself stores its blocks in.
pub const Chunk = struct {
    pub const side = 32;
    pub const volume = side * side * side;

    solid: [volume]i32,
    /// Liquids, in their own layer: a block and a liquid can share a place, as plants growing
    /// in water do.
    liquid: [volume]i32,
};

/// Pixels row by row, red, green, blue and alpha.
pub const Image = struct {
    width: u16,
    height: u16,
    pixels: []const [4]u8,
};

/// The top, south and east faces of a block drawn as a cube, each as the game's textures show
/// them, looking at the face from outside with the sky up (the top with north up).
pub const CubeFaces = struct {
    up: Face,
    south: Face,
    east: Face,

    /// What's never tinted, and what the block's tint colours, drawn over it: each a texture's
    /// variants, of which a block shows the one its position picks (the game reader's
    /// `variant`), and none for a face without the layer.
    pub const Face = struct {
        plain: []const *const Image = &.{},
        tinted: []const *const Image = &.{},
    };
};

/// A block drawn in its shape: boxes placed and turned in it, each face it shows in a texture.
/// A block is from 0 to 1 on each axis, x east, y up and z south. Blocks placed the same share
/// their boxes, and each has its own textures.
pub const Shape = struct {
    boxes: []const Box,
    /// What the boxes' faces show, by number (`Face.texture`): none on a face whose texture
    /// isn't there.
    textures: []const CubeFaces.Face,

    pub const Box = struct {
        /// Where the box's corners go: a point from (0, 0, 0) to `size`, in blocks, times this
        /// matrix is the point in the block. Three rows of four, the last column the shift.
        transform: [3][4]f32,
        size: [3]f32,
        /// Whether its faces are lit by the way they face; unlit, they're as bright as a top.
        shade: bool,
        /// By `Side`: null for a face it doesn't show.
        faces: [6]?Face,
    };

    /// A box's faces, each facing away from its middle, before the box is turned.
    pub const Side = enum {
        north,
        east,
        south,
        west,
        up,
        down,

        /// The corners of the face on this side of a box from (0, 0, 0) to (1, 1, 1), in the
        /// order `Face.uv` gives their texture coordinates: going round the face.
        pub fn corners(self: Side) [4][3]f32 {
            return switch (self) {
                .north => .{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 0 } },
                .east => .{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } },
                .south => .{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } },
                .west => .{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 } },
                .up => .{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 } },
                .down => .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } },
            };
        }
    };

    pub const Face = struct {
        /// In `Shape.textures`.
        texture: u16,
        /// Where each of the face's corners (`Side.corners`) is on the texture, from 0 to 1
        /// across and down; between them, the texture is stretched evenly.
        uv: [4][2]f32,
    };
};

/// The chunks at x and z from the bottom of the world to the top.
pub const ChunkColumn = struct {
    x: i32,
    z: i32,
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
    /// The same for the highest liquid block. Plants growing in water, such as seaweed, share
    /// its block, so from above the liquid shows. Liquid under a solid block, such as a lake
    /// under leaves, is here too, though the solid block shows.
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
    /// Liquid at or above the highest solid block.
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
