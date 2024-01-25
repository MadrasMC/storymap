const std = @import("std");

const positions = @import("values.zig").list;

const Chunk = struct {
    pub const Coords = packed struct(u64) {
        x: u27,
        z: u27,
        y: u10,
        fn from(position: u64) Chunk.Coords {
            return @as(Chunk.Coords, @bitCast(position));
        }
    };
};

pub fn main() !void {
    for (positions) |position| {
        const chunk = Chunk.Coords.from(position);
        std.debug.print("{}, {}, {}\n", .{ chunk.x, chunk.y, chunk.z });
    }
}
