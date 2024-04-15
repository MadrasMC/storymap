const std = @import("std");
const DB = @import("sqlite.zig");
const s = @import("sqlite3");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");
const stb = @cImport({
    @cDefine("STB_IMAGE_IMPLEMENTATION", {});
    @cInclude("stb_image.h");
    @cDefine("STB_IMAGE_WRITE_IMPLEMENTATION", {});
    @cDefine("STB_IMAGE_WRITE_STATIC", {});
    @cInclude("stb_image_write.h");
});

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

    const image = .{
        .width = 9,
        .height = 9,
    };

    var positions = [_]u64{0} ** (image.height * image.width * 11);

    for (16005 - image.height / 2..16005 + image.height / 2 + 1) |x| {
        for (16004 - image.width / 2..16004 + image.width / 2 + 1) |z| {
            for (0..11) |y| {
                positions[(x - (16005 - image.height / 2)) * (z - (16004 - image.width / 2)) * y] = Chunk.Position.position64(.{ .x = @truncate(x), .y = @truncate(y), .z = @truncate(z) });
            }
        }
    }

    // spawn chunk of sample.vcdbs
    _ = Chunk.Position.position64(.{ .x = 15997, .y = 3, .z = 16000 });

    // empty chunk in sample-one-block-spawn.vcdbs
    _ = Chunk.Position.position64(.{ .x = 15995, .y = 5, .z = 15999 });

    // chunk with one block in sample-one-block-spawn.vcdbs
    _ = Chunk.Position.position64(.{ .x = 15995, .y = 4, .z = 15999 });

    comptime var query: []const u8 = "SELECT position, data FROM chunk";

    // comptime {
    //     if (positions.len > 0) {
    //         query = std.fmt.comptimePrint("{s} WHERE position = {d}", .{ query, positions[0] });
    //         for (positions[1..]) |p| {
    //             query = std.fmt.comptimePrint("{s} OR position = {d}", .{ query, p });
    //         }
    //     }
    // }
    query = std.fmt.comptimePrint("{s} ORDER BY position ASC;", .{query});

    const stmt = try db.prepare(query);
    defer stmt.finalize();

    var pixel_data = [_]u32{0xFF000000} ** (1024 * image.width * image.height);

    while (stmt.step()) {
        const position = stmt.column(u64, 0);
        const data = stmt.column([]const u8, 1);

        const chunk = try Chunk.from(allocator, position, data);
        defer chunk.deinit();

        // std.debug.print("{}\n", .{chunk});

        if (within(chunk.position.x, 16005 - image.height / 2, 16005 + image.height / 2) and
            within(chunk.position.z, 16004 - image.width / 2, 16004 + image.width / 2))
        {
            if (chunk.blocks) |blocks| if (blocks.len > 0) for (blocks, 0..) |layer, height| for (layer, 0..) |block, i| {
                const O = .{
                    .x = @as(u32, chunk.position.x) - (16005 - image.height / 2),
                    .z = @as(u32, chunk.position.z) - (16004 - image.width / 2),
                    .y = @as(u32, chunk.position.y),
                };
                const pixel = &pixel_data[(O.x * 32 * 32 * image.width) + (O.z * 32) + ((i / 32) * 32 * image.width) + (i % 32)];
                const brightnessF: f64 = @as(f64, @floatFromInt((O.y + 1) * (height + 1))) / 25;
                const C = .{
                    .r = 0,
                    .g = 8,
                    .b = 16,
                };
                const brightness: u8 = @intFromFloat(brightnessF * 255);
                const new_color = 0xFF000000 + (@as(u32, brightness) << C.g);
                if (block != 0 and @as(u8, @intCast((pixel.* >> C.g) & 0xFF)) < brightness) {
                    pixel.* = new_color;
                }
            };
        }
    }

    var filename: [128]u8 = undefined;
    _ = try std.fmt.bufPrintZ(&filename, "out.png", .{});
    std.debug.assert(stb.stbi_write_png(&filename, 32 * image.width, 32 * image.width, 4, &pixel_data, 32 * image.width * @sizeOf(u32)) != 0);
}

fn within(x: anytype, min: anytype, max: anytype) bool {
    return x >= min and x <= max;
}
