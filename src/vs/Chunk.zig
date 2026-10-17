const Chunk = @This();

const std = @import("std");
const ProtoBuf = @import("../ProtoBuf.zig");
const Compression = @import("Compression.zig");
const BlockEntity = @import("BlockEntity.zig");

// NOTE: To keep in sync with the server per game version
pub const fieldNames = [_][]const u8{
    "<unused>",
    "compressed_blocks",
    "compressed_light",
    "compressed_light_sat",
    "<unused>",
    "entities_count",
    "entities_serialized",
    "block_entities_count",
    "block_entities",
    "moddata",
    "lights",
    "serverside_moddata",
    "game_version",
    "empty",
    "decors",
    "saved_compression_version",
    "compressed_liquids",
    "blocks_placed",
    "blocks_removed",
};

pub const Position = packed struct(u64) {
    x: u27,
    z: u27,
    y: u10,

    pub fn position64(self: Position) u64 {
        return @bitCast(self);
    }
    pub fn eql(self: Position, other: Position) bool {
        return self.position64() == other.position64();
    }
};

position: Position = @bitCast(@as(u64, 0)),
/// Solid blocks (field 1).
blocks: Compression.Layer = .{},
/// Liquids (field 16), in the same format.
liquids: Compression.Layer = .{},
/// Points into the `Decoder`'s block entity buffer: valid until its next `decode`.
blockEntities: []BlockEntity = &.{},

/// Returns the block id at chunk-local (x, y, z). 0 is air.
///
/// Blocks are numbered x first, then z, then y. Each block's palette index is split
/// into bits, and bit `b` of every block is stored together in a bit plane: see
/// `Compression.Layer`.
pub fn getBlock(self: *const Chunk, x: u5, y: u5, z: u5) i32 {
    return self.blocks.get((@as(usize, y) * 32 + z) * 32 + x);
}

/// Everything decoding a chunk needs, allocated once (per worker) and reused for every chunk,
/// so decoding itself never allocates.
pub const Decoder = struct {
    decompressor: Compression.Decompressor,
    blockEntityBuffer: []u8,
    blockEntityMemory: std.heap.FixedBufferAllocator,

    /// Room for one chunk's parsed block entities. The busiest chunk in the test saves (a ruin
    /// with 659 chiseled blocks, 134 KB of raw data) needs 615 KB; see docs/rendering.md.
    pub const defaultBlockEntityBytes = 2 << 20;

    pub fn init(allocator: std.mem.Allocator, blockEntityBytes: usize) !Decoder {
        const decompressor: Compression.Decompressor = try .init(allocator);
        errdefer decompressor.deinit(allocator);
        const buffer = try allocator.alloc(u8, blockEntityBytes);
        return .{ .decompressor = decompressor, .blockEntityBuffer = buffer, .blockEntityMemory = .init(buffer) };
    }

    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
        self.decompressor.deinit(allocator);
        allocator.free(self.blockEntityBuffer);
    }

    /// Decodes one chunk record into `chunk`, replacing what was there. On error the chunk
    /// is left empty. Block entities that don't fit in the buffer are skipped with a warning.
    pub fn decode(self: *Decoder, chunk: *Chunk, position: u64, data: []const u8) (ProtoBuf.Error || Compression.Error)!void {
        chunk.position = @bitCast(position);
        chunk.blocks.clear();
        chunk.liquids.clear();
        chunk.blockEntities = &.{};
        self.blockEntityMemory.reset();
        errdefer {
            chunk.blocks.clear();
            chunk.liquids.clear();
            chunk.blockEntities = &.{};
        }

        // Count the block entities first, so their list is allocated once, at the right size.
        var count: usize = 0;
        var counter: ProtoBuf = .{ .buf = data };
        while (try counter.next()) |msg| {
            if (msg.field_number == 8 and msg.data == .LEN) count += 1;
        }
        const arena = self.blockEntityMemory.allocator();
        var none: [0]BlockEntity = .{};
        const entities: []BlockEntity = arena.alloc(BlockEntity, count) catch &none;
        var found: usize = 0;
        var overLimit: usize = count - entities.len;

        var parser: ProtoBuf = .{ .buf = data };
        while (try parser.next()) |msg| {
            if (msg.data != .LEN) continue;
            switch (msg.field_number) {
                1 => try chunk.blocks.decode(self.decompressor, msg.data.LEN),
                16 => try chunk.liquids.decode(self.decompressor, msg.data.LEN),
                8 => {
                    if (found == entities.len) continue;
                    // One unreadable block entity shouldn't stop the whole map.
                    entities[found] = BlockEntity.parse(arena, msg.data.LEN) catch |err| {
                        if (err == error.OutOfMemory) {
                            overLimit += 1;
                        } else {
                            const pos = chunk.position;
                            std.log.warn("chunk ({}, {}, {}): skipping a block entity ({s})", .{ pos.x, pos.y, pos.z, @errorName(err) });
                        }
                        continue;
                    };
                    found += 1;
                },
                else => {},
            }
        }
        if (overLimit > 0) {
            const pos = chunk.position;
            std.log.warn("chunk ({}, {}, {}): skipping {} block entities over the {} KiB limit", .{ pos.x, pos.y, pos.z, overLimit, self.blockEntityBuffer.len / 1024 });
        }
        chunk.blockEntities = entities[0..found];
    }
};

test {
    _ = BlockEntity;
}

test getBlock {
    // palette index 3 (0b11) at (1, 2, 3): block 2145, word 67, bit 1, set in both planes
    // palette index 2 (0b10) at (0, 0, 0): block 0, word 0, bit 0, set in plane 1 only
    const chunk = try std.testing.allocator.create(Chunk);
    defer std.testing.allocator.destroy(chunk);
    chunk.* = .{};
    chunk.blocks.bits = 2;
    @memcpy(chunk.blocks.palette[0..4], &[_]i32{ 0, 5, 7, 9 });
    @memset(chunk.blocks.planes[0..2], @splat(0));
    chunk.blocks.planes[0][67] = 0b10;
    chunk.blocks.planes[1][67] = 0b10;
    chunk.blocks.planes[1][0] = 0b1;
    try std.testing.expectEqual(9, chunk.getBlock(1, 2, 3));
    try std.testing.expectEqual(7, chunk.getBlock(0, 0, 0));
    try std.testing.expectEqual(0, chunk.getBlock(1, 0, 0));
}

/// A chunk record for the decoder tests: field 1 holds the one-block layer from the 1.19
/// sample, field 8 one small block entity.
const testRecord = [_]u8{ 0x0a, testLayer.len } ++ testLayer ++ [_]u8{ 0x42, testEntity.len } ++ testEntity;

const testLayer = [_]u8{
    0xf8, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xa4, 0x00, 0x00, 0x00, 0x28, 0xb5, 0x2f, 0xfd,
    0x60, 0x00, 0x0f, 0x8d, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x02, 0x00,
    0x32, 0x04, 0xfe, 0x08, 0x5e, 0x01, 0x22,
};

/// Class "X", then posx/posy/posz 1/2/3 and blockCode "a", then the end of the tree.
const testEntity = [_]u8{ 0x01, 'X' } ++
    [_]u8{ 0x01, 0x04, 'p', 'o', 's', 'x', 1, 0, 0, 0 } ++
    [_]u8{ 0x01, 0x04, 'p', 'o', 's', 'y', 2, 0, 0, 0 } ++
    [_]u8{ 0x01, 0x04, 'p', 'o', 's', 'z', 3, 0, 0, 0 } ++
    [_]u8{ 0x05, 0x09, 'b', 'l', 'o', 'c', 'k', 'C', 'o', 'd', 'e', 0x01, 'a' } ++
    [_]u8{0x00};

test "a decoder is reused across chunks without allocating" {
    var decoder: Decoder = try .init(std.testing.allocator, Decoder.defaultBlockEntityBytes);
    defer decoder.deinit(std.testing.allocator);
    const chunk = try std.testing.allocator.create(Chunk);
    defer std.testing.allocator.destroy(chunk);
    chunk.* = .{};

    try decoder.decode(chunk, 0, &testRecord);
    try std.testing.expectEqual(164, chunk.getBlock(5, 7, 18));
    try std.testing.expectEqual(1, chunk.blockEntities.len);
    try std.testing.expectEqualStrings("a", chunk.blockEntities[0].blockCode);

    // The next chunk replaces everything: here an empty record.
    try decoder.decode(chunk, 1, &.{});
    try std.testing.expectEqual(0, chunk.blocks.bits);
    try std.testing.expectEqual(0, chunk.getBlock(5, 7, 18));
    try std.testing.expectEqual(0, chunk.blockEntities.len);
}

test "block entities over the limit are skipped, the blocks still decode" {
    // Room for the list but not for the entity's own data.
    var decoder: Decoder = try .init(std.testing.allocator, @sizeOf(BlockEntity) + 16);
    defer decoder.deinit(std.testing.allocator);
    const chunk = try std.testing.allocator.create(Chunk);
    defer std.testing.allocator.destroy(chunk);
    chunk.* = .{};
    try decoder.decode(chunk, 0, &testRecord);
    try std.testing.expectEqual(164, chunk.getBlock(5, 7, 18));
    try std.testing.expectEqual(0, chunk.blockEntities.len);
}

pub fn format(self: *const Chunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Chunk(x: {[x]}, z: {[z]}, y: {[y]}):\n", self.position);
    try formatLayer(&self.blocks, "Blocks", writer);
    try formatLayer(&self.liquids, "Liquids", writer);
    try writer.print("Block entities:\n", .{});
    for (self.blockEntities) |blockEntity| {
        try writer.print("{f}\n", .{blockEntity});
    }
}

/// The palette, then each plane with runs of zero words collapsed.
fn formatLayer(layer: *const Compression.Layer, name: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{s} palette: {any}\n", .{ name, layer.palette[0 .. @as(usize, 1) << layer.bits] });
    for (layer.planes[0..layer.bits], 0..) |*plane, i| {
        try writer.print("{s} plane {}: {{ ", .{ name, i });
        var same: usize = 0;
        var first = true;
        for (plane) |word| {
            if (word == 0) {
                same += 1;
                continue;
            }
            if (same > 0) {
                try writer.print("{s}\x1b[30m{} x \x1b[32m0\x1b[0m", .{ if (first) "" else ", ", same });
                first = false;
                same = 0;
            }
            try writer.print("{s}\x1b[32m{}\x1b[0m", .{ if (first) "" else ", ", word });
            first = false;
        }
        if (same > 0) try writer.print("{s}\x1b[30m{} x \x1b[32m0\x1b[0m", .{ if (first) "" else ", ", same });
        try writer.print(" }}\n", .{});
    }
}
