const std = @import("std");
const sqlite = @import("sqlite");
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

    var db = try sqlite.Db.init(.{ .mode = sqlite.Db.Mode{ .File = dbPath }, .threading_mode = .MultiThread });
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

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const chunks = try stmt.all(struct {
        position: u64,
        data: []const u8,
    }, allocator, .{}, .{});
    defer allocator.free(chunks);

    for (chunks) |c| {
        defer allocator.free(c.data);
        const chunk = try Chunk.from(allocator, c.position, c.data);
        defer chunk.deinit();

        std.debug.print("{}", .{chunk});
    }
}
