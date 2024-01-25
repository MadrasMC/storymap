const std = @import("std");
const sqlite = @import("sqlite");

const Chunk = struct {
    pub const Coords = packed struct(u64) {
        x: u27,
        z: u27,
        y: u10,
        fn from(position: u64) Coords {
            return @bitCast(position);
        }
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const ally = gpa.allocator();
    const args = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, args);

    const dbPath = switch (args.len) {
        0, 1 => return error.NotEnoughArgs,
        2 => args[1],
        else => return error.TooManyArgs,
    };

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = dbPath },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .MultiThread,
    });

    const query =
        \\SELECT position FROM chunk ORDER BY position ASC;
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const positions = try stmt.all(u64, ally, .{}, .{});
    defer ally.free(positions);

    for (positions) |position| {
        const chunk = Chunk.Coords.from(position);
        std.debug.print("{}, {}, {}\n", .{ chunk.x, chunk.y, chunk.z });
    }
}
