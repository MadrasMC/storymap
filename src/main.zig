const std = @import("std");
const sqlite = @import("sqlite");
const ProtoBuf = @import("ProtoBuf.zig");

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
        \\SELECT position, data FROM chunk ORDER BY position ASC;
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const chunks = try stmt.all(struct {
        position: u64,
        data: []const u8,
    }, ally, .{}, .{});
    defer ally.free(chunks);

    var field_sizes = [_]u64{0} ** 16;

    for (chunks) |c| {
        const position = c.position;
        const chunk = Chunk.from(position);

        std.debug.print("{}, {}, {}\n", .{ chunk.position.x, chunk.position.y, chunk.position.z });
        var data_stmt = try db.prepare("SELECT data FROM chunk WHERE position = ?");
        defer data_stmt.deinit();

        var chunk_field_sizes = [_]u64{0} ** 16;

        const data = c.data;
        defer ally.free(data);
        var parser = ProtoBuf{ .buf = data };
        while (parser.next()) |msg| {
            if (msg.data == .LEN) {
                chunk_field_sizes[msg.field_number - 1] += msg.data.LEN.len;
                // msg.debugPrint();
            }
        }

        for (chunk_field_sizes, 0..) |size, i| {
            if (size > field_sizes[i]) {
                field_sizes[i] = size;
            }
        }
    }
    for (1.., field_sizes) |i, size| if (size != 0) std.debug.print("{}: {}\n", .{ i, size });
}
