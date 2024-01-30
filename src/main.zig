const std = @import("std");
const sqlite = @import("sqlite");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const Entity = @import("Entity.zig");

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

    // hardcoded to spawn chunk 54045343012109949 (.{ 15997, 0, 16000 })
    const query =
        \\SELECT position, data FROM chunk WHERE position = 54045343012109949 ORDER BY position ASC;
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const chunks = try stmt.all(struct {
        position: u64,
        data: []const u8,
    }, ally, .{}, .{});
    defer ally.free(chunks);

    for (chunks) |c| {
        const position = c.position;
        const chunk = Chunk.from(position);
        _ = chunk;

        const data = c.data;
        defer ally.free(data);

        var parser = ProtoBuf{ .buf = data };
        while (parser.next()) |msg| {
            if (msg.data == .LEN) {
                // msg.debugPrint();

                if (msg.field_number == 8) {
                    var entity = Entity{ .buf = msg.data.LEN };
                    while (entity.next()) |entry| entry.debugPrint();
                }
            }
        }
    }
}
