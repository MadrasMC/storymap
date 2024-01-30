const Chunk = @This();

pub const Position = packed struct(u64) {
    x: u27,
    z: u27,
    y: u10,
};

position: Position,

pub fn from(position: u64) Chunk {
    return .{ .position = @bitCast(position) };
}

pub fn position64(self: Chunk) u64 {
    return @bitCast(self.position);
}
