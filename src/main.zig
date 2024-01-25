const std = @import("std");
const sqlite = @import("sqlite");

const Chunk = struct {
    pub const Coords = packed struct(u64) {
        x: u27,
        z: u27,
        y: u10,
        fn from(position: u64) Chunk.Coords {
            return @as(Chunk.Coords, @bitCast(position));
        }
    };
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var dbPath: [:0]u8 = undefined;
    var found = false;
    for (args, 0..) |arg, i| {
        if (i == 0) {
            continue;
        } else if (i == 1) {
            dbPath = arg;
            found = true;
        } else {
            std.debug.print("too many arguments", .{});
            return error.TooManyArgs;
        }
    }

    if (!found) {
        std.debug.print("not enough arguments", .{});
        return error.NotEnoughArgs;
    }

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

    const positions = try stmt.all(u64, gpa, .{}, .{});

    for (positions) |position| {
        const chunk = Chunk.Coords.from(position);
        std.debug.print("{}, {}, {}\n", .{ chunk.x, chunk.y, chunk.z });
    }
}
