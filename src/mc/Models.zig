//! Block models (`assets/minecraft/models/<path>.json`), placed in a block as a blockstate places
//! them: the boxes a block state is drawn with, each face in a texture. A model takes its
//! `elements` from the nearest of itself and its parents that has them, and its textures from
//! all of them, a model's own replacing its parents'.
//!
//! Positions in a model are in sixteenths of a block; boxes come out in blocks, as `world.Shape`
//! has them.
const Models = @This();

const std = @import("std");
const world = @import("world");
const BlockStates = @import("BlockStates.zig");
const Json = std.json.Value;
const Side = world.Shape.Side;

arena: std.mem.Allocator,
files: Files,
/// The models read so far, by name, e.g. "minecraft:block/stone"; null for one that couldn't
/// be read.
resolved: std.StringHashMapUnmanaged(?*const Model) = .empty,

/// Where model files come from: the jar, or a test's files.
pub const Files = struct {
    context: *const anyopaque,
    /// The file at `path` below `assets/minecraft/`, e.g. "models/block/stone.json"; null if
    /// there's none.
    readFn: *const fn (context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror!?[]const u8,
};

/// A face's texture, e.g. "minecraft:block/oak_planks", and whether the block's tint colours it.
pub const Texture = struct {
    name: []const u8,
    tinted: bool,
};

/// What drawing a block state in its shape needs: its boxes, whose faces' `texture` is an index
/// in `textures`.
pub const Shape = struct {
    boxes: []const world.Shape.Box,
    textures: []const Texture,
    /// The texture of the highest face that faces up, which a map seen from above shows.
    top: ?u16 = null,
    /// How high its boxes reach, in blocks.
    height: f32 = 0,
};

/// A model as its parents make it.
const Model = struct {
    elements: []const Element,
    /// By key, e.g. "all" → "minecraft:block/stone" or "#side".
    textures: std.StringHashMapUnmanaged([]const u8),
};

const Element = struct {
    from: [3]f32,
    to: [3]f32,
    /// How it's turned and stretched about `origin`, in sixteenths of a block.
    rotation: ?struct { origin: [3]f32, matrix: [3][3]f32 },
    /// Lit by the way its faces face; not when they're lit as a top is
    /// (`shade_direction_override: up`).
    shade: bool,
    /// By `Side`.
    faces: [6]?Face,
};

const Face = struct {
    /// E.g. "#side".
    texture: []const u8,
    /// The texture's corners at the face's top left and bottom right, in sixteenths; from the
    /// element's position where the model doesn't give them.
    uv: ?[4]f32,
    /// Quarter turns of the texture, clockwise.
    turns: u2,
    tinted: bool,
};

/// How deep a model's parents and texture references may go.
const maxDepth = 32;

pub fn init(arena: std.mem.Allocator, files: Files) Models {
    return .{ .arena = arena, .files = files };
}

/// The boxes of `placements`, drawn together, e.g. a fence's post and the sides it joins. A
/// model that can't be read is left out, and named in `missing`.
pub fn place(self: *Models, placements: []const BlockStates.Placement, missing: *?[]const u8) !Shape {
    var boxes: std.ArrayList(world.Shape.Box) = .empty;
    var textures: std.ArrayList(Texture) = .empty;
    var top: ?u16 = null;
    var topHeight: f32 = -std.math.inf(f32);
    var height: f32 = 0;
    for (placements) |placement| {
        const model = try self.resolve(placement.model, 0) orelse {
            missing.* = placement.model;
            continue;
        };
        const turn = blockTurn(placement.x, placement.y);
        for (model.elements) |element| {
            var box: world.Shape.Box = .{
                .transform = multiply(turn, elementTransform(element)),
                .size = .{ (element.to[0] - element.from[0]) / 16, (element.to[1] - element.from[1]) / 16, (element.to[2] - element.from[2]) / 16 },
                .shade = element.shade,
                .faces = @splat(null),
            };
            for (element.faces, 0..) |maybeFace, i| {
                const face = maybeFace orelse continue;
                const name = textureName(model, face.texture) orelse continue;
                const side: Side = @fromBackingInt(@intCast(i));
                const uv = if (placement.uvlock and (placement.x != 0 or placement.y != 0))
                    lockedUv(box.transform, box.size, side)
                else
                    faceUv(face, side, element.from, element.to);
                const texture = try indexOf(self.arena, &textures, .{ .name = name, .tinted = face.tinted });
                box.faces[i] = .{ .texture = texture, .uv = uv };
                if (sideFacing(box.transform, side) == .up) {
                    const y = highest(box.transform, box.size, &side.corners());
                    if (y > topHeight) {
                        topHeight = y;
                        top = texture;
                    }
                }
            }
            const corners = [8][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 } };
            height = @max(height, highest(box.transform, box.size, &corners));
            try boxes.append(self.arena, box);
        }
    }
    return .{ .boxes = boxes.items, .textures = textures.items, .top = top, .height = height };
}

/// How high the highest of `corners`, of a box from (0, 0, 0) to (1, 1, 1), is once the box is
/// `size` and placed by `transform`.
fn highest(transform: Transform, size: [3]f32, corners: []const [3]f32) f32 {
    var result = -std.math.inf(f32);
    for (corners) |corner| result = @max(result, apply(transform, .{ corner[0] * size[0], corner[1] * size[1], corner[2] * size[2] })[1]);
    return result;
}

fn indexOf(arena: std.mem.Allocator, textures: *std.ArrayList(Texture), texture: Texture) !u16 {
    for (textures.items, 0..) |known, i| {
        if (known.tinted == texture.tinted and std.mem.eql(u8, known.name, texture.name)) return @intCast(i);
    }
    try textures.append(arena, texture);
    return @intCast(textures.items.len - 1);
}

/// The texture a face's `#key` names, following keys that name other keys; null where it names
/// none.
fn textureName(model: *const Model, reference: []const u8) ?[]const u8 {
    var name = reference;
    for (0..maxDepth) |_| {
        if (name.len == 0 or name[0] != '#') return name;
        name = model.textures.get(name[1..]) orelse return null;
    }
    return null;
}

/// Model `name` with what its parents give it; null if it, or a parent, can't be read.
fn resolve(self: *Models, name: []const u8, depth: usize) anyerror!?*const Model {
    if (self.resolved.get(name)) |model| return model;
    const model = if (depth < maxDepth) try self.read(name, depth) else null;
    try self.resolved.put(self.arena, name, model);
    return model;
}

fn read(self: *Models, name: []const u8, depth: usize) !?*const Model {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
    if (!std.mem.eql(u8, name[0..colon], "minecraft")) return null;
    const path = try std.fmt.allocPrint(self.arena, "models/{s}.json", .{name[colon + 1 ..]});
    const bytes = try self.files.readFn(self.files.context, self.arena, path) orelse return null;
    const root = std.json.parseFromSliceLeaky(Json, self.arena, bytes, .{}) catch return null;
    if (root != .object) return null;

    const model = try self.arena.create(Model);
    model.* = .{ .elements = &.{}, .textures = .empty };
    if (root.object.get("parent")) |parent| {
        if (parent != .string) return null;
        const inherited = try self.resolve(try BlockStates.withNamespace(self.arena, parent.string), depth + 1) orelse return null;
        model.elements = inherited.elements;
        model.textures = try inherited.textures.clone(self.arena);
    }
    if (root.object.get("textures")) |textures| {
        if (textures != .object) return null;
        var it = textures.object.iterator();
        while (it.next()) |entry| {
            // A texture is its name, or an object naming it as `sprite`.
            const value = switch (entry.value_ptr.*) {
                .string => |text| text,
                .object => |object| if (object.get("sprite")) |sprite| (if (sprite == .string) sprite.string else return null) else return null,
                else => return null,
            };
            const named = if (value.len > 0 and value[0] == '#') value else try BlockStates.withNamespace(self.arena, value);
            try model.textures.put(self.arena, entry.key_ptr.*, named);
        }
    }
    if (root.object.get("elements")) |elements| {
        if (elements != .array) return null;
        const list = try self.arena.alloc(Element, elements.array.items.len);
        for (list, elements.array.items) |*element, value| element.* = elementOf(value) orelse return null;
        model.elements = list;
    }
    return model;
}

fn elementOf(value: Json) ?Element {
    if (value != .object) return null;
    const object = value.object;
    var element: Element = .{
        .from = vector(3, object.get("from")) orelse return null,
        .to = vector(3, object.get("to")) orelse return null,
        .rotation = null,
        .shade = if (object.get("shade_direction_override")) |direction| !(direction == .string and std.mem.eql(u8, direction.string, "up")) else true,
        .faces = @splat(null),
    };
    if (object.get("rotation")) |rotation| {
        if (rotation != .object) return null;
        element.rotation = .{
            .origin = vector(3, rotation.object.get("origin")) orelse return null,
            .matrix = rotationOf(rotation.object) orelse return null,
        };
    }
    const faces = object.get("faces") orelse return element;
    if (faces != .object) return null;
    for (std.enums.values(Side)) |side| {
        if (faces.object.get(@tagName(side))) |face| {
            if (face != .object) return null;
            const texture = face.object.get("texture") orelse return null;
            if (texture != .string) return null;
            element.faces[@backingInt(side)] = .{
                .texture = texture.string,
                .uv = if (face.object.get("uv")) |uv| vector(4, uv) orelse return null else null,
                .turns = if (number(face.object.get("rotation"))) |degrees| @intCast(@mod(@divFloor(@as(i64, @intFromFloat(degrees)), 90), 4)) else 0,
                .tinted = face.object.get("tintindex") != null,
            };
        }
    }
    return element;
}

/// An element's rotation: one turn about an axis, stretched back to fill its block where it
/// says `rescale`, or a turn about each of x, y and z, applied in that order. Angles turn
/// anticlockwise looking down the axis towards 0.
fn rotationOf(rotation: std.json.ObjectMap) ?[3][3]f32 {
    if (rotation.get("axis")) |axis| {
        if (axis != .string or axis.string.len != 1) return null;
        const index: usize = switch (axis.string[0]) {
            'x' => 0,
            'y' => 1,
            'z' => 2,
            else => return null,
        };
        const degrees = number(rotation.get("angle")) orelse return null;
        var matrix = turnAbout(index, degrees);
        const rescale = if (rotation.get("rescale")) |value| value == .bool and value.bool else false;
        if (rescale) {
            const stretch = 1 / @cos(std.math.degreesToRadians(degrees));
            for (0..3) |row| for (0..3) |column| {
                if (row != index) matrix[row][column] *= stretch;
            };
        }
        return matrix;
    }
    var matrix = turnAbout(0, number(rotation.get("x")) orelse 0);
    matrix = multiply3(turnAbout(1, number(rotation.get("y")) orelse 0), matrix);
    return multiply3(turnAbout(2, number(rotation.get("z")) orelse 0), matrix);
}

/// A turn of `degrees` about axis `index`, anticlockwise looking down it towards 0.
fn turnAbout(index: usize, degrees: f32) [3][3]f32 {
    const radians = std.math.degreesToRadians(degrees);
    const c = @cos(radians);
    const s = @sin(radians);
    return switch (index) {
        0 => .{ .{ 1, 0, 0 }, .{ 0, c, -s }, .{ 0, s, c } },
        1 => .{ .{ c, 0, s }, .{ 0, 1, 0 }, .{ -s, 0, c } },
        else => .{ .{ c, -s, 0 }, .{ s, c, 0 }, .{ 0, 0, 1 } },
    };
}

fn number(value: ?Json) ?f32 {
    return switch (value orelse return null) {
        .integer => |n| @floatFromInt(n),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn vector(comptime n: usize, value: ?Json) ?[n]f32 {
    const array = value orelse return null;
    if (array != .array or array.array.items.len != n) return null;
    var result: [n]f32 = undefined;
    for (&result, array.array.items) |*item, part| item.* = number(part) orelse return null;
    return result;
}

pub const Transform = [3][4]f32;

/// Where an element's box goes in its model: from its corner at `from`, turned and stretched
/// about its rotation's origin; in blocks.
fn elementTransform(element: Element) Transform {
    const from: [3]f32 = .{ element.from[0] / 16, element.from[1] / 16, element.from[2] / 16 };
    const rotation = element.rotation orelse return translation(from);
    const origin: [3]f32 = .{ rotation.origin[0] / 16, rotation.origin[1] / 16, rotation.origin[2] / 16 };
    return multiply(about(origin, rotation.matrix), translation(from));
}

/// A blockstate's turn of a model about the block's middle: x quarter turns, then y, each
/// clockwise looking down the axis towards 0. Exact, so turned boxes meet as unturned ones do.
pub fn blockTurn(x: u2, y: u2) Transform {
    var matrix: [3][3]f32 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    for (0..x) |_| matrix = multiply3(.{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, -1, 0 } }, matrix);
    for (0..y) |_| matrix = multiply3(.{ .{ 0, 0, -1 }, .{ 0, 1, 0 }, .{ 1, 0, 0 } }, matrix);
    return about(@splat(0.5), matrix);
}

pub fn translation(by: [3]f32) Transform {
    return .{ .{ 1, 0, 0, by[0] }, .{ 0, 1, 0, by[1] }, .{ 0, 0, 1, by[2] } };
}

/// `matrix` applied about `origin`.
fn about(origin: [3]f32, matrix: [3][3]f32) Transform {
    var result: Transform = undefined;
    for (0..3) |row| {
        var shift = origin[row];
        for (0..3) |column| {
            result[row][column] = matrix[row][column];
            shift -= matrix[row][column] * origin[column];
        }
        result[row][3] = shift;
    }
    return result;
}

pub fn multiply(a: Transform, b: Transform) Transform {
    var result: Transform = undefined;
    for (0..3) |row| {
        for (0..4) |column| {
            var sum: f32 = if (column == 3) a[row][3] else 0;
            for (0..3) |k| sum += a[row][k] * b[k][column];
            result[row][column] = sum;
        }
    }
    return result;
}

fn multiply3(a: [3][3]f32, b: [3][3]f32) [3][3]f32 {
    var result: [3][3]f32 = undefined;
    for (0..3) |row| for (0..3) |column| {
        var sum: f32 = 0;
        for (0..3) |k| sum += a[row][k] * b[k][column];
        result[row][column] = sum;
    };
    return result;
}

fn apply(transform: Transform, point: [3]f32) [3]f32 {
    var result: [3]f32 = undefined;
    for (0..3) |row| result[row] = transform[row][0] * point[0] + transform[row][1] * point[1] + transform[row][2] * point[2] + transform[row][3];
    return result;
}

/// Where a point on face `side` of a box from (0, 0, 0) to (1, 1, 1) is across and down the
/// face as it's seen from outside: the sides with up at the top, the top with north at the top,
/// and the bottom with south at the top. Each from 0 to 1.
fn acrossAndDown(side: Side, point: [3]f32) [2]f32 {
    const x, const y, const z = point;
    return switch (side) {
        .north => .{ 1 - x, 1 - y },
        .south => .{ x, 1 - y },
        .west => .{ z, 1 - y },
        .east => .{ 1 - z, 1 - y },
        .up => .{ x, z },
        .down => .{ x, 1 - z },
    };
}

/// A face's texture coordinates at each of its corners (`Side.corners`): its `uv`, or where the
/// element's position puts it, turned by its rotation.
fn faceUv(face: Face, side: Side, from: [3]f32, to: [3]f32) [4][2]f32 {
    const rect = face.uv orelse rect: {
        var low: [3]f32 = undefined;
        var high: [3]f32 = undefined;
        for (0..3) |i| {
            low[i] = from[i] / 16;
            high[i] = to[i] / 16;
        }
        const a = acrossAndDown(side, low);
        const b = acrossAndDown(side, high);
        break :rect .{ @min(a[0], b[0]) * 16, @min(a[1], b[1]) * 16, @max(a[0], b[0]) * 16, @max(a[1], b[1]) * 16 };
    };
    // The texture's corners going round: top left, top right, bottom right, bottom left.
    const corners = [4][2]f32{ .{ rect[0], rect[1] }, .{ rect[2], rect[1] }, .{ rect[2], rect[3] }, .{ rect[0], rect[3] } };
    var uv: [4][2]f32 = undefined;
    for (&uv, side.corners()) |*corner, point| {
        const across, const down = acrossAndDown(side, point);
        const at: u2 = if (down < 0.5) (if (across < 0.5) 0 else 1) else (if (across < 0.5) 3 else 2);
        const texture = corners[at -% face.turns];
        corner.* = .{ texture[0] / 16, texture[1] / 16 };
    }
    return uv;
}

/// A face's texture coordinates where they stay as they are in the world (`uvlock`): from where
/// its corners are in the block, on the side it faces once turned.
fn lockedUv(transform: Transform, size: [3]f32, side: Side) [4][2]f32 {
    const facing = sideFacing(transform, side);
    var uv: [4][2]f32 = undefined;
    for (&uv, side.corners()) |*corner, point| {
        const placed = apply(transform, .{ point[0] * size[0], point[1] * size[1], point[2] * size[2] });
        corner.* = acrossAndDown(facing, placed);
    }
    return uv;
}

/// The side face `side` of a box faces once `transform` places it, the nearest if it's turned
/// part of the way.
fn sideFacing(transform: Transform, side: Side) Side {
    const out: [3]f32 = switch (side) {
        .north => .{ 0, 0, -1 },
        .east => .{ 1, 0, 0 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .up => .{ 0, 1, 0 },
        .down => .{ 0, -1, 0 },
    };
    var normal: [3]f32 = undefined;
    for (0..3) |row| normal[row] = transform[row][0] * out[0] + transform[row][1] * out[1] + transform[row][2] * out[2];
    const axis = std.mem.indexOfMax(f32, &.{ @abs(normal[0]), @abs(normal[1]), @abs(normal[2]) });
    return switch (axis) {
        0 => if (normal[0] > 0) .east else .west,
        1 => if (normal[1] > 0) .up else .down,
        else => if (normal[2] > 0) .south else .north,
    };
}

const TestFiles = struct {
    files: []const [2][]const u8,

    fn read(context: *const anyopaque, _: std.mem.Allocator, path: []const u8) anyerror!?[]const u8 {
        const self: *const TestFiles = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.eql(u8, file[0], path)) return file[1];
        return null;
    }
};

fn expectNear(expected: anytype, actual: @TypeOf(expected)) !void {
    const a: []const f32 = @ptrCast(&expected);
    const b: []const f32 = @ptrCast(&actual);
    for (a, b) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-5);
}

test "a model takes its parents' elements and textures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const files: TestFiles = .{ .files = &.{
        .{
            "models/block/cube.json",
            \\{"elements": [{"from": [0, 0, 0], "to": [16, 16, 16], "faces": {
            \\  "up": {"texture": "#up", "tintindex": 0}, "north": {"texture": "#north", "uv": [0, 0, 16, 8], "rotation": 90},
            \\  "east": {"texture": "#missing"}}}]}
        },
        .{ "models/block/cube_column.json", "{\"parent\": \"block/cube\", \"textures\": {\"up\": \"#end\", \"north\": \"#side\"}}" },
        .{ "models/block/oak_log.json", "{\"parent\": \"minecraft:block/cube_column\", \"textures\": {\"end\": \"block/oak_log_top\", \"side\": {\"sprite\": \"minecraft:block/oak_log\"}}}" },
    } };
    var models: Models = .init(arena.allocator(), .{ .context = &files, .readFn = TestFiles.read });
    var missing: ?[]const u8 = null;
    const shape = try models.place(&.{.{ .model = "minecraft:block/oak_log" }}, &missing);
    try std.testing.expectEqual(null, missing);
    try std.testing.expectEqual(1, shape.boxes.len);
    try std.testing.expectEqualDeep(&[_]Texture{ .{ .name = "minecraft:block/oak_log", .tinted = false }, .{ .name = "minecraft:block/oak_log_top", .tinted = true } }, shape.textures);
    const box = shape.boxes[0];
    try std.testing.expectEqual(null, box.faces[@backingInt(Side.east)]);
    // The top's texture as the element's position puts it: its top left at the face's north-west.
    try expectNear([4][2]f32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } }, box.faces[@backingInt(Side.up)].?.uv);
    // The north face's top half of the texture, turned a quarter clockwise: the face's top left
    // (its north-east corner, at the top) shows the texture's bottom left.
    try expectNear([4][2]f32{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0.5 }, .{ 1, 0.5 } }, box.faces[@backingInt(Side.north)].?.uv);

    const missingShape = try models.place(&.{.{ .model = "minecraft:block/nothing" }}, &missing);
    try std.testing.expectEqualStrings("minecraft:block/nothing", missing.?);
    try std.testing.expectEqual(0, missingShape.boxes.len);
}

test "a blockstate's turns, and textures kept as they are in the world" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A slab along the north edge: half a block deep.
    const files: TestFiles = .{ .files = &.{.{
        "models/block/half.json",
        \\{"textures": {"t": "block/stone"}, "elements": [{"from": [0, 0, 0], "to": [16, 16, 8], "faces": {"up": {"texture": "#t"}}}]}
    }} };
    var models: Models = .init(arena.allocator(), .{ .context = &files, .readFn = TestFiles.read });
    var missing: ?[]const u8 = null;
    // y = 1: north turns to east.
    const turned = (try models.place(&.{.{ .model = "minecraft:block/half", .y = 1 }}, &missing)).boxes[0];
    try expectNear([3]f32{ 1, 1, 0 }, apply(turned.transform, .{ 0, 1, 0 }));
    try expectNear([3]f32{ 0.5, 0, 0 }, apply(turned.transform, .{ 0, 0, 0.5 }));
    // The top's texture turns with it: the box's own top is the north half of the texture.
    try expectNear([4][2]f32{ .{ 0, 0 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 } }, turned.faces[@backingInt(Side.up)].?.uv);
    // With uvlock it's where the box is in the world: its east half.
    const locked = (try models.place(&.{.{ .model = "minecraft:block/half", .y = 1, .uvlock = true }}, &missing)).boxes[0];
    try expectNear([4][2]f32{ .{ 1, 0 }, .{ 0.5, 0 }, .{ 0.5, 1 }, .{ 1, 1 } }, locked.faces[@backingInt(Side.up)].?.uv);
    // x = 1: up turns to north.
    try expectNear([3]f32{ 0, 1, 0 }, apply(blockTurn(1, 0), .{ 0, 1, 1 }));
}

test "an element turned about its origin and stretched back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A cross's plane, turned 45° about the middle: its ends reach the block's corners.
    const files: TestFiles = .{ .files = &.{.{
        "models/block/plane.json",
        \\{"elements": [{"from": [0, 0, 8], "to": [16, 16, 8], "shade_direction_override": "up",
        \\  "rotation": {"origin": [8, 8, 8], "axis": "y", "angle": 45, "rescale": true}}]}
    }} };
    var models: Models = .init(arena.allocator(), .{ .context = &files, .readFn = TestFiles.read });
    var missing: ?[]const u8 = null;
    const box = (try models.place(&.{.{ .model = "minecraft:block/plane" }}, &missing)).boxes[0];
    try std.testing.expect(!box.shade);
    try expectNear([3]f32{ 1, 1, 0 }, box.size);
    // Anticlockwise looking down y: the west end goes south.
    try expectNear([3]f32{ 0, 0, 1 }, apply(box.transform, .{ 0, 0, 0 }));
    try expectNear([3]f32{ 1, 0, 0 }, apply(box.transform, .{ 1, 0, 0 }));
}
