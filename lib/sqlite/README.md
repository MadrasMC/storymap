# sqlite

A small wrapper over SQLite's C API for Zig 0.17: opening a database, and stepping through the rows of a prepared statement. The module is the database type itself.

It needs the SQLite amalgamation built and translated as the module `sqlite3` (see `build.zig`).

## Example

```zig
const DB = @import("sqlite");

const db = try DB.initImmutable(allocator, "data/notes.db");
defer db.deinit();
const stmt = try db.prepare("SELECT id, body FROM note;");
defer stmt.finalize();
while (stmt.step()) {
    const id = stmt.column(u64, 0);
    const body = stmt.column([]const u8, 1);
    // ...
}
```

## API

| name | contents |
| --- | --- |
| `init(filename, flags)` | opens a database with `OpenFlags`, SQLite's `SQLITE_OPEN_*` flags |
| `initImmutable(allocator, path)` | opens a database read-only without writing anything next to it (see 1) |
| `deinit()` | closes it |
| `prepare(sql)` | a `Stmt` for one statement |
| `Stmt.step()` | moves to the next row; false after the last one, or on an error |
| `Stmt.column(T, index)` | a column of the current row, as `u64`, `i64` or `[]const u8` (valid until the next step) |
| `Stmt.bind(index, value)` | binds a `u64` to a parameter, from 1 |
| `Stmt.reset()` | runs the statement again from the start, keeping its bindings |
| `Stmt.finalize()` | frees it |

## 1. Immutable opens

A read-only open of a database in write-ahead-log mode still creates `-shm` and `-wal` files beside it. `initImmutable` opens the path as a URI with `immutable=1`, which doesn't, but which also ignores any `-wal` file already there: changes not yet checkpointed into the database aren't seen. The path is escaped for the URI, Windows drive paths included; a drive-relative path such as `C:a.db` is `error.RelativeDrivePath`.
