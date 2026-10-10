const std = @import("std");
const DB = @import("sqlite.zig");
const s = @import("sqlite3");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");
const stb = @import("stb_image_write");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // const args = try std.process.argsAlloc(allocator);
    // defer std.process.argsFree(allocator, args);

    // const dbPath = switch (args.len) {
    //     0, 1 => return error.NotEnoughArgs,
    //     2 => args[1],
    //     else => return error.TooManyArgs,
    // };

    // const dbPath = "sample.vcdbs";
    const dbPath = "content/sample-one-block-spawn.vcdbs";

    const db = try DB.init(dbPath, .{ .readonly = true });
    defer db.deinit();

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

    const image = .{
        .width = 9,
        .height = 9,
    };

    const centre = .{
        .x = 15996,
        .y = 7,
        .z = 15995,
    };

    const chunk_start = Chunk.Position{
        .x = centre.x - image.height / 2,
        .y = 0,
        .z = centre.z - image.width / 2,
    };

    const chunk_end = Chunk.Position{
        .x = centre.x + image.height / 2,
        .y = 10,
        .z = centre.z + image.width / 2,
    };

    std.debug.print("\nRange: ({}, {}, {}) to ({}, {}, {})\n", .{ chunk_start.x, chunk_start.y, chunk_start.z, chunk_end.x, chunk_end.y, chunk_end.z });

    var positions: [image.height * image.width * 11]u128 = @splat(0);

    for (chunk_start.x..chunk_end.x) |x| {
        for (chunk_end.z..chunk_end.z) |z| {
            for (0..11) |y| {
                positions[(x - (chunk_start.x)) * (z - (chunk_start.z)) * y] = Chunk.Position.position64(.{ .x = @truncate(x), .y = @truncate(y), .z = @truncate(z) });
            }
        }
    }

    var pixel_data: [(image.height) * 32][(image.width) * 32]u32 = undefined;
    for (&pixel_data) |*z| for (z) |*x| {
        x.* = 0xFF000000;
    };

    var highest_chunk = Chunk.Position{ .x = 0, .y = 0, .z = 0 };
    var lowest_chunk = Chunk.Position{ .x = 0, .y = 0, .z = 0 };
    var highest_y: u64 = 0;

    while (stmt.step()) {
        const position = stmt.column(u64, 0);
        const data = stmt.column([]const u8, 1);

        const chunk = try Chunk.from(allocator, position, data);
        defer chunk.deinit();

        if (chunk.position.x > highest_chunk.x and chunk.position.z > highest_chunk.z and chunk.position.y > highest_chunk.y) {
            highest_chunk = chunk.position;
        }

        if (chunk.position.x < lowest_chunk.x and chunk.position.z < lowest_chunk.z and chunk.position.y < lowest_chunk.y) {
            lowest_chunk = chunk.position;
        }

        // std.debug.print("{f}\n", .{chunk});

        if (within(chunk.position.x, chunk_start.x, chunk_end.x) and
            within(chunk.position.z, chunk_start.z, chunk_end.z))
        {
            if (chunk.blocks) |blocks| if (blocks.len > 0) for (blocks, 0..) |layer, height| for (layer, 0..) |block, i| {
                if (block == 0) continue;

                const Chunk64 = struct {
                    x: u64,
                    z: u64,
                    y: u64,
                };

                // chunk position within the image
                const chunk_normalised = Chunk64{
                    .x = chunk.position.x - chunk_start.x,
                    .z = chunk.position.z - chunk_start.z,
                    .y = chunk.position.y,
                };

                // block coords within this chunk
                const chunk_block = Chunk64{
                    .x = (i % 32),
                    .z = (i / 32),
                    .y = height,
                };

                // block coords within the image
                const img_block = Chunk64{
                    .x = chunk_normalised.x * 32 + chunk_block.x,
                    .z = chunk_normalised.z * 32 + chunk_block.z,
                    .y = chunk_normalised.y * 32 + chunk_block.y,
                };

                if (img_block.y > highest_y) {
                    highest_y = img_block.y;
                }

                const pixel = &pixel_data[img_block.z][img_block.x];

                const shift = .{
                    .r = 0, //  0000XX; shift left by 0 bits
                    .g = 8, //  00XX00; shift left by 8 bits
                    .b = 16, // XX0000; shift left by 16 bits
                };

                // 132 is the highest non-air block we know of, so divide by it to get a value between 0 and 1
                const brightnessF: f64 = @as(f64, @floatFromInt(img_block.y)) / 132;
                const brightness: u8 = @intFromFloat(brightnessF * 255);
                const new_color = 0xFF000000 + (@as(u32, brightness) << shift.g);
                if (block != 0 and @as(u8, @intCast((pixel.* >> shift.g) & 0xFF)) < brightness) {
                    pixel.* = new_color;
                }
            };
        }
    }

    std.debug.print("Highest chunk: ({}, {}, {})\n", .{ highest_chunk.x, highest_chunk.y, highest_chunk.z });
    std.debug.print("Lowest chunk: ({}, {}, {})\n", .{ lowest_chunk.x, lowest_chunk.y, lowest_chunk.z });
    std.debug.print("Highest y: {}\n", .{highest_y});

    std.debug.assert(stb.stbi_write_png("out.png", 32 * image.width, 32 * image.width, 4, &pixel_data, 32 * image.width * @sizeOf(u32)) != 0);
}

fn within(x: anytype, min: anytype, max: anytype) bool {
    return x >= min and x <= max;
}

test {
    _ = ProtoBuf;
    _ = VS;
}
