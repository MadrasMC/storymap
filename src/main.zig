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
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const dbPath = switch (args.len) {
        0, 1 => return error.NotEnoughArgs,
        2 => args[1],
        else => return error.TooManyArgs,
    };

    var db = try sqlite.Db.init(.{ .mode = sqlite.Db.Mode{ .File = dbPath }, .threading_mode = .MultiThread });
    defer db.deinit();

    // hardcoded to spawn chunk 54045343012109949 (.{ 15997, 3, 16000 })
    const query =
        \\SELECT position, data FROM chunk WHERE position = 54045343012109949 ORDER BY position ASC;
    ;

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
