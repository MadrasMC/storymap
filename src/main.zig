const std = @import("std");
const sqlite = @import("sqlite");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const ally = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const ally2 = arena.allocator();
    const args = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, args);

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
    }, ally2, .{}, .{});
    defer ally2.free(chunks);

    for (chunks) |c| {
        const position = c.position;
        const chunk = Chunk.from(position);
        _ = chunk;

        const data = c.data;
        defer ally2.free(data);

        var parser = ProtoBuf{ .buf = data };
        while (parser.next()) |msg| {
            if (msg.data == .LEN) {
                // if (msg.field_number == 8) {
                //     const blockEntity = BlockEntity.from(msg.data.LEN);
                //     std.debug.print("\nentity type: {s}\npos: {d}, {d}, {d}\nblockCode: {s}\n", .{
                //         blockEntity.class,
                //         blockEntity.position.x,
                //         blockEntity.position.y,
                //         blockEntity.position.z,
                //         blockEntity.blockCode,
                //     });
                // }

                if (msg.field_number != 12 and msg.field_number != 8) {
                    // std.debug.print("Field '{s}':\n", .{Chunk.fieldNames[msg.field_number]});
                    // msg.debugPrint();

                    if (msg.field_number == 1) {
                        // compressed_blocks
                        var blocks: [][]i32 = &.{};
                        var refCount: i32 = 0;
                        var decompress_arena = std.heap.ArenaAllocator.init(ally);
                        defer decompress_arena.deinit();
                        const decompress_allocator = decompress_arena.allocator();
                        const NewArrayStruct = struct {
                            var allocator: std.mem.Allocator = undefined;
                            fn newArray() ![]i32 {
                                return @This().allocator.alloc(i32, 1024);
                            }
                        };
                        NewArrayStruct.allocator = decompress_allocator;
                        const numArray = try VS.Compression.DecompressCombined(decompress_allocator, msg.data.LEN, &blocks, &refCount, &NewArrayStruct.newArray);
                        _ = numArray;
                        std.debug.print("decompressed: {x}\n", .{blocks});
                    }
                }
            }
        }
    }
}
