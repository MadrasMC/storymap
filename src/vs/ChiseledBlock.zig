//! A chiseled block's voxels: the `materials` and `cuboids` of a `MicroBlock` or `Chisel` block
//! entity (docs/save-format/README.md#chiseled-blocks-microblock-chisel).
const ChiseledBlock = @This();

const std = @import("std");
const TreeAttribute = @import("TreeAttribute.zig");

/// Block IDs.
materials: []const i32,
/// Packed boxes (`Cuboid.unpack`).
cuboids: []const i32,

/// Null if the attributes aren't a chiseled block's. Old saves may name the materials by code
/// instead; those aren't read.
pub fn of(attributes: TreeAttribute) ?ChiseledBlock {
    return .{
        .materials = attributes.getIntArray("materials") orelse return null,
        .cuboids = attributes.getIntArray("cuboids") orelse return null,
    };
}

/// A box of voxels, from (x1, y1, z1) up to but not including (x2, y2, z2), each 0 to 16.
pub const Cuboid = struct {
    x1: u5,
    y1: u5,
    z1: u5,
    x2: u5,
    y2: u5,
    z2: u5,
    /// An index into `materials`.
    material: u8,

    pub fn unpack(word: i32) Cuboid {
        const bits: u32 = @bitCast(word);
        return .{
            .x1 = @intCast(bits & 15),
            .y1 = @intCast(bits >> 4 & 15),
            .z1 = @intCast(bits >> 8 & 15),
            .x2 = @intCast((bits >> 12 & 15) + 1),
            .y2 = @intCast((bits >> 16 & 15) + 1),
            .z2 = @intCast((bits >> 20 & 15) + 1),
            .material = @intCast(bits >> 24),
        };
    }

    pub fn volume(self: Cuboid) u32 {
        return @as(u32, self.x2 - self.x1) * (self.y2 - self.y1) * (self.z2 - self.z1);
    }
};

/// Materials by their index in `materials`.
pub const MaterialSet = std.StaticBitSet(256);

/// Whether a cuboid's material is one of `visible` and not air.
fn shows(self: ChiseledBlock, cuboid: Cuboid, visible: MaterialSet) bool {
    return cuboid.material < self.materials.len and visible.isSet(cuboid.material) and self.materials[cuboid.material] > 0;
}

/// Of the `visible` materials, the one that covers most of the block seen from above: the top
/// voxel of each of its 16 × 16 columns of voxels, by material. On a tie, the material listed
/// first. Null if none shows.
pub fn topMaterial(self: ChiseledBlock, visible: MaterialSet) ?i32 {
    // Each voxel column's top as its height + 1, 0 for none, and its material index.
    var tops: [16 * 16]struct { height: u5 = 0, material: u8 = 0 } = @splat(.{});
    for (self.cuboids) |word| {
        const cuboid: Cuboid = .unpack(word);
        if (!self.shows(cuboid, visible)) continue;
        for (cuboid.z1..cuboid.z2) |z| for (cuboid.x1..cuboid.x2) |x| {
            const top = &tops[z * 16 + x];
            if (cuboid.y2 > top.height) top.* = .{ .height = cuboid.y2, .material = cuboid.material };
        };
    }
    var counts: [256]u16 = @splat(0);
    for (tops) |top| {
        if (top.height > 0) counts[top.material] += 1;
    }
    const most = std.mem.indexOfMax(u16, &counts);
    return if (counts[most] == 0) null else self.materials[most];
}

/// Of the `visible` materials, the one filling the most voxels, as the game's
/// `BlockEntityMicroBlock.getMajorityMaterial` picks it: on a tie, the one whose first cuboid
/// comes first. Null if none shows.
pub fn majorityMaterial(self: ChiseledBlock, visible: MaterialSet) ?i32 {
    var volumes: [256]u32 = @splat(0);
    var order: [256]u8 = undefined;
    var count: usize = 0;
    for (self.cuboids) |word| {
        const cuboid: Cuboid = .unpack(word);
        if (!self.shows(cuboid, visible)) continue;
        if (volumes[cuboid.material] == 0) {
            order[count] = cuboid.material;
            count += 1;
        }
        volumes[cuboid.material] += cuboid.volume();
    }
    if (count == 0) return null;
    var best = order[0];
    for (order[1..count]) |material| {
        if (volumes[material] > volumes[best]) best = material;
    }
    return self.materials[best];
}

/// Packs a cuboid as the save does, for the tests.
fn pack(x1: u32, y1: u32, z1: u32, x2: u32, y2: u32, z2: u32, material: u32) i32 {
    return @bitCast(x1 | y1 << 4 | z1 << 8 | (x2 - 1) << 12 | (y2 - 1) << 16 | (z2 - 1) << 20 | material << 24);
}

const all: MaterialSet = .full;

test "Cuboid.unpack" {
    // From the save format's example: x 0–8, y 0–8, z 0–16, material 0.
    const cuboid: Cuboid = .unpack(0x00F77000);
    try std.testing.expectEqual(Cuboid{ .x1 = 0, .y1 = 0, .z1 = 0, .x2 = 8, .y2 = 8, .z2 = 16, .material = 0 }, cuboid);
    try std.testing.expectEqual(8 * 8 * 16, cuboid.volume());
    // Material index 200 makes the packed number negative.
    try std.testing.expectEqual(200, Cuboid.unpack(pack(0, 0, 0, 16, 16, 16, 200)).material);
}

test topMaterial {
    // A plank floor, one voxel thick, beside a stone wall along one edge: from above, three
    // quarters of the voxel columns are planks, though most voxels are stone.
    const block: ChiseledBlock = .{
        .materials = &.{ 10, 20 },
        .cuboids = &.{ pack(0, 0, 0, 16, 1, 16, 0), pack(12, 1, 0, 16, 16, 16, 1) },
    };
    try std.testing.expectEqual(10, block.topMaterial(all));
    try std.testing.expectEqual(20, block.majorityMaterial(all));
}

test "invisible materials are looked through" {
    // An invisible collider over a plank floor.
    const block: ChiseledBlock = .{
        .materials = &.{ 10, 40 },
        .cuboids = &.{ pack(0, 0, 0, 16, 1, 16, 0), pack(0, 1, 0, 16, 16, 16, 1) },
    };
    var visible: MaterialSet = .full;
    visible.unset(1);
    try std.testing.expectEqual(40, block.topMaterial(all));
    try std.testing.expectEqual(10, block.topMaterial(visible));
    try std.testing.expectEqual(10, block.majorityMaterial(visible));
}

test "air and missing materials show nothing" {
    const block: ChiseledBlock = .{
        .materials = &.{ 0, 30 },
        .cuboids = &.{ pack(0, 0, 0, 16, 16, 16, 0), pack(0, 0, 0, 1, 1, 1, 5) },
    };
    try std.testing.expectEqual(null, block.topMaterial(all));
    try std.testing.expectEqual(null, block.majorityMaterial(all));
    const empty: ChiseledBlock = .{ .materials = &.{30}, .cuboids = &.{} };
    try std.testing.expectEqual(null, empty.topMaterial(all));
}

test "on a tie, majorityMaterial keeps the first cuboid's" {
    const block: ChiseledBlock = .{
        .materials = &.{ 10, 20 },
        .cuboids = &.{ pack(8, 0, 0, 16, 16, 16, 1), pack(0, 0, 0, 8, 16, 16, 0) },
    };
    try std.testing.expectEqual(20, block.majorityMaterial(all));
    try std.testing.expectEqual(10, block.topMaterial(all));
}
