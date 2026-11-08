//! The client jar's block states, each with the shapes it's drawn in, from the blockstate files
//! and the models they place.
const Blocks = @This();

const std = @import("std");
const Io = std.Io;
const Jar = @import("Jar.zig");
const BlockStates = @import("BlockStates.zig");
const Models = @import("Models.zig");

/// In the order of the blockstate files' names, then as each lists them.
states: []const State,
/// How many blockstate files they're from.
blockCount: usize,

pub const State = struct {
    /// E.g. "minecraft:oak_stairs[facing=east,half=bottom,shape=straight]" (`BlockStates`).
    name: []const u8,
    /// The shapes it picks one of by where it is; a shape without boxes for one its models don't
    /// draw, such as a chest's or water's.
    alternates: []const Models.Shape,
};

/// What couldn't be read, which the blocks are read without.
pub const Problems = struct {
    /// Blockstate files that couldn't be read, e.g. "blockstates/stone.json".
    blockStates: std.ArrayList([]const u8) = .empty,
    /// Models that couldn't be read, each once, e.g. "minecraft:block/stone".
    models: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Biome files that couldn't be read, e.g. "worldgen/biome/plains.json".
    biomes: std.ArrayList([]const u8) = .empty,
};

/// Reads every block state in `jar`, kept in `arena`.
pub fn read(arena: std.mem.Allocator, io: Io, jar: *const Jar, problems: *Problems) !Blocks {
    var paths: std.ArrayList([]const u8) = .empty;
    var keys = jar.entries.keyIterator();
    while (keys.next()) |key| {
        if (std.mem.startsWith(u8, key.*, "blockstates/") and std.mem.endsWith(u8, key.*, ".json")) try paths.append(arena, key.*);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const files: JarFiles = .{ .jar = jar, .io = io };
    var models: Models = .init(arena, .{ .context = &files, .readFn = JarFiles.read });
    var parsed: std.ArrayList(BlockStates.State) = .empty;
    var states: std.ArrayList(State) = .empty;
    for (paths.items) |path| {
        const name = path["blockstates/".len .. path.len - ".json".len];
        const block = try std.fmt.allocPrint(arena, "minecraft:{s}", .{name});
        const json = try jar.read(arena, io, path) orelse unreachable;
        parsed.clearRetainingCapacity();
        BlockStates.parse(arena, block, json, &parsed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try problems.blockStates.append(arena, path);
                continue;
            },
        };
        for (parsed.items) |state| {
            const alternates = try arena.alloc(Models.Shape, state.alternates.len);
            for (alternates, state.alternates) |*shape, placements| {
                var missing: ?[]const u8 = null;
                shape.* = try models.place(placements, &missing);
                if (missing) |model| try problems.models.put(arena, model, {});
            }
            try states.append(arena, .{ .name = state.name, .alternates = alternates });
        }
    }
    return .{ .states = states.items, .blockCount = paths.items.len };
}

const JarFiles = struct {
    jar: *const Jar,
    io: Io,

    fn read(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror!?[]const u8 {
        const self: *const JarFiles = @ptrCast(@alignCast(context));
        return self.jar.read(arena, self.io, path);
    }
};
