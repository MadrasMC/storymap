const std = @import("std");

const c = @import("sqlite3");

const DB = @This();
db: *c.sqlite3,

pub const OpenFlags = packed struct(c_int) {
    readonly: bool = false,
    readwrite: bool = false,
    create: bool = false,
    deleteonclose: bool = false,
    exclusive: bool = false,
    autoproxy: bool = false,
    uri: bool = false,
    memory: bool = false,
    main_db: bool = false,
    temp_db: bool = false,
    transient_db: bool = false,
    main_journal: bool = false,
    temp_journal: bool = false,
    subjournal: bool = false,
    super_journal: bool = false,
    nomutex: bool = false,
    fullmutex: bool = false,
    sharedcache: bool = false,
    privatecache: bool = false,
    wal: bool = false,
    nofollow: bool = false,
    exrescode: bool = false,
    _pad: u10 = 0,
};

pub const OpenError = error{
    misuse,
    nomem,
    cantopen,
};

pub fn init(filename: [*:0]const u8, flags: OpenFlags) !DB {
    var db: ?*c.sqlite3 = null;
    return switch (c.sqlite3_open_v2(
        filename,
        &db,
        @bitCast(flags),
        null,
    )) {
        c.SQLITE_OK => .{ .db = db.? },
        c.SQLITE_NOMEM => OpenError.nomem,
        c.SQLITE_MISUSE => OpenError.misuse,
        c.SQLITE_CANTOPEN => OpenError.cantopen,
        else => |rc| std.debug.panic(
            \\[sqlite3_open_v2]: Unexpected result code: {}
            \\  (See https://sqlite.org/rescode.html)
        , .{rc}),
    };
}

/// Opens a database without writing anything next to it. A plain read-only open of a
/// database in write-ahead-log mode (like a Vintage Story save) still creates `-shm` and
/// `-wal` files beside it; `immutable=1` doesn't, but also ignores any `-wal` file that's
/// already there.
pub fn initImmutable(allocator: std.mem.Allocator, path: []const u8) !DB {
    const uri = try immutableUri(allocator, path);
    defer allocator.free(uri);
    return init(uri, .{ .readonly = true, .uri = true });
}

/// `path` as an SQLite URI with `immutable=1`. See https://sqlite.org/uri.html.
fn immutableUri(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    var uri: std.ArrayList(u8) = .empty;
    errdefer uri.deinit(allocator);
    try uri.appendSlice(allocator, "file:");
    // A Windows drive path needs an empty authority in front of it: file:///C:/...
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        try uri.appendSlice(allocator, "//");
        if (path.len == 2 or (path[2] != '/' and path[2] != '\\')) return error.RelativeDrivePath;
        try uri.append(allocator, '/');
    }
    for (path) |char| switch (char) {
        '\\' => try uri.append(allocator, '/'),
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => try uri.append(allocator, char),
        // Everything else, including spaces, '?', '#', '%' and non-ASCII UTF-8 bytes.
        else => try uri.print(allocator, "%{X:0>2}", .{char}),
    };
    try uri.appendSlice(allocator, "?immutable=1");
    return uri.toOwnedSliceSentinel(allocator, 0);
}

test immutableUri {
    const cases = [_][2][]const u8{
        .{ "content/gloomy cave valley.vcdbs", "file:content/gloomy%20cave%20valley.vcdbs?immutable=1" },
        .{ "C:\\Users\\mkr\\Saves\\a.vcdbs", "file:///C:/Users/mkr/Saves/a.vcdbs?immutable=1" },
        .{ "/home/mkr/save #1?.vcdbs", "file:/home/mkr/save%20%231%3F.vcdbs?immutable=1" },
        .{ "Welt 100%.vcdbs", "file:Welt%20100%25.vcdbs?immutable=1" },
        .{ "ü.vcdbs", "file:%C3%BC.vcdbs?immutable=1" },
    };
    for (cases) |case| {
        const uri = try immutableUri(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(uri);
        try std.testing.expectEqualStrings(case[1], uri);
    }
    try std.testing.expectError(error.RelativeDrivePath, immutableUri(std.testing.allocator, "C:save.vcdbs"));
}

pub fn deinit(self: DB) void {
    // sqlite3_close_v2 can only return SQLITE_MISUSE or SQLITE_OK
    std.debug.assert(c.sqlite3_close_v2(self.db) == c.SQLITE_OK);
}

pub const Stmt = struct {
    stmt: *c.sqlite3_stmt,

    pub fn step(self: Stmt) bool {
        return c.sqlite3_step(self.stmt) == c.SQLITE_ROW;
    }

    pub fn column(self: Stmt, comptime T: type, col: c_int) T {
        return switch (T) {
            u64 => @bitCast(self.column(i64, col)),
            i64 => c.sqlite3_column_int64(self.stmt, col),
            []const u8 => {
                const data_ptr: [*]const u8 = @ptrCast(
                    c.sqlite3_column_blob(self.stmt, col),
                );
                const data_len: usize = @intCast(
                    c.sqlite3_column_bytes(self.stmt, col),
                );
                return data_ptr[0..data_len];
            },
            else => @compileError("[stmt.column(" ++ @typeName(T) ++ ")]: Unimplemented"),
        };
    }

    /// Sets the statement's parameter `index` (from 1, as in `?1`).
    pub fn bind(self: Stmt, index: c_int, value: u64) void {
        // Only fails for an index the statement doesn't have, or while it's running.
        std.debug.assert(c.sqlite3_bind_int64(self.stmt, index, @bitCast(value)) == c.SQLITE_OK);
    }

    /// Makes the statement ready to step again, keeping its parameters.
    pub fn reset(self: Stmt) void {
        // Returns the last step's error, if any; step already reports that by returning false.
        _ = c.sqlite3_reset(self.stmt);
    }

    pub fn finalize(self: Stmt) void {
        std.debug.assert(c.sqlite3_finalize(self.stmt) == c.SQLITE_OK);
    }
};

pub const PrepareError = error{
    @"error",
    nomem,
    interrupt,
    toobig,
    misuse,
    locked_sharedcache,
    notadb,
};

pub fn prepare(self: DB, sql: []const u8) PrepareError!Stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    return switch (c.sqlite3_prepare_v2(
        self.db,
        sql.ptr,
        @intCast(sql.len),
        &stmt,
        null,
    )) {
        c.SQLITE_OK => .{ .stmt = stmt.? },
        c.SQLITE_ERROR => PrepareError.@"error",
        c.SQLITE_NOMEM => PrepareError.nomem,
        c.SQLITE_INTERRUPT => PrepareError.interrupt,
        c.SQLITE_TOOBIG => PrepareError.toobig,
        c.SQLITE_MISUSE => PrepareError.misuse,
        c.SQLITE_LOCKED_SHAREDCACHE => PrepareError.locked_sharedcache,
        c.SQLITE_NOTADB => PrepareError.notadb,
        else => |rc| std.debug.panic(
            \\[sqlite3_prepare_v2]: Unexpected result code: {}
            \\  (See https://sqlite.org/rescode.html)
        , .{rc}),
    };
}
