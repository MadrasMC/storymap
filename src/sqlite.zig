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
        else => |rc| std.debug.panic(
            \\[sqlite3_open_v2]: Unexpected result code: {}
            \\  (See https://sqlite.org/rescode.html)
        , .{rc}),
    };
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
        else => |rc| std.debug.panic(
            \\[sqlite3_prepare_v2]: Unexpected result code: {}
            \\  (See https://sqlite.org/rescode.html)
        , .{rc}),
    };
}
