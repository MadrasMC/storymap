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
        var data_stmt = try db.prepare("SELECT data FROM chunk WHERE position = ?");
        defer data_stmt.deinit();

        const datas = try data_stmt.all([]const u8, ally, .{}, .{ .position = position });
        defer {
            for (datas) |data| ally.free(data);
            ally.free(datas);
        }

        var protoscope = std.ChildProcess.init(&.{ "protoscope", "-explicit-length-prefixes" }, ally);
        protoscope.stdin_behavior = .Pipe;
        protoscope.stdout_behavior = .Pipe;
        try protoscope.spawn();
        try protoscope.stdin.?.writeAll(datas[0]);
        protoscope.stdin.?.close();
        var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
        try fifo.pump(protoscope.stdout.?, std.io.getStdOut().writer());
    }
}
