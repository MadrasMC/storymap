const std = @import("std");
const DB = @import("sqlite.zig");
const s = @import("sqlite3");
const Chunk = @import("Chunk.zig");
const ProtoBuf = @import("ProtoBuf.zig");
const BlockEntity = @import("BlockEntity.zig");
const VS = @import("Compression.zig");
const extract = @import("extract.zig");
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

    const stmt = try db.prepare("SELECT position, data FROM chunk;");
    defer stmt.finalize();

    while (stmt.step()) {
        const chunk = try Chunk.from(allocator, stmt.column(u64, 0), stmt.column([]const u8, 1));
        defer chunk.deinit();

        // std.debug.print("{f}\n", .{chunk});

        if (chunk.blockPalette == null) continue; // all air

        const left = (chunk.position.x - min_x) * 32;
        const up = (chunk.position.z - min_z) * 32;

        for (0..32) |z| for (0..32) |x| {
            const column = &top[(up + z) * width + left + x];
            // Walk down from the top of the chunk and stop at the first solid block.
            for (0..32) |i| {
                const y = 31 - i;
                if (chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)) == 0) continue;
                const world_y: u16 = @intCast(@as(usize, chunk.position.y) * 32 + y);
                if (column.* == null or column.*.? < world_y) column.* = world_y;
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

test {
    _ = ProtoBuf;
    _ = VS;
    _ = Chunk;
    _ = DB;
    _ = extract;
}
