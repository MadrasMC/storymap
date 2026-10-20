//! The save's `gamedata` row: world-wide data, including which block and item code each
//! numeric ID stands for. Layout and sources: docs/save-format/README.md §6.
const GameData = @This();

const std = @import("std");
const ProtoBuf = @import("protobuf");
const DB = @import("sqlite");
const Chunk = @import("Chunk.zig");
const TreeAttribute = @import("TreeAttribute.zig");

/// Owns everything below.
arena: std.heap.ArenaAllocator,
/// Block code by block ID, e.g. "rock-granite". IDs are per save. null for an unused ID.
blockCodes: []const ?[]const u8,
/// Item code by item ID, like `blockCodes`.
itemCodes: []const ?[]const u8,
/// The world's height in blocks, at most `maxWorldHeight`.
worldHeight: u32,
/// The world's size east to west (x) and north to south (z) in blocks (fields 1 and 3). The
/// defaults are the game's.
worldWidth: u64 = 1024000,
worldLength: u64 = 1024000,
/// The world's name, as the player gave it (field 13).
name: []const u8 = "",
/// The version of the game that last saved the world, e.g. "1.22.7" (field 21).
gameVersion: []const u8 = "",
/// The in-game clock when the world was saved, in game seconds (field 12), and the hours in a
/// game day (field 25).
totalGameSeconds: u64 = 0,
hoursPerDay: f32 = 24,
/// The days in a month, from the world config's `daysPerMonth` (field 31). The game's
/// default is 9, and a year has 12 months.
daysPerMonth: u32 = 9,

/// The game's limits, which chunk positions are sized for (Chunk.Position): 16,384 blocks
/// high and 2²⁶ across.
pub const maxWorldHeight = Chunk.Position.levels * 32;
pub const maxWorldWidth = (Chunk.Position.maxXZ + 1) * 32;

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
    // The game's defaults, should a save ever leave the fields out.
    var worldHeight: u32 = 256;
    var worldWidth: u64 = 1024000;
    var worldLength: u64 = 1024000;
    var name: []const u8 = "";
    var gameVersion: []const u8 = "";
    var totalGameSeconds: u64 = 0;
    var hoursPerDay: f32 = 24;
    var daysPerMonth: u32 = 9;

    var parser: ProtoBuf = .{ .buf = data };
    while (try parser.next()) |msg| {
        if (msg.field_number == 12 and msg.data == .VARINT) totalGameSeconds = msg.data.VARINT;
        if (msg.field_number == 25 and msg.data == .I32) {
            const hours: f32 = @bitCast(msg.data.I32);
            if (hours > 0) hoursPerDay = hours;
        }
        if (msg.field_number == 31 and msg.data == .LEN) daysPerMonth = worldDaysPerMonth(arena.allocator(), msg.data.LEN) orelse daysPerMonth;
        if (msg.field_number == 2 and msg.data == .VARINT) {
            if (msg.data.VARINT == 0 or msg.data.VARINT > maxWorldHeight) return error.InvalidWorldHeight;
            worldHeight = @intCast(msg.data.VARINT);
        }
        if ((msg.field_number == 1 or msg.field_number == 3) and msg.data == .VARINT) {
            if (msg.data.VARINT == 0 or msg.data.VARINT > maxWorldWidth) return error.InvalidWorldSize;
            if (msg.field_number == 1) worldWidth = msg.data.VARINT else worldLength = msg.data.VARINT;
        }
        if (msg.field_number == 13 and msg.data == .LEN) name = try arena.allocator().dupe(u8, msg.data.LEN);
        if (msg.field_number == 21 and msg.data == .LEN) gameVersion = try arena.allocator().dupe(u8, msg.data.LEN);
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
        .worldWidth = worldWidth,
        .worldLength = worldLength,
        .name = name,
        .gameVersion = gameVersion,
        .totalGameSeconds = totalGameSeconds,
        .hoursPerDay = hoursPerDay,
        .daysPerMonth = daysPerMonth,
    };
}

/// `daysPerMonth` from the world config, a tree attribute whose values are strings, or null
/// if it isn't there or can't be read.
fn worldDaysPerMonth(arena: std.mem.Allocator, bytes: []const u8) ?u32 {
    var reader: TreeAttribute.Reader = .{ .bytes = bytes };
    const config = TreeAttribute.parse(arena, &reader) catch return null;
    const days = std.fmt.parseInt(u32, config.getString("daysPerMonth") orelse return null, 10) catch return null;
    return if (days > 0) days else null;
}

/// How far through the year the save's clock is, from 0 at the start of January to 1.
pub fn yearProgress(self: GameData) f32 {
    const days = @as(f64, @floatFromInt(self.totalGameSeconds)) / 3600 / self.hoursPerDay;
    const daysPerYear: f64 = @floatFromInt(12 * self.daysPerMonth);
    return @floatCast(@mod(days, daysPerYear) / daysPerYear);
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

/// A cut-down gamedata row: field 1 (world width, 1,024,000), field 2 (world height, 256),
/// field 25 (a fixed 32-bit float), then
/// field 11 { 1: "BlockIDs", 2: [ { 1: 0, 2: "air" }, { 1: 1, 2: "mantle" } ] }.
const testRow = [_]u8{
    0x08, 0x80, 0xc0, 0x3e, 0x10, 0x80, 0x02, 0xcd, 0x01, 0x00, 0x00, 0xc0, 0x41,
    0x5a, 0x21, 0x0a, 0x08, 'B',  'l',  'o',  'c',  'k',  'I',  'D',  's',  0x12,
    0x15, 0x0a, 0x07, 0x08, 0x00, 0x12, 0x03, 'a',  'i',  'r',  0x0a, 0x0a, 0x08,
    0x01, 0x12, 0x06, 'm',  'a',  'n',  't',  'l',  'e',
};

test "BlockIDs and ItemIDs in the layout real saves use" {
    const gameData = try parse(std.testing.allocator, &testRow);
    defer gameData.deinit();
    try std.testing.expectEqualStrings("air", gameData.blockCode(0).?);
    try std.testing.expectEqualStrings("mantle", gameData.blockCode(1).?);
    try std.testing.expectEqual(null, gameData.blockCode(2));
    try std.testing.expectEqual(null, gameData.blockCode(-1));
    try std.testing.expectEqual(null, gameData.itemCode(0));
    try std.testing.expectEqual(256, gameData.worldHeight);
    try std.testing.expectEqual(110, gameData.seaLevel());
    try std.testing.expectEqual(1024000, gameData.worldWidth);
}

test "world size, name and game version" {
    // Then field 3 = 2,048 (world length), field 13 = "Test" and field 21 = "1.22.7".
    const row = testRow ++ [_]u8{ 0x18, 0x80, 0x10, 0x6a, 0x04, 'T', 'e', 's', 't', 0xaa, 0x01, 0x06, '1', '.', '2', '2', '.', '7' };
    const gameData = try parse(std.testing.allocator, &row);
    defer gameData.deinit();
    try std.testing.expectEqual(2048, gameData.worldLength);
    try std.testing.expectEqual(1024000, gameData.worldWidth);
    try std.testing.expectEqualStrings("Test", gameData.name);
    try std.testing.expectEqualStrings("1.22.7", gameData.gameVersion);
    // A size of 0 is invalid.
    try std.testing.expectError(error.InvalidWorldSize, parse(std.testing.allocator, &.{ 0x08, 0x00 }));
}

test yearProgress {
    // 36.5 days of 24 hours into a year of 12 months of 9 days.
    const gameData: GameData = .{ .arena = undefined, .blockCodes = &.{}, .itemCodes = &.{}, .worldHeight = 256, .totalGameSeconds = 3153600 };
    try std.testing.expectApproxEqAbs(36.5 / 108.0, gameData.yearProgress(), 1e-6);
    // The test row's hours per day, 24.
    const parsed = try parse(std.testing.allocator, &testRow);
    defer parsed.deinit();
    try std.testing.expectEqual(24, parsed.hoursPerDay);
}

test "a world height of 0 or over 512 chunks is invalid" {
    // Field 2 = 0, then field 2 = 16,385.
    try std.testing.expectError(error.InvalidWorldHeight, parse(std.testing.allocator, &.{ 0x10, 0x00 }));
    try std.testing.expectError(error.InvalidWorldHeight, parse(std.testing.allocator, &.{ 0x10, 0x81, 0x80, 0x01 }));
}

test seaLevel {
    // The wiki's table: https://wiki.vintagestory.at/Sea_level
    for ([_][2]u32{ .{ 128, 55 }, .{ 192, 82 }, .{ 256, 110 }, .{ 320, 138 }, .{ 384, 165 }, .{ 448, 193 }, .{ 512, 220 } }) |row| {
        const gameData: GameData = .{ .arena = undefined, .blockCodes = &.{}, .itemCodes = &.{}, .worldHeight = row[0] };
        try std.testing.expectEqual(row[1], gameData.seaLevel());
    }
}
