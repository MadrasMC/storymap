//! Vintage Story's asset JSON, which is lenient: keys may be unquoted, strings single-quoted,
//! numbers written as `.5`, and there may be comments and trailing commas
//! (docs/rendering.md#what-the-renderer-needs-from-them). Everything is allocated in an arena.
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    /// As written, e.g. "0", ".5" or "-2e3".
    number: []const u8,
    string: []const u8,
    array: []const Value,
    /// In the order written. Keys keep their case: the game reads most of them ignoring case,
    /// as `get` does.
    object: []const Field,

    /// The property `key` of an object, ignoring case, or null. A key written twice counts
    /// as its last value.
    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .object) return null;
        var i = self.object.len;
        while (i > 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.object[i].key, key)) return self.object[i].value;
        }
        return null;
    }

    pub fn asString(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }

    pub fn asArray(self: Value) []const Value {
        return if (self == .array) self.array else &.{};
    }

    /// The array property `key`, ignoring case, or none.
    pub fn getArray(self: Value, key: []const u8) []const Value {
        return (self.get(key) orelse return &.{}).asArray();
    }

    /// False for `false` and for a number that is 0, as the game's JSON library reads them.
    pub fn isFalse(self: Value) bool {
        return switch (self) {
            .bool => |b| !b,
            .number => |n| (std.fmt.parseFloat(f64, n) catch return false) == 0,
            else => false,
        };
    }
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

pub const Error = error{ InvalidJson, TooDeep, OutOfMemory };

/// Parses `text`, allocating with `arena`; strings point into `text` where they have no
/// escapes, so it must outlive the result.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Value {
    var parser: Parser = .{ .arena = arena, .text = text };
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) parser.pos = 3;
    const value = try parser.value(0);
    try parser.skip();
    if (parser.pos != text.len) return error.InvalidJson;
    return value;
}

/// The object `over` laid over `base`, as the game merges a block type over the one it
/// inherits from: properties match ignoring case, objects merge, anything else replaces.
pub fn merge(arena: std.mem.Allocator, base: Value, over: Value) error{OutOfMemory}!Value {
    if (base != .object or over != .object) return over;
    var fields: std.ArrayList(Field) = .empty;
    try fields.appendSlice(arena, base.object);
    for (over.object) |field| {
        for (fields.items, 0..) |*existing, i| {
            if (!std.ascii.eqlIgnoreCase(existing.key, field.key)) continue;
            if (existing.value == .object and field.value == .object) {
                existing.value = try merge(arena, existing.value, field.value);
            } else {
                _ = fields.orderedRemove(i);
                try fields.append(arena, field);
            }
            break;
        } else try fields.append(arena, field);
    }
    return .{ .object = fields.items };
}

const maxDepth = 128;

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    /// Skips whitespace and comments.
    fn skip(self: *Parser) Error!void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, self.text[self.pos..], "//")) {
                self.pos = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            } else if (std.mem.startsWith(u8, self.text[self.pos..], "/*")) {
                const end = std.mem.indexOfPos(u8, self.text, self.pos + 2, "*/") orelse return error.InvalidJson;
                self.pos = end + 2;
            } else break;
        }
    }

    fn value(self: *Parser, depth: usize) Error!Value {
        if (depth == maxDepth) return error.TooDeep;
        try self.skip();
        if (self.pos == self.text.len) return error.InvalidJson;
        switch (self.text[self.pos]) {
            '{' => return self.object(depth),
            '[' => return self.array(depth),
            '"', '\'' => return .{ .string = try self.quoted() },
            else => {
                const word = try self.bare();
                if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
                if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
                if (std.mem.eql(u8, word, "null")) return .null;
                if (isNumber(word)) return .{ .number = word };
                return .{ .string = word };
            },
        }
    }

    fn object(self: *Parser, depth: usize) Error!Value {
        self.pos += 1;
        var fields: std.ArrayList(Field) = .empty;
        while (true) {
            try self.skip();
            if (self.pos == self.text.len) return error.InvalidJson;
            if (self.text[self.pos] == '}') break;
            const key = switch (self.text[self.pos]) {
                '"', '\'' => try self.quoted(),
                else => try self.bare(),
            };
            try self.skip();
            if (self.pos == self.text.len or self.text[self.pos] != ':') return error.InvalidJson;
            self.pos += 1;
            try fields.append(self.arena, .{ .key = key, .value = try self.value(depth + 1) });
            if (!try self.separator('}')) break;
        }
        self.pos += 1;
        return .{ .object = fields.items };
    }

    fn array(self: *Parser, depth: usize) Error!Value {
        self.pos += 1;
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            try self.skip();
            if (self.pos == self.text.len) return error.InvalidJson;
            if (self.text[self.pos] == ']') break;
            try items.append(self.arena, try self.value(depth + 1));
            if (!try self.separator(']')) break;
        }
        self.pos += 1;
        return .{ .array = items.items };
    }

    /// After a value: a comma, which may also come before the closing bracket, or the
    /// closing bracket itself. Returns whether more may follow, and leaves the position on
    /// the closing bracket otherwise.
    fn separator(self: *Parser, close: u8) Error!bool {
        try self.skip();
        if (self.pos == self.text.len) return error.InvalidJson;
        if (self.text[self.pos] == ',') {
            self.pos += 1;
            return true;
        }
        if (self.text[self.pos] != close) return error.InvalidJson;
        return false;
    }

    /// A string in double or single quotes.
    fn quoted(self: *Parser) Error![]const u8 {
        const quote = self.text[self.pos];
        const start = self.pos + 1;
        var i = start;
        var escaped = false;
        while (i < self.text.len and self.text[i] != quote) : (i += 1) {
            if (self.text[i] == '\\') {
                escaped = true;
                i += 1;
            }
        }
        if (i >= self.text.len) return error.InvalidJson;
        self.pos = i + 1;
        const raw = self.text[start..i];
        if (!escaped) return raw;
        return unescape(self.arena, raw);
    }

    /// An unquoted key or value: up to whitespace, punctuation, a quote or a comment.
    fn bare(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            if (std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, "{}[]:,\"'", c) != null) break;
            if (c == '/' and self.pos + 1 < self.text.len and (self.text[self.pos + 1] == '/' or self.text[self.pos + 1] == '*')) break;
        }
        if (self.pos == start) return error.InvalidJson;
        return self.text[start..self.pos];
    }
};

fn isNumber(word: []const u8) bool {
    var rest = word;
    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) rest = rest[1..];
    if (rest.len == 0) return false;
    var digits = false;
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) digits = true;
    if (i < rest.len and rest[i] == '.') {
        i += 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) digits = true;
    }
    if (!digits) return false;
    if (i < rest.len and (rest[i] == 'e' or rest[i] == 'E')) {
        i += 1;
        if (i < rest.len and (rest[i] == '-' or rest[i] == '+')) i += 1;
        const exponent = i;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
        if (i == exponent) return false;
    }
    return i == rest.len;
}

fn unescape(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\') {
            out.appendAssumeCapacity(raw[i]);
            continue;
        }
        i += 1;
        if (i == raw.len) return error.InvalidJson;
        switch (raw[i]) {
            'n' => out.appendAssumeCapacity('\n'),
            't' => out.appendAssumeCapacity('\t'),
            'r' => out.appendAssumeCapacity('\r'),
            'b' => out.appendAssumeCapacity(8),
            'f' => out.appendAssumeCapacity(12),
            'u' => {
                if (i + 5 > raw.len) return error.InvalidJson;
                const code = std.fmt.parseInt(u21, raw[i + 1 .. i + 5], 16) catch return error.InvalidJson;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidJson;
                try out.appendSlice(arena, buffer[0..len]);
                i += 4;
            },
            else => |c| out.appendAssumeCapacity(c),
        }
    }
    return out.items;
}

test "lenient JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{
        \\    code: "rock", // a comment
        \\    /* another */ enabled: 0,
        \\    'quoted': 'it\'s',
        \\    variantgroups: [ { code: "rock", loadFromProperties: "block/rock" }, ],
        \\    scale: .5, "Path": block/stone/rock*,
        \\    "escaped": "a\"bé",
        \\}
    ;
    const value = try parse(arena.allocator(), text);
    try std.testing.expectEqualStrings("rock", value.get("CODE").?.asString().?);
    try std.testing.expect(value.get("enabled").?.isFalse());
    try std.testing.expectEqualStrings("it's", value.get("quoted").?.asString().?);
    const groups = value.get("variantGroups").?.asArray();
    try std.testing.expectEqual(1, groups.len);
    try std.testing.expectEqualStrings("block/rock", groups[0].get("loadfromproperties").?.asString().?);
    try std.testing.expectEqualStrings(".5", value.get("scale").?.number);
    try std.testing.expectEqualStrings("block/stone/rock*", value.get("path").?.asString().?);
    try std.testing.expectEqualStrings("a\"b\u{e9}", value.get("escaped").?.asString().?);
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "{ a: 1"));
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "{ a 1 }"));
}

test merge {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const base = try parse(arena.allocator(), "{ code: 'a', textures: { all: 'x', side: 'y' }, list: [1, 2] }");
    const over = try parse(arena.allocator(), "{ Code: 'b', Textures: { all: 'z' }, list: [3] }");
    const merged = try merge(arena.allocator(), base, over);
    try std.testing.expectEqualStrings("b", merged.get("code").?.asString().?);
    try std.testing.expectEqualStrings("z", merged.get("textures").?.get("all").?.asString().?);
    try std.testing.expectEqualStrings("y", merged.get("textures").?.get("side").?.asString().?);
    try std.testing.expectEqual(1, merged.get("list").?.asArray().len);
}
