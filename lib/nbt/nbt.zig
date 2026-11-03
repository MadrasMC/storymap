//! A reader for NBT, the binary format of Minecraft's saves, uncompressed and read in place:
//! nothing is allocated or copied, and fields are found when they're asked for.
//! https://minecraft.wiki/w/NBT_format
//!
//! Every read is bounds-checked, so truncated or corrupt data is an error, not a crash.
const std = @import("std");

pub const Error = error{
    /// The data ends in the middle of a value.
    EndOfData,
    /// A tag that doesn't exist.
    UnknownTag,
    /// A length below 0.
    InvalidLength,
    /// Nested deeper than `maxDepth`.
    TooDeep,
    /// The data doesn't start with a compound.
    NotCompound,
};

/// As deep as the game itself reads.
pub const maxDepth = 512;

pub const Tag = enum(u8) {
    end,
    byte,
    short,
    int,
    long,
    float,
    double,
    byteArray,
    string,
    list,
    compound,
    intArray,
    longArray,

    fn of(byte: u8) Error!Tag {
        return std.enums.fromInt(Tag, byte) orelse error.UnknownTag;
    }

    /// The bytes of one value of a tag of fixed size.
    fn size(self: Tag) ?usize {
        return switch (self) {
            .end => 0,
            .byte => 1,
            .short => 2,
            .int, .float => 4,
            .long, .double => 8,
            else => null,
        };
    }
};

pub const Value = union(Tag) {
    end,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byteArray: []const u8,
    /// Java's modified UTF-8, which is plain UTF-8 for any text without a NUL or an emoji.
    string: []const u8,
    list: List,
    compound: Compound,
    intArray: Array(i32),
    longArray: Array(i64),
};

/// Big-endian integers, read where they are.
pub fn Array(comptime T: type) type {
    return struct {
        const Self = @This();

        bytes: []const u8,

        pub fn len(self: Self) usize {
            return self.bytes.len / @sizeOf(T);
        }

        /// `i` must be below `len`.
        pub fn get(self: Self, i: usize) T {
            return std.mem.readInt(T, self.bytes[i * @sizeOf(T) ..][0..@sizeOf(T)], .big);
        }
    };
}

pub const List = struct {
    tag: Tag,
    count: usize,
    bytes: []const u8,
    depth: usize,

    pub fn iterator(self: List) Iterator {
        return .{ .list = self, .cursor = .{ .bytes = self.bytes } };
    }

    pub const Iterator = struct {
        list: List,
        cursor: Cursor,
        at: usize = 0,

        pub fn next(self: *Iterator) Error!?Value {
            if (self.at == self.list.count) return null;
            self.at += 1;
            return try self.cursor.value(self.list.tag, self.list.depth);
        }
    };
};

pub const Compound = struct {
    /// Its fields and the end tag after them.
    bytes: []const u8,
    depth: usize,

    pub const Field = struct {
        name: []const u8,
        value: Value,
    };

    pub fn iterator(self: Compound) Iterator {
        return .{ .depth = self.depth, .cursor = .{ .bytes = self.bytes } };
    }

    /// The field called `name`, or null if there's none.
    pub fn get(self: Compound, name: []const u8) Error!?Value {
        var fields = self.iterator();
        while (try fields.next()) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }

    pub const Iterator = struct {
        cursor: Cursor,
        depth: usize,

        pub fn next(self: *Iterator) Error!?Field {
            const tag: Tag = try .of(try self.cursor.byte());
            if (tag == .end) return null;
            const name = try self.cursor.string();
            return .{ .name = name, .value = try self.cursor.value(tag, self.depth) };
        }
    };
};

/// The compound that `bytes`, which must outlive it, hold.
pub fn parse(bytes: []const u8) Error!Compound {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try Tag.of(try cursor.byte()) != .compound) return error.NotCompound;
    _ = try cursor.string();
    return (try cursor.value(.compound, 0)).compound;
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Cursor, length: usize) Error![]const u8 {
        if (length > self.bytes.len - self.at) return error.EndOfData;
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }

    fn byte(self: *Cursor) Error!u8 {
        return (try self.take(1))[0];
    }

    fn int(self: *Cursor, comptime T: type) Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn string(self: *Cursor) Error![]const u8 {
        return self.take(try self.int(u16));
    }

    /// An array of values of `size` bytes, after its count.
    fn array(self: *Cursor, size: usize) Error![]const u8 {
        const count = try self.int(i32);
        if (count < 0) return error.InvalidLength;
        const bytes = std.math.mul(usize, @intCast(count), size) catch return error.EndOfData;
        return self.take(bytes);
    }

    fn value(self: *Cursor, tag: Tag, depth: usize) Error!Value {
        return switch (tag) {
            .end => .end,
            .byte => .{ .byte = try self.int(i8) },
            .short => .{ .short = try self.int(i16) },
            .int => .{ .int = try self.int(i32) },
            .long => .{ .long = try self.int(i64) },
            .float => .{ .float = @bitCast(try self.int(u32)) },
            .double => .{ .double = @bitCast(try self.int(u64)) },
            .byteArray => .{ .byteArray = try self.array(1) },
            .string => .{ .string = try self.string() },
            .intArray => .{ .intArray = .{ .bytes = try self.array(4) } },
            .longArray => .{ .longArray = .{ .bytes = try self.array(8) } },
            .list => .{ .list = try self.list(depth) },
            .compound => compound: {
                const start = self.at;
                try self.skipCompound(depth);
                break :compound .{ .compound = .{ .bytes = self.bytes[start..self.at], .depth = depth + 1 } };
            },
        };
    }

    fn list(self: *Cursor, depth: usize) Error!List {
        const tag: Tag = try .of(try self.byte());
        const signed = try self.int(i32);
        // An empty list may give any tag, or a count below 0.
        const count: usize = if (signed < 0) 0 else @intCast(signed);
        const start = self.at;
        try self.skipItems(tag, count, depth);
        return .{ .tag = tag, .count = count, .bytes = self.bytes[start..self.at], .depth = depth + 1 };
    }

    fn skipItems(self: *Cursor, tag: Tag, count: usize, depth: usize) Error!void {
        if (tag.size()) |size| {
            _ = try self.take(std.math.mul(usize, count, size) catch return error.EndOfData);
            return;
        }
        for (0..count) |_| try self.skip(tag, depth);
    }

    fn skipCompound(self: *Cursor, depth: usize) Error!void {
        if (depth >= maxDepth) return error.TooDeep;
        while (true) {
            const tag: Tag = try .of(try self.byte());
            if (tag == .end) return;
            _ = try self.string();
            try self.skip(tag, depth + 1);
        }
    }

    fn skip(self: *Cursor, tag: Tag, depth: usize) Error!void {
        if (depth >= maxDepth) return error.TooDeep;
        if (tag.size()) |size| {
            _ = try self.take(size);
            return;
        }
        switch (tag) {
            .byteArray => _ = try self.array(1),
            .string => _ = try self.string(),
            .intArray => _ = try self.array(4),
            .longArray => _ = try self.array(8),
            .list => {
                const items: Tag = try .of(try self.byte());
                const count = try self.int(i32);
                try self.skipItems(items, if (count < 0) 0 else @intCast(count), depth + 1);
            },
            .compound => try self.skipCompound(depth),
            else => unreachable,
        }
    }
};

/// A root compound named "" with a byte, a string, a long array, a list of compounds, an empty
/// list and a nested compound.
const sample = [_]u8{ 10, 0, 0 } ++
    [_]u8{ 1, 0, 1, 'b', 0xFF } ++
    [_]u8{ 8, 0, 1, 's', 0, 2, 'h', 'i' } ++
    [_]u8{ 12, 0, 1, 'l', 0, 0, 0, 2 } ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 } ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE } ++
    [_]u8{ 9, 0, 1, 'c', 10, 0, 0, 0, 2 } ++ [_]u8{ 3, 0, 1, 'x', 0, 0, 1, 0, 0 } ++ [_]u8{ 3, 0, 1, 'x', 0, 0, 2, 0, 0 } ++
    [_]u8{ 9, 0, 1, 'e', 0, 0xFF, 0xFF, 0xFF, 0xFF } ++
    [_]u8{ 10, 0, 1, 'n', 5, 0, 1, 'f', 0x3F, 0x80, 0, 0, 0 } ++
    [_]u8{0};

test parse {
    const root = try parse(&sample);
    try std.testing.expectEqual(-1, (try root.get("b")).?.byte);
    try std.testing.expectEqualStrings("hi", (try root.get("s")).?.string);
    try std.testing.expectEqual(null, try root.get("missing"));

    const longs = (try root.get("l")).?.longArray;
    try std.testing.expectEqual(2, longs.len());
    try std.testing.expectEqual(1, longs.get(0));
    try std.testing.expectEqual(-2, longs.get(1));

    const list = (try root.get("c")).?.list;
    try std.testing.expectEqual(Tag.compound, list.tag);
    var items = list.iterator();
    try std.testing.expectEqual(256, (try (try items.next()).?.compound.get("x")).?.int);
    try std.testing.expectEqual(512, (try (try items.next()).?.compound.get("x")).?.int);
    try std.testing.expectEqual(null, try items.next());

    var empty = (try root.get("e")).?.list.iterator();
    try std.testing.expectEqual(null, try empty.next());

    const nested = (try root.get("n")).?.compound;
    try std.testing.expectEqual(1.0, (try nested.get("f")).?.float);

    var fields = root.iterator();
    var count: usize = 0;
    while (try fields.next()) |_| count += 1;
    try std.testing.expectEqual(6, count);
}

test "cut short at every length" {
    for (0..sample.len) |length| {
        try std.testing.expectError(error.EndOfData, parse(sample[0..length]));
    }
}

test "invalid data" {
    try std.testing.expectError(error.NotCompound, parse(&.{ 1, 0, 0, 7 }));
    try std.testing.expectError(error.UnknownTag, parse(&.{ 13, 0, 0 }));
    try std.testing.expectError(error.UnknownTag, parse(&.{ 10, 0, 0, 13 }));
    // A long array claiming far more than there is, and one below 0.
    try std.testing.expectError(error.EndOfData, parse(&.{ 10, 0, 0, 12, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF, 0 }));
    try std.testing.expectError(error.InvalidLength, parse(&.{ 10, 0, 0, 12, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0 }));

    // Compounds nested past the limit stop, however deep they go.
    const nest = [_]u8{ 10, 0, 0 };
    var deep: [nest.len * (maxDepth + 2)]u8 = undefined;
    for (0..maxDepth + 2) |i| @memcpy(deep[i * nest.len ..][0..nest.len], &nest);
    try std.testing.expectError(error.TooDeep, parse(&deep));
}
