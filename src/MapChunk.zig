//! A `mapchunk` row: data for one chunk column (32 × 32 block columns), including its height
//! maps. Layout and sources: docs/save-format/README.md §7.
const MapChunk = @This();

const std = @import("std");
const ProtoBuf = @import("ProtoBuf.zig");

pub const Error = ProtoBuf.Error || error{
    /// A height map is missing, has the wrong number of values, or a value over 65,535.
    InvalidHeightMap,
    /// The world-generation stage isn't a small number.
    InvalidStage,
};

/// How far world generation has got in a chunk column: the pass it's waiting for, not the
/// last one finished (`EnumWorldGenPass`; docs/save-format/README.md §7). Passes 2 to 5 need
/// the neighbouring columns, so finished columns are ringed by partly generated ones.
pub const Stage = enum(u8) {
    none = 0,
    /// Waiting for terrain, rock layers and caves.
    terrain = 1,
    /// Waiting for deposits, structures and ponds.
    terrainFeatures = 2,
    /// Waiting for plants, shrubs, trees and rivulets.
    vegetation = 3,
    /// Waiting for the snow layer and light spreading across chunks.
    neighbourSunLightFlood = 4,
    /// Waiting for creatures; neighbours may still add things.
    preDone = 5,
    /// Fully generated.
    done = 6,
    _,
};

/// A height the game hasn't set. A few columns hold other values far above the world (down to
/// 65,531), which readers should treat the same.
pub const unset = std.math.maxInt(u16);

/// Per block column, at index z * 32 + x: the highest block that rain can't fall through
/// (field 3). Water stops rain; plants and loose stones don't, so this is the water surface
/// or the ground beneath them.
rainHeight: [1024]u16 = undefined,
/// Per block column: the terrain height when the world was generated, before plants
/// (field 7). For seas and lakes it's their bed.
terrainHeight: [1024]u16 = undefined,
/// The column's world-generation stage (field 4).
stage: Stage = .none,

/// Reads the stage and the height maps from a row's data. Each map is 1,024 repeated varints.
pub fn decode(self: *MapChunk, data: []const u8) Error!void {
    var rain: usize = 0;
    var terrain: usize = 0;
    // A field the game leaves out is 0.
    self.stage = .none;
    var parser: ProtoBuf = .{ .buf = data };
    while (try parser.next()) |msg| {
        if (msg.field_number == 4) {
            self.stage = try stageOf(msg);
            continue;
        }
        const map, const count = switch (msg.field_number) {
            3 => .{ &self.rainHeight, &rain },
            7 => .{ &self.terrainHeight, &terrain },
            else => continue,
        };
        if (msg.data != .VARINT or count.* == map.len) return error.InvalidHeightMap;
        map[count.*] = std.math.cast(u16, msg.data.VARINT) orelse return error.InvalidHeightMap;
        count.* += 1;
    }
    if (rain != 1024 or terrain != 1024) return error.InvalidHeightMap;
}

fn stageOf(msg: ProtoBuf.Message) Error!Stage {
    if (msg.data != .VARINT) return error.InvalidStage;
    return @fromBackingInt(std.math.cast(u8, msg.data.VARINT) orelse return error.InvalidStage);
}

/// A row with field 4 (the world-generation stage, 6: done), then fields 3 and 7 holding
/// `rain` and `terrain` in every column.
fn testRow(rain: u16, terrain: u16) [2 + 1024 * 2 * 3]u8 {
    var row: [2 + 1024 * 2 * 3]u8 = undefined;
    row[0..2].* = .{ 0x20, 0x06 };
    var n: usize = 2;
    for ([_]u8{ 0x18, 0x38 }, [_]u16{ rain, terrain }) |key, value| {
        for (0..1024) |_| {
            // A key byte, then the value as a two-byte varint.
            row[n..][0..3].* = .{ key, @as(u8, @truncate(value)) | 0x80, @intCast(value >> 7) };
            n += 3;
        }
    }
    return row;
}

test decode {
    var mapChunk: MapChunk = .{};
    const row = testRow(130, 128);
    try mapChunk.decode(&row);
    try std.testing.expectEqual(130, mapChunk.rainHeight[0]);
    try std.testing.expectEqual(130, mapChunk.rainHeight[1023]);
    try std.testing.expectEqual(128, mapChunk.terrainHeight[1023]);
    try std.testing.expectEqual(.done, mapChunk.stage);
}

test "the world-generation stage" {
    var mapChunk: MapChunk = .{};
    const row = testRow(130, 128);
    // Without field 4, the game's default: none.
    try mapChunk.decode(row[2..]);
    try std.testing.expectEqual(.none, mapChunk.stage);
    // Stages the game doesn't have yet still read; they just aren't done. The stage is kept
    // when the height maps turn out invalid, as they are here (there are none).
    try std.testing.expectError(error.InvalidHeightMap, mapChunk.decode(&.{ 0x20, 0x09 }));
    try std.testing.expectEqual(@as(Stage, @fromBackingInt(9)), mapChunk.stage);
    // 300 doesn't fit in a byte, and a stage isn't a string.
    try std.testing.expectError(error.InvalidStage, mapChunk.decode(&.{ 0x20, 0xac, 0x02 }));
    try std.testing.expectError(error.InvalidStage, mapChunk.decode(&.{ 0x22, 0x01, 0x06 }));
}

test "a short, long or missing height map is invalid" {
    var mapChunk: MapChunk = .{};
    const row = testRow(130, 128);
    try std.testing.expectError(error.InvalidHeightMap, mapChunk.decode(row[0 .. row.len - 3]));
    try std.testing.expectError(error.InvalidHeightMap, mapChunk.decode(row[0 .. 2 + 1024 * 3]));
    try std.testing.expectError(error.InvalidHeightMap, mapChunk.decode(row[0..2]));
    const long = row ++ [_]u8{ 0x38, 0x80, 0x01 };
    try std.testing.expectError(error.InvalidHeightMap, mapChunk.decode(&long));
    // 65,536 doesn't fit.
    try std.testing.expectError(error.InvalidHeightMap, mapChunk.decode(&.{ 0x18, 0x80, 0x80, 0x04 }));
}
