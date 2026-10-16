//! The save's `gamedata` row: world-wide data, including which block and item code each
//! numeric ID stands for. Layout and sources: docs/save-format/README.md §6.
const GameData = @This();

const std = @import("std");
const ProtoBuf = @import("ProtoBuf.zig");
const DB = @import("sqlite.zig");

/// Owns everything below.
arena: std.heap.ArenaAllocator,
/// Block code by block ID, e.g. "rock-granite". IDs are per save. null for an unused ID.
blockCodes: []const ?[]const u8,
/// Item code by item ID, like `blockCodes`.
itemCodes: []const ?[]const u8,
/// The world's height in blocks, at most `maxWorldHeight`.
worldHeight: u32,

pub const maxWorldHeight = 1024 * 32;

pub fn read(allocator: std.mem.Allocator, db: DB) !GameData {
    const stmt = try db.prepare("SELECT data FROM gamedata;");
    defer stmt.finalize();
    if (!stmt.step()) return error.NoGameData;
    return parse(allocator, stmt.column([]const u8, 0));
}

/// Everything is copied, so the result outlives `data`.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !GameData {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    var blockCodes: ?[]const ?[]const u8 = null;
    var itemCodes: ?[]const ?[]const u8 = null;
    // The game's default, should a save ever leave the field out.
    var worldHeight: u32 = 256;

    var parser: ProtoBuf = .{ .buf = data };
    while (try parser.next()) |msg| {
        if (msg.field_number == 2 and msg.data == .VARINT) {
            // Chunk y positions have 10 bits, so no world is taller than 1,024 chunks.
            if (msg.data.VARINT == 0 or msg.data.VARINT > maxWorldHeight) return error.InvalidWorldHeight;
            worldHeight = @intCast(msg.data.VARINT);
        }
        // Field 11 holds named data entries: { 1: key, 2: value }.
        if (msg.field_number != 11 or msg.data != .LEN) continue;
        var key: []const u8 = "";
        var value: []const u8 = "";
        var entry: ProtoBuf = .{ .buf = msg.data.LEN };
        while (try entry.next()) |part| {
            if (part.data != .LEN) continue;
            switch (part.field_number) {
                1 => key = part.data.LEN,
                2 => value = part.data.LEN,
                else => {},
            }
        }
        if (std.mem.eql(u8, key, "BlockIDs")) blockCodes = try parseIdMapping(arena.allocator(), value);
        if (std.mem.eql(u8, key, "ItemIDs")) itemCodes = try parseIdMapping(arena.allocator(), value);
    }
    return .{
        .arena = arena,
        .blockCodes = blockCodes orelse return error.NoBlockIds,
        .itemCodes = itemCodes orelse &.{},
        .worldHeight = worldHeight,
    };
}

/// The height of the water surface of seas and lakes: water fills the blocks below it.
/// The save doesn't store it; the game derives it from the world height
/// (docs/save-format/README.md#sea-level).
pub fn seaLevel(self: GameData) u32 {
    return self.worldHeight * 110 / 255;
}

pub fn deinit(self: GameData) void {
    self.arena.deinit();
}

pub fn blockCode(self: GameData, id: i32) ?[]const u8 {
    return lookup(self.blockCodes, id);
}

pub fn itemCode(self: GameData, id: i32) ?[]const u8 {
    return lookup(self.itemCodes, id);
}

fn lookup(codes: []const ?[]const u8, id: i32) ?[]const u8 {
    if (id < 0 or id >= codes.len) return null;
    return codes[@intCast(id)];
}

/// A list of { 1: id, 2: code } entries, indexed by id in the result.
fn parseIdMapping(arena: std.mem.Allocator, bytes: []const u8) ![]?[]const u8 {
    const Pair = struct { id: u64, code: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    var maxId: u64 = 0;
    var parser: ProtoBuf = .{ .buf = bytes };
    while (try parser.next()) |msg| {
        if (msg.field_number != 1 or msg.data != .LEN) continue;
        // Protobuf may leave out an id of 0, its default.
        var pair: Pair = .{ .id = 0, .code = "" };
        var entry: ProtoBuf = .{ .buf = msg.data.LEN };
        while (try entry.next()) |part| switch (part.field_number) {
            1 => if (part.data == .VARINT) {
                pair.id = part.data.VARINT;
            },
            2 => if (part.data == .LEN) {
                pair.code = try arena.dupe(u8, part.data.LEN);
            },
            else => {},
        };
        maxId = @max(maxId, pair.id);
        try pairs.append(arena, pair);
    }
    if (pairs.items.len == 0) return &.{};
    // IDs are contiguous in practice; a much larger maximum can only be corrupt data.
    if (maxId > pairs.items.len * 2) return error.InvalidIdMapping;
    const codes = try arena.alloc(?[]const u8, maxId + 1);
    @memset(codes, null);
    for (pairs.items) |pair| codes[pair.id] = pair.code;
    return codes;
}

test "BlockIDs and ItemIDs in the layout real saves use" {
    // A cut-down gamedata row: field 1 (world width, a varint), field 2 (world height, 256),
    // field 25 (a fixed 32-bit float), then
    // field 11 { 1: "BlockIDs", 2: [ { 1: 0, 2: "air" }, { 1: 1, 2: "mantle" } ] }.
    const data = [_]u8{
        0x08, 0x80, 0xc0, 0x3e, 0x10, 0x80, 0x02, 0xcd, 0x01, 0x00, 0x00, 0xc0, 0x41,
        0x5a, 0x21, 0x0a, 0x08, 'B',  'l',  'o',  'c',  'k',  'I',  'D',  's',  0x12,
        0x15, 0x0a, 0x07, 0x08, 0x00, 0x12, 0x03, 'a',  'i',  'r',  0x0a, 0x0a, 0x08,
        0x01, 0x12, 0x06, 'm',  'a',  'n',  't',  'l',  'e',
    };
    const gameData = try parse(std.testing.allocator, &data);
    defer gameData.deinit();
    try std.testing.expectEqualStrings("air", gameData.blockCode(0).?);
    try std.testing.expectEqualStrings("mantle", gameData.blockCode(1).?);
    try std.testing.expectEqual(null, gameData.blockCode(2));
    try std.testing.expectEqual(null, gameData.blockCode(-1));
    try std.testing.expectEqual(null, gameData.itemCode(0));
    try std.testing.expectEqual(256, gameData.worldHeight);
    try std.testing.expectEqual(110, gameData.seaLevel());
}

test "a world height of 0 or over 1,024 chunks is invalid" {
    // Field 2 = 0, then field 2 = 32,769.
    try std.testing.expectError(error.InvalidWorldHeight, parse(std.testing.allocator, &.{ 0x10, 0x00 }));
    try std.testing.expectError(error.InvalidWorldHeight, parse(std.testing.allocator, &.{ 0x10, 0x81, 0x80, 0x02 }));
}

test seaLevel {
    // The wiki's table: https://wiki.vintagestory.at/Sea_level
    for ([_][2]u32{ .{ 128, 55 }, .{ 192, 82 }, .{ 256, 110 }, .{ 320, 138 }, .{ 384, 165 }, .{ 448, 193 }, .{ 512, 220 } }) |row| {
        const gameData: GameData = .{ .arena = undefined, .blockCodes = &.{}, .itemCodes = &.{}, .worldHeight = row[0] };
        try std.testing.expectEqual(row[1], gameData.seaLevel());
    }
}
