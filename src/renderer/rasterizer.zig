//! Draws textured triangles into pixels with a depth buffer, nearer covering farther. A
//! triangle's corners are given in pixels, each with its depth and texture coordinates, which
//! are spread evenly between them: exact for a view without perspective, as the isometric
//! view is.
const std = @import("std");
const world = @import("world");

pub const Corner = struct {
    x: f32,
    y: f32,
    /// Larger is nearer.
    depth: f32,
    /// On the texture, from 0 to 1 across and down.
    u: f32,
    v: f32,
};

/// Where triangles are drawn: each pixel's colour, its depth, and the tag of what drew it, row by
/// row.
pub const Target = struct {
    width: usize,
    height: usize,
    colours: [][4]u8,
    depths: []f32,
    /// 0 where nothing is drawn.
    tags: []u8,
    /// Whether how opaque a texture is counts: what covers a pixel is layered with what's there,
    /// as glass needs. Otherwise a texel is drawn or left out, by whether it's at least half
    /// opaque.
    keepsOpacity: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Target {
        const colours = try allocator.alloc([4]u8, width * height);
        errdefer allocator.free(colours);
        const depths = try allocator.alloc(f32, width * height);
        errdefer allocator.free(depths);
        const tags = try allocator.alloc(u8, width * height);
        var target: Target = .{ .width = width, .height = height, .colours = colours, .depths = depths, .tags = tags };
        target.clear();
        return target;
    }

    pub fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.tags);
        allocator.free(self.depths);
        allocator.free(self.colours);
    }

    pub fn clear(self: *Target) void {
        @memset(self.colours, @splat(0));
        @memset(self.depths, -std.math.inf(f32));
        @memset(self.tags, 0);
    }
};

/// Draws the triangle in `texture`, lit by `light` 256ths, on each pixel whose middle it covers
/// where its texel there is at least half opaque and it's nearer than what the pixel shows, or
/// with `Target.keepsOpacity`, layered with what's there.
pub fn triangle(target: *Target, corners: [3]Corner, texture: *const world.Image, light: u16, tag: u8) void {
    const a = corners[0];
    const b = corners[1];
    const c = corners[2];
    const area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (area == 0) return;
    const width: f32 = @floatFromInt(target.width);
    const height: f32 = @floatFromInt(target.height);
    const left: usize = @intFromFloat(std.math.clamp(@floor(@min(a.x, b.x, c.x)), 0, width));
    const right: usize = @intFromFloat(std.math.clamp(@ceil(@max(a.x, b.x, c.x)), 0, width));
    const top: usize = @intFromFloat(std.math.clamp(@floor(@min(a.y, b.y, c.y)), 0, height));
    const bottom: usize = @intFromFloat(std.math.clamp(@ceil(@max(a.y, b.y, c.y)), 0, height));
    for (top..bottom) |row| for (left..right) |column| {
        const x = @as(f32, @floatFromInt(column)) + 0.5;
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        // How much of each corner the point takes, from 0 to 1, all of them inside.
        const wa = ((b.x - x) * (c.y - y) - (b.y - y) * (c.x - x)) / area;
        const wb = ((c.x - x) * (a.y - y) - (c.y - y) * (a.x - x)) / area;
        const wc = 1 - wa - wb;
        if (wa < 0 or wb < 0 or wc < 0) continue;
        const p = row * target.width + column;
        const depth = wa * a.depth + wb * b.depth + wc * c.depth;
        if (!target.keepsOpacity and depth <= target.depths[p]) continue;
        const texel = texelAt(texture, wa * a.u + wb * b.u + wc * c.u, wa * a.v + wb * b.v + wc * c.v);
        if (texel[3] < (if (target.keepsOpacity) @as(u8, 1) else 128)) continue;
        var colour: [4]u8 = .{ 0, 0, 0, if (target.keepsOpacity) texel[3] else 255 };
        for (0..3) |i| colour[i] = @intCast(@min(255, @as(u32, texel[i]) * light / 256));
        if (target.keepsOpacity and target.tags[p] != 0) {
            const nearer = depth > target.depths[p];
            colour = if (nearer) over(colour, target.colours[p]) else over(target.colours[p], colour);
            if (!nearer) {
                target.colours[p] = colour;
                continue;
            }
        }
        target.depths[p] = depth;
        target.tags[p] = tag;
        target.colours[p] = colour;
    };
}

/// `front` over `back`, each as opaque as its alpha says.
fn over(front: [4]u8, back: [4]u8) [4]u8 {
    const frontWeight = @as(u32, front[3]) * 255;
    const backWeight = @as(u32, back[3]) * (255 - @as(u32, front[3]));
    const total = frontWeight + backWeight;
    if (total == 0) return @splat(0);
    var out: [4]u8 = undefined;
    for (0..3) |i| out[i] = @intCast((front[i] * frontWeight + back[i] * backWeight) / total);
    out[3] = @intCast(total / 255);
    return out;
}

test over {
    const glass: [4]u8 = .{ 100, 200, 100, 51 };
    const frame: [4]u8 = .{ 10, 20, 30, 255 };
    // An opaque front hides what's behind it.
    try std.testing.expectEqual(frame, over(frame, glass));
    // Over something opaque, the result is opaque.
    try std.testing.expectEqual([4]u8{ 28, 56, 44, 255 }, over(glass, frame));
    // Two layers of glass are more opaque than one, and keep their colour.
    try std.testing.expectEqual([4]u8{ 100, 200, 100, 91 }, over(glass, glass));
}

/// The texel at (u, v), each from 0 to 1.
pub fn texelAt(image: *const world.Image, u: f32, v: f32) [4]u8 {
    const x: usize = @min(image.width - 1, @as(usize, @intFromFloat(std.math.clamp(u, 0, 1) * @as(f32, @floatFromInt(image.width)))));
    const y: usize = @min(image.height - 1, @as(usize, @intFromFloat(std.math.clamp(v, 0, 1) * @as(f32, @floatFromInt(image.height)))));
    return image.pixels[y * image.width + x];
}

test triangle {
    var target: Target = try .init(std.testing.allocator, 4, 4);
    defer target.deinit(std.testing.allocator);
    // A texture red on the left, and holes on the right.
    const pixels = [_][4]u8{ .{ 200, 0, 0, 255 }, .{ 0, 0, 0, 0 } };
    const texture: world.Image = .{ .width = 2, .height = 1, .pixels = &pixels };
    // The top left half of the target, the texture across it; corners in either turn draw.
    const corners = [3]Corner{
        .{ .x = 0, .y = 0, .depth = 1, .u = 0, .v = 0 },
        .{ .x = 4, .y = 0, .depth = 1, .u = 1, .v = 0 },
        .{ .x = 0, .y = 4, .depth = 1, .u = 0, .v = 1 },
    };
    triangle(&target, .{ corners[0], corners[2], corners[1] }, &texture, 128, 1);
    try std.testing.expectEqual([4]u8{ 100, 0, 0, 255 }, target.colours[0]);
    try std.testing.expectEqual(1, target.tags[4]);
    // Through the texture's hole, and outside the triangle, nothing is drawn.
    try std.testing.expectEqual(0, target.tags[2]);
    try std.testing.expectEqual(0, target.tags[15]);
    // Farther, it's hidden; nearer, it covers.
    triangle(&target, corners, &texture, 256, 2);
    try std.testing.expectEqual(1, target.tags[0]);
    var nearer = corners;
    for (&nearer) |*corner| corner.depth = 2;
    triangle(&target, nearer, &texture, 256, 2);
    try std.testing.expectEqual([4]u8{ 200, 0, 0, 255 }, target.colours[0]);
    try std.testing.expectEqual(2, target.tags[0]);

    // Keeping opacity: glass drawn after what's in front of it goes under it, and glass drawn
    // over something stays in front.
    const glassy = [_][4]u8{.{ 100, 100, 200, 51 }};
    const glass: world.Image = .{ .width = 1, .height = 1, .pixels = &glassy };
    const opaque_ = [_][4]u8{.{ 200, 0, 0, 255 }};
    const frame: world.Image = .{ .width = 1, .height = 1, .pixels = &opaque_ };
    var order: [2]Target = .{ try .init(std.testing.allocator, 4, 4), try .init(std.testing.allocator, 4, 4) };
    defer for (order) |one| one.deinit(std.testing.allocator);
    for (&order) |*one| one.keepsOpacity = true;
    triangle(&order[0], corners, &frame, 256, 1);
    triangle(&order[0], nearer, &glass, 256, 1);
    triangle(&order[1], nearer, &glass, 256, 1);
    triangle(&order[1], corners, &frame, 256, 1);
    try std.testing.expectEqual(order[0].colours[0], order[1].colours[0]);
    try std.testing.expectEqual(255, order[0].colours[0][3]);
    try std.testing.expectEqual(2, order[0].depths[0]);
    try std.testing.expectEqual(2, order[1].depths[0]);
    // Alone, glass keeps how opaque it is.
    var alone: Target = try .init(std.testing.allocator, 4, 4);
    defer alone.deinit(std.testing.allocator);
    alone.keepsOpacity = true;
    triangle(&alone, corners, &glass, 256, 1);
    try std.testing.expectEqual(51, alone.colours[0][3]);
}
