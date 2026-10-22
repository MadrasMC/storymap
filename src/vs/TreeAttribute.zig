//! Vintage Story's binary "tree attribute" format. Layout and sources:
//! docs/save-format/README.md §5.
const TreeAttribute = @This();

const std = @import("std");

entries: []const Entry,

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const ItemStack = struct {
    class: i32,
    id: i32,
    stackSize: i32,
    attributes: TreeAttribute,
};

/// Tags match the type ids in the file (1-16).
pub const Value = union(enum(u8)) {
    int: i32 = 1,
    long: i64 = 2,
    double: f64 = 3,
    float: f32 = 4,
    string: []const u8 = 5,
    tree: TreeAttribute = 6,
    itemStack: ?ItemStack = 7,
    bytes: []const u8 = 8,
    boolean: bool = 9,
    stringArray: []const []const u8 = 10,
    intArray: []const i32 = 11,
    floatArray: []const f32 = 12,
    doubleArray: []const f64 = 13,
    treeArray: []const TreeAttribute = 14,
    longArray: []const i64 = 15,
    boolArray: []const bool = 16,
};

pub const Error = error{ EndOfData, UnknownAttributeType, OutOfMemory };

pub fn get(self: TreeAttribute, key: []const u8) ?Value {
    for (self.entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

pub fn getInt(self: TreeAttribute, key: []const u8) ?i32 {
    const value = self.get(key) orelse return null;
    return if (value == .int) value.int else null;
}

pub fn getString(self: TreeAttribute, key: []const u8) ?[]const u8 {
    const value = self.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn getIntArray(self: TreeAttribute, key: []const u8) ?[]const i32 {
    const value = self.get(key) orelse return null;
    return if (value == .intArray) value.intArray else null;
}

/// Everything is copied into `arena`, so the result outlives the input.
pub fn parse(arena: std.mem.Allocator, reader: *Reader) Error!TreeAttribute {
    // Collected on the stack and copied once at the exact size: a list grown in an arena
    // leaves every outgrown copy behind.
    var stack: [32]Entry = undefined;
    var count: usize = 0;
    var spill: std.ArrayList(Entry) = .empty;
    while (true) {
        const typeId = try reader.byte();
        if (typeId == 0) break;
        const key = try reader.string(arena);
        const entry: Entry = .{ .key = key, .value = try parseValue(arena, reader, typeId) };
        if (count < stack.len) {
            stack[count] = entry;
            count += 1;
        } else {
            if (spill.items.len == 0) try spill.appendSlice(arena, &stack);
            try spill.append(arena, entry);
        }
    }
    if (spill.items.len > 0) return .{ .entries = try spill.toOwnedSlice(arena) };
    return .{ .entries = try arena.dupe(Entry, stack[0..count]) };
}

test "a tree with more entries than the stack holds" {
    // 40 int entries "a0".."a39", then the end of the tree.
    var bytes: [40 * 8 + 1]u8 = undefined;
    for (0..40) |i| {
        const entry = bytes[i * 8 ..][0..8];
        entry.* = .{ 1, 2, 'a', '0' + @as(u8, @intCast(i / 10)), @intCast(i), 0, 0, 0 };
    }
    bytes[40 * 8] = 0;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var reader: Reader = .{ .bytes = &bytes };
    const tree = try parse(arena.allocator(), &reader);
    try std.testing.expectEqual(40, tree.entries.len);
    for (tree.entries, 0..) |entry, i| try std.testing.expectEqual(@as(i32, @intCast(i)), entry.value.int);
}

fn parseValue(arena: std.mem.Allocator, reader: *Reader, typeId: u8) Error!Value {
    return switch (typeId) {
        1 => .{ .int = try reader.int(i32) },
        2 => .{ .long = try reader.int(i64) },
        3 => .{ .double = @bitCast(try reader.int(u64)) },
        4 => .{ .float = @bitCast(try reader.int(u32)) },
        5 => .{ .string = try reader.string(arena) },
        6 => .{ .tree = try parse(arena, reader) },
        7 => .{ .itemStack = if (try reader.byte() != 0) null else .{
            .class = try reader.int(i32),
            .id = try reader.int(i32),
            .stackSize = try reader.int(i32),
            .attributes = try parse(arena, reader),
        } },
        // Byte arrays are the one type with a u16 length rather than an i32 count.
        8 => .{ .bytes = try arena.dupe(u8, try reader.take(try reader.int(u16))) },
        9 => .{ .boolean = try reader.byte() != 0 },
        10 => .{ .stringArray = try parseArray([]const u8, arena, reader) },
        11 => .{ .intArray = try parseArray(i32, arena, reader) },
        12 => .{ .floatArray = try parseArray(f32, arena, reader) },
        13 => .{ .doubleArray = try parseArray(f64, arena, reader) },
        14 => .{ .treeArray = try parseArray(TreeAttribute, arena, reader) },
        15 => .{ .longArray = try parseArray(i64, arena, reader) },
        16 => .{ .boolArray = try parseArray(bool, arena, reader) },
        else => error.UnknownAttributeType,
    };
}

fn parseArray(comptime T: type, arena: std.mem.Allocator, reader: *Reader) Error![]T {
    const count = try reader.int(i32);
    // Every element takes at least one byte, so a larger count can only be corrupt data.
    if (count < 0 or count > reader.bytes.len - reader.pos) return error.EndOfData;
    const items = try arena.alloc(T, @intCast(count));
    for (items) |*item| item.* = switch (T) {
        []const u8 => try reader.string(arena),
        TreeAttribute => try parse(arena, reader),
        bool => try reader.byte() != 0,
        f32 => @bitCast(try reader.int(u32)),
        f64 => @bitCast(try reader.int(u64)),
        else => try reader.int(T),
    };
    return items;
}

/// Little-endian cursor over a byte slice, matching .NET's BinaryReader.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn take(self: *Reader, len: usize) Error![]const u8 {
        if (self.bytes.len - self.pos < len) return error.EndOfData;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn int(self: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    /// A .NET BinaryWriter string: 7-bit varint byte length, then UTF-8.
    pub fn string(self: *Reader, arena: std.mem.Allocator) Error![]const u8 {
        var len: usize = 0;
        var shift: u6 = 0;
        while (true) : (shift += 7) {
            if (shift > 28) return error.EndOfData;
            const b = try self.byte();
            len |= @as(usize, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
        }
        return arena.dupe(u8, try self.take(len));
    }
};

test "a real chiseled block entity" {
    // Field 8 entry from a 1.19.1 save: class "MicroBlock", then its tree.
    const bytes = [_]u8{
        0x0a, 'M',  'i',  'c',  'r',  'o',  'B',  'l',  'o',  'c',  'k',  0x01, 0x04, 'p',  'o',  's',
        'x',  0xf6, 0xce, 0x07, 0x00, 0x01, 0x04, 'p',  'o',  's',  'y',  0x0c, 0x00, 0x00, 0x00, 0x01,
        0x04, 'p',  'o',  's',  'z',  0x2b, 0xce, 0x07, 0x00, 0x05, 0x09, 'b',  'l',  'o',  'c',  'k',
        'C',  'o',  'd',  'e',  0x0a, 'm',  'i',  'c',  'r',  'o',  'b',  'l',  'o',  'c',  'k',  0x0b,
        0x09, 'm',  'a',  't',  'e',  'r',  'i',  'a',  'l',  's',  0x01, 0x00, 0x00, 0x00, 0x74, 0x1a,
        0x00, 0x00, 0x01, 0x08, 'r',  'o',  't',  'a',  't',  'i',  'o',  'n',  0x00, 0xa0, 0x05, 0x00,
        0x0b, 0x07, 'c',  'u',  'b',  'o',  'i',  'd',  's',  0x01, 0x00, 0x00, 0x00, 0x00, 0x70, 0xf7,
        0x00, 0x08, 0x0a, 'e',  'm',  'i',  't',  'S',  'i',  'd',  'e',  'A',  'o',  0x01, 0x00, 0x00,
        0x08, 0x09, 's',  'i',  'd',  'e',  'S',  'o',  'l',  'i',  'd',  0x01, 0x00, 0x00, 0x08, 0x0f,
        's',  'i',  'd',  'e',  'A',  'l',  'm',  'o',  's',  't',  'S',  'o',  'l',  'i',  'd',  0x01,
        0x00, 0x00, 0x05, 0x09, 'b',  'l',  'o',  'c',  'k',  'N',  'a',  'm',  'e',  0x00, 0x00,
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var reader: Reader = .{ .bytes = &bytes };
    try std.testing.expectEqualStrings("MicroBlock", try reader.string(arena.allocator()));
    const tree = try parse(arena.allocator(), &reader);
    try std.testing.expectEqual(bytes.len, reader.pos);
    try std.testing.expectEqual(511734, tree.getInt("posx").?);
    try std.testing.expectEqual(12, tree.getInt("posy").?);
    try std.testing.expectEqualStrings("microblock", tree.getString("blockCode").?);
    try std.testing.expectEqualSlices(i32, &.{6772}, tree.getIntArray("materials").?);
    try std.testing.expectEqual((0 + 360) << 10, tree.getInt("rotation").?);
    try std.testing.expectEqualSlices(i32, &.{0x00f77000}, tree.getIntArray("cuboids").?);
    try std.testing.expectEqualSlices(u8, &.{0}, tree.get("sideSolid").?.bytes);
    try std.testing.expectEqualStrings("", tree.getString("blockName").?);
}

test "truncated input is an error, not a crash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var reader: Reader = .{ .bytes = &.{ 0x0b, 0x01, 'a', 0x05, 0x00, 0x00, 0x00, 0x01 } };
    try std.testing.expectError(error.EndOfData, parse(arena.allocator(), &reader));
}
