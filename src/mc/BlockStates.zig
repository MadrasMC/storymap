//! A block's states as its blockstate file (`assets/minecraft/blockstates/<block>.json`) lists
//! them, each with the models it's drawn with. A state is named by the block and the properties
//! its models depend on, sorted, e.g. `minecraft:oak_stairs[facing=east,half=bottom,shape=straight]`:
//! a save names more (`waterlogged`), which a reader drops to find it.
//!
//! A `variants` file lists each state. A `multipart` file lists parts and the states they apply
//! to, so its states are every combination of the values its conditions name; a property's value
//! is empty in a name where it stands for every value the conditions don't name (`east=` for a
//! wall's `none`), and a condition's `true` or `false` stands for the other too.
const std = @import("std");
const Json = std.json.Value;

/// A model placed in a block, as a blockstate places it.
pub const Placement = struct {
    /// E.g. "minecraft:block/oak_stairs".
    model: []const u8,
    /// Quarter turns about the block's middle, clockwise looking down the axis towards 0: x
    /// first, then y.
    x: u2 = 0,
    y: u2 = 0,
    /// The textures stay as they are in the world, rather than turning with the model.
    uvlock: bool = false,
};

pub const State = struct {
    name: []const u8,
    /// The models it picks one of by where it is (a variant's weighted list), each a list of
    /// models drawn together (a multipart's parts).
    alternates: []const []const Placement,
};

/// The most states a multipart block's combinations may make.
const maxCombinations = 1 << 16;

/// Appends the states of `block`, e.g. "minecraft:oak_stairs", from its blockstate file `json`,
/// kept in `arena`.
pub fn parse(arena: std.mem.Allocator, block: []const u8, json: []const u8, states: *std.ArrayList(State)) !void {
    const root = std.json.parseFromSliceLeaky(Json, arena, json, .{}) catch return error.InvalidBlockState;
    if (root != .object) return error.InvalidBlockState;
    if (root.object.get("variants")) |variants| {
        if (variants != .object) return error.InvalidBlockState;
        var it = variants.object.iterator();
        while (it.next()) |entry| {
            const choices = try placements(arena, entry.value_ptr.*);
            const alternates = try arena.alloc([]const Placement, choices.len);
            for (alternates, choices) |*alternate, *choice| alternate.* = choice[0..1];
            try states.append(arena, .{ .name = try nameOf(arena, block, entry.key_ptr.*), .alternates = alternates });
        }
    } else if (root.object.get("multipart")) |parts| {
        if (parts != .array) return error.InvalidBlockState;
        try parseMultipart(arena, block, parts.array.items, states);
    } else return error.InvalidBlockState;
}

/// The name of a variant: the block, and its key's properties in name order.
fn nameOf(arena: std.mem.Allocator, block: []const u8, key: []const u8) ![]const u8 {
    if (key.len == 0) return arena.dupe(u8, block);
    var pairs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, key, ',');
    while (it.next()) |pair| try pairs.append(arena, pair);
    std.mem.sort([]const u8, pairs.items, {}, lessThan);
    return std.fmt.allocPrint(arena, "{s}[{s}]", .{ block, try std.mem.join(arena, ",", pairs.items) });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// An entry, or each of a list of them.
fn placements(arena: std.mem.Allocator, value: Json) ![]Placement {
    const items: []const Json = switch (value) {
        .array => |array| array.items,
        .object => &.{value},
        else => return error.InvalidBlockState,
    };
    if (items.len == 0) return error.InvalidBlockState;
    const result = try arena.alloc(Placement, items.len);
    for (result, items) |*placement, item| placement.* = try placementOf(arena, item);
    return result;
}

fn placementOf(arena: std.mem.Allocator, value: Json) !Placement {
    if (value != .object) return error.InvalidBlockState;
    const model = value.object.get("model") orelse return error.InvalidBlockState;
    if (model != .string) return error.InvalidBlockState;
    return .{
        .model = try withNamespace(arena, model.string),
        .x = try quarterTurns(value.object.get("x")),
        .y = try quarterTurns(value.object.get("y")),
        .uvlock = if (value.object.get("uvlock")) |lock| lock == .bool and lock.bool else false,
    };
}

/// A resource name with its namespace, which is `minecraft:` where it's left out.
pub fn withNamespace(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, ':') != null) return name;
    return std.fmt.allocPrint(arena, "minecraft:{s}", .{name});
}

fn quarterTurns(value: ?Json) !u2 {
    const degrees: i64 = switch (value orelse return 0) {
        .integer => |n| n,
        .float => |f| std.math.lossyCast(i64, f),
        else => return error.InvalidBlockState,
    };
    if (@mod(degrees, 90) != 0) return error.InvalidBlockState;
    return @intCast(@mod(@divExact(degrees, 90), 4));
}

/// A multipart property's values: those its conditions name, then the empty one standing for the
/// rest, unless the named ones are `true` and `false`.
const Property = struct {
    name: []const u8,
    values: std.ArrayList([]const u8) = .empty,
};

fn parseMultipart(arena: std.mem.Allocator, block: []const u8, parts: []const Json, states: *std.ArrayList(State)) !void {
    var properties: std.ArrayList(Property) = .empty;
    const applied = try arena.alloc(Placement, parts.len);
    for (parts, applied) |part, *placement| {
        if (part != .object) return error.InvalidBlockState;
        // A part that picks one of several models draws its first.
        placement.* = (try placements(arena, part.object.get("apply") orelse return error.InvalidBlockState))[0];
        if (part.object.get("when")) |when| try collect(arena, when, &properties);
    }
    std.mem.sort(Property, properties.items, {}, struct {
        fn lessThan(_: void, a: Property, b: Property) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    var combinations: usize = 1;
    for (properties.items) |*property| {
        if (isBoolean(property.values.items)) {
            property.values.clearRetainingCapacity();
            try property.values.appendSlice(arena, &.{ "false", "true" });
        } else try property.values.append(arena, "");
        combinations = std.math.mul(usize, combinations, property.values.items.len) catch return error.TooManyStates;
    }
    if (combinations > maxCombinations) return error.TooManyStates;

    const values = try arena.alloc([]const u8, properties.items.len);
    for (0..combinations) |combination| {
        var rest = combination;
        var name: std.ArrayList(u8) = .empty;
        try name.appendSlice(arena, block);
        for (properties.items, values, 0..) |property, *value, i| {
            value.* = property.values.items[rest % property.values.items.len];
            rest /= property.values.items.len;
            try name.print(arena, "{s}{s}={s}", .{ if (i == 0) "[" else ",", property.name, value.* });
        }
        if (properties.items.len > 0) try name.append(arena, ']');
        var drawn: std.ArrayList(Placement) = .empty;
        for (parts, applied) |part, placement| {
            const when = part.object.get("when") orelse {
                try drawn.append(arena, placement);
                continue;
            };
            if (try holds(when, properties.items, values)) try drawn.append(arena, placement);
        }
        const alternates = try arena.alloc([]const Placement, 1);
        alternates[0] = drawn.items;
        try states.append(arena, .{ .name = name.items, .alternates = alternates });
    }
}

fn isBoolean(values: []const []const u8) bool {
    for (values) |value| if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return false;
    return true;
}

/// Adds the properties and values a condition names to `properties`.
fn collect(arena: std.mem.Allocator, when: Json, properties: *std.ArrayList(Property)) !void {
    if (when != .object) return error.InvalidBlockState;
    if (when.object.get("OR") orelse when.object.get("AND")) |list| {
        if (list != .array) return error.InvalidBlockState;
        for (list.array.items) |condition| try collect(arena, condition, properties);
        return;
    }
    var it = when.object.iterator();
    while (it.next()) |entry| {
        const property = for (properties.items) |*property| {
            if (std.mem.eql(u8, property.name, entry.key_ptr.*)) break property;
        } else add: {
            try properties.append(arena, .{ .name = entry.key_ptr.* });
            break :add &properties.items[properties.items.len - 1];
        };
        var named = std.mem.splitScalar(u8, try textOf(arena, entry.value_ptr.*), '|');
        while (named.next()) |value| {
            for (property.values.items) |known| {
                if (std.mem.eql(u8, known, value)) break;
            } else try property.values.append(arena, value);
        }
    }
}

/// A condition's value: a string, or a `true`, `false` or number written without quotes.
fn textOf(arena: std.mem.Allocator, value: Json) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .bool => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}),
        else => error.InvalidBlockState,
    };
}

/// Whether condition `when` holds for the state with `values` of `properties`.
fn holds(when: Json, properties: []const Property, values: []const []const u8) !bool {
    if (when.object.get("OR")) |list| {
        for (list.array.items) |condition| if (try holds(condition, properties, values)) return true;
        return false;
    }
    if (when.object.get("AND")) |list| {
        for (list.array.items) |condition| if (!try holds(condition, properties, values)) return false;
        return true;
    }
    var it = when.object.iterator();
    while (it.next()) |entry| {
        const value = for (properties, values) |property, value| {
            if (std.mem.eql(u8, property.name, entry.key_ptr.*)) break value;
        } else unreachable;
        var buffer: [32]u8 = undefined;
        const named = switch (entry.value_ptr.*) {
            .string => |text| text,
            .bool => |b| if (b) "true" else "false",
            .integer => |n| std.fmt.bufPrint(&buffer, "{d}", .{n}) catch return error.InvalidBlockState,
            else => return error.InvalidBlockState,
        };
        var options = std.mem.splitScalar(u8, named, '|');
        const matched = while (options.next()) |option| {
            if (std.mem.eql(u8, option, value)) break true;
        } else false;
        if (!matched) return false;
    }
    return true;
}

test "variants are named by their properties in name order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var states: std.ArrayList(State) = .empty;
    try parse(arena.allocator(), "minecraft:oak_stairs",
        \\{"variants": {
        \\  "half=bottom,facing=east,shape=straight": {"model": "minecraft:block/oak_stairs"},
        \\  "facing=west,half=top,shape=straight": {"model": "block/oak_stairs", "x": 180, "y": 180, "uvlock": true},
        \\  "facing=north,half=bottom,shape=straight": [{"model": "minecraft:block/a"}, {"model": "minecraft:block/b", "y": -90, "weight": 3}]
        \\}}
    , &states);
    try std.testing.expectEqual(3, states.items.len);
    try std.testing.expectEqualStrings("minecraft:oak_stairs[facing=east,half=bottom,shape=straight]", states.items[0].name);
    try std.testing.expectEqualStrings("minecraft:oak_stairs[facing=west,half=top,shape=straight]", states.items[1].name);
    try std.testing.expectEqualDeep(Placement{ .model = "minecraft:block/oak_stairs", .x = 2, .y = 2, .uvlock = true }, states.items[1].alternates[0][0]);
    // A weighted list is a choice of alternates, each one model.
    try std.testing.expectEqual(2, states.items[2].alternates.len);
    try std.testing.expectEqualDeep(Placement{ .model = "minecraft:block/b", .y = 3 }, states.items[2].alternates[1][0]);

    states.clearRetainingCapacity();
    try parse(arena.allocator(), "minecraft:stone", "{\"variants\": {\"\": {\"model\": \"minecraft:block/stone\"}}}", &states);
    try std.testing.expectEqualStrings("minecraft:stone", states.items[0].name);
}

test "a multipart block has a state for each combination its conditions name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var states: std.ArrayList(State) = .empty;
    // A wall cut down: `up` names only `true`, `east` only `low` and `tall`.
    try parse(arena.allocator(), "minecraft:wall",
        \\{"multipart": [
        \\  {"when": {"up": "true"}, "apply": {"model": "minecraft:block/post"}},
        \\  {"when": {"east": "low"}, "apply": {"model": "minecraft:block/side", "uvlock": true}},
        \\  {"when": {"OR": [{"east": "tall"}, {"AND": [{"up": "false"}, {"east": "low|tall"}]}]}, "apply": {"model": "minecraft:block/tall"}},
        \\  {"apply": {"model": "minecraft:block/always"}}
        \\]}
    , &states);
    var names: [6][]const u8 = undefined;
    for (&names, states.items) |*name, state| name.* = state.name;
    try std.testing.expectEqual(6, states.items.len);
    try std.testing.expectEqualDeep([6][]const u8{
        "minecraft:wall[east=low,up=false]", "minecraft:wall[east=tall,up=false]", "minecraft:wall[east=,up=false]",
        "minecraft:wall[east=low,up=true]",  "minecraft:wall[east=tall,up=true]",  "minecraft:wall[east=,up=true]",
    }, names);
    const models = struct {
        fn of(state: State) [4][]const u8 {
            var result: [4][]const u8 = @splat("");
            for (state.alternates[0], 0..) |placement, i| result[i] = placement.model["minecraft:block/".len..];
            return result;
        }
    }.of;
    try std.testing.expectEqualDeep([4][]const u8{ "side", "tall", "always", "" }, models(states.items[0]));
    try std.testing.expectEqualDeep([4][]const u8{ "always", "", "", "" }, models(states.items[2]));
    try std.testing.expectEqualDeep([4][]const u8{ "post", "tall", "always", "" }, models(states.items[4]));
}
