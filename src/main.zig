const std = @import("std");
const DB = @import("sqlite.zig");
const s = @import("sqlite3");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");
const extract = @import("extract.zig");
const GameData = @import("GameData.zig");
const stb = @import("stb_image_write");

const usage =
    \\usage: storymap <save.vcdbs> [output.png]
    \\       storymap extract-assets <output folder> [--game <folder>] [--data <folder>]
    \\
    \\Renders a top-down heightmap of a Vintage Story save to output.png,
    \\or out.png when no output path is given.
    \\Run extract-assets without arguments for its options.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "extract-assets")) return extract.run(init, args[2..]);
    if (args.len < 2 or args.len > 3) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
    const dbPath = args[1];
    const outPath = if (args.len == 3) args[2] else "out.png";

    // Never write next to the save: it may be in the game's own Saves folder.
    const db = DB.initImmutable(allocator, dbPath) catch |err| {
        std.debug.print("storymap: can't open {s} ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer db.deinit();

    // The immutable open ignores the save's -wal file. A non-empty one holds changes the
    // game hasn't written into the save yet, because it's still running or it crashed.
    const walPath = try std.mem.concat(allocator, u8, &.{ dbPath, "-wal" });
    defer allocator.free(walPath);
    if (std.Io.Dir.cwd().statFile(init.io, walPath, .{})) |wal| {
        if (wal.size > 0) std.debug.print("storymap: {s} has unsaved changes (is the game running?); they won't be on the map\n", .{dbPath});
    } else |_| {}

    // spawn chunk of sample.vcdbs
    _ = Chunk.Position.position64(.{ .x = 15997, .y = 3, .z = 16000 });

    // empty chunk in sample-one-block-spawn.vcdbs
    _ = Chunk.Position.position64(.{ .x = 15995, .y = 5, .z = 15999 });

    // chunk with one block in sample-one-block-spawn.vcdbs
    _ = Chunk.Position.position64(.{ .x = 15995, .y = 4, .z = 15999 });

    // The image covers every chunk in the save. Chunk x is the low 27 bits of
    // `position` and z the next 27 (see Chunk.Position).
    const bounds = db.prepare(
        \\SELECT MIN(position & 134217727), MAX(position & 134217727),
        \\       MIN((position >> 27) & 134217727), MAX((position >> 27) & 134217727)
        \\FROM chunk;
    ) catch |err| {
        // SQLite opens any file lazily, so this first query is where a wrong file shows up.
        std.debug.print("storymap: {s} isn't a Vintage Story save ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer bounds.finalize();
    if (!bounds.step()) return error.NoChunks;

    // Which block code each numeric block ID stands for, in this save.
    const gameData = GameData.read(allocator, db) catch |err| {
        std.debug.print("storymap: can't read the block list in {s} ({s})\n", .{ dbPath, @errorName(err) });
        std.process.exit(1);
    };
    defer gameData.deinit();
    const min_x: usize = @intCast(bounds.column(u64, 0));
    const max_x: usize = @intCast(bounds.column(u64, 1));
    const min_z: usize = @intCast(bounds.column(u64, 2));
    const max_z: usize = @intCast(bounds.column(u64, 3));

    // One pixel per block column; x goes right (east), z goes down (south).
    const width = (max_x - min_x + 1) * 32;
    const height = (max_z - min_z + 1) * 32;

    // Height of the highest non-air block in each column, or null if there is none.
    const top = try allocator.alloc(?u16, width * height);
    defer allocator.free(top);
    @memset(top, null);
    // The block ID at that height.
    const topBlock = try allocator.alloc(i32, width * height);
    defer allocator.free(topBlock);
    @memset(topBlock, 0);

    const stmt = try db.prepare("SELECT position, data FROM chunk;");
    defer stmt.finalize();

    while (stmt.step()) {
        // One undecodable chunk shouldn't stop the whole map.
        const chunk = Chunk.from(allocator, stmt.column(u64, 0), stmt.column([]const u8, 1)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                const pos: Chunk.Position = @bitCast(stmt.column(u64, 0));
                std.debug.print("storymap: skipping chunk ({}, {}, {}): {s}\n", .{ pos.x, pos.y, pos.z, @errorName(err) });
                continue;
            },
        };
        defer chunk.deinit();

        // std.debug.print("{f}\n", .{chunk});

        if (chunk.blockPalette == null) continue; // all air

        const left = (chunk.position.x - min_x) * 32;
        const up = (chunk.position.z - min_z) * 32;

        for (0..32) |z| for (0..32) |x| {
            const index = (up + z) * width + left + x;
            // Walk down from the top of the chunk and stop at the first solid block.
            for (0..32) |i| {
                const y = 31 - i;
                const block = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (block == 0) continue;
                const world_y: u16 = @intCast(@as(usize, chunk.position.y) * 32 + y);
                if (top[index] == null or top[index].? < world_y) {
                    top[index] = world_y;
                    topBlock[index] = block;
                }
                break;
            }
        };
    }

    var lowest: u16 = std.math.maxInt(u16);
    var highest: u16 = 0;
    for (top) |column| if (column) |y| {
        lowest = @min(lowest, y);
        highest = @max(highest, y);
    };

    std.debug.print("{}x{} blocks, surface y {}..{}\n", .{ width, height, lowest, highest });
    try printSurfaceBlocks(allocator, gameData, top, topBlock);

    // Greyscale by height. The lowest surface is dark grey rather than black, so it
    // stays distinguishable from columns with no blocks at all.
    const pixels = try allocator.alloc(u32, top.len);
    defer allocator.free(pixels);
    for (pixels, top) |*pixel, column| {
        const y = column orelse {
            pixel.* = 0xFF000000;
            continue;
        };
        const shade: u32 = if (highest == lowest) 255 else 32 + @as(u32, y - lowest) * 223 / (highest - lowest);
        pixel.* = 0xFF000000 | (shade << 16) | (shade << 8) | shade;
    }

    if (stb.stbi_write_png(outPath, @intCast(width), @intCast(height), 4, pixels.ptr, @intCast(width * @sizeOf(u32))) == 0) {
        return error.WritePngFailed;
    }
}

/// The five most common top blocks, by name.
fn printSurfaceBlocks(allocator: std.mem.Allocator, gameData: GameData, top: []const ?u16, topBlock: []const i32) !void {
    var counts: std.AutoArrayHashMapUnmanaged(i32, usize) = .empty;
    defer counts.deinit(allocator);
    var columns: usize = 0;
    for (top, topBlock) |column, block| if (column != null) {
        const entry = try counts.getOrPutValue(allocator, block, 0);
        entry.value_ptr.* += 1;
        columns += 1;
    };
    const Context = struct {
        values: []const usize,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.values[a] > ctx.values[b];
        }
    };
    counts.sort(Context{ .values = counts.values() });

    std.debug.print("most common surface blocks:", .{});
    for (counts.keys()[0..@min(5, counts.count())], counts.values()[0..@min(5, counts.count())], 0..) |block, count, i| {
        const percent = count * 100 / columns;
        if (gameData.blockCode(block)) |code| {
            std.debug.print("{s} {s} {}%", .{ if (i == 0) "" else ",", code, percent });
        } else {
            std.debug.print("{s} #{} {}%", .{ if (i == 0) "" else ",", block, percent });
        }
    }
    std.debug.print("\n", .{});
}

test {
    _ = GameData;
    _ = ProtoBuf;
    _ = VS;
    _ = Chunk;
    _ = DB;
    _ = extract;
}
