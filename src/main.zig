const std = @import("std");
const DB = @import("sqlite.zig");
const s = @import("sqlite3");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // const args = try std.process.argsAlloc(allocator);
    // defer std.process.argsFree(allocator, args);

    // const dbPath = switch (args.len) {
    //     0, 1 => return error.NotEnoughArgs,
    //     2 => args[1],
    //     else => return error.TooManyArgs,
    // };

    const dbPath = "sample.vcdbs";
    // const dbPath = "content/sample-one-block-spawn.vcdbs";

    const db = try DB.init(dbPath, .{ .readonly = true });
    defer db.deinit();

    const positions = comptime [_]u64{
        // spawn chunk of sample.vcdbs
        Chunk.Position.position64(.{ .x = 15997, .y = 3, .z = 16000 }),

        // empty chunk in sample-one-block-spawn.vcdbs
        // Chunk.Position.position64(.{ .x = 15995, .y = 5, .z = 15999 }),

        // chunk with one block in sample-one-block-spawn.vcdbs
        // Chunk.Position.position64(.{ .x = 15995, .y = 4, .z = 15999 }),
    };

    comptime var query: []const u8 = "SELECT position, data FROM chunk";

    comptime {
        if (positions.len > 0) {
            query = std.fmt.comptimePrint("{s} WHERE position = {d}", .{ query, positions[0] });
            for (positions[1..]) |p| {
                query = std.fmt.comptimePrint("{s} OR position = {d}", .{ query, p });
            }
        }

        query = std.fmt.comptimePrint("{s} ORDER BY position ASC;", .{query});
    }

    const stmt = try db.prepare(query);
    defer stmt.finalize();

    while (stmt.step()) {
        const position = stmt.column(u64, 0);
        const data = stmt.column([]const u8, 1);

        const chunk = try Chunk.from(allocator, position, data);
        defer chunk.deinit();

        std.debug.print("{}\n", .{chunk});
    }
}
