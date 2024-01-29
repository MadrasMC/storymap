pub const Position = packed struct(u64) {
    x: u27,
    z: u27,
    y: u10,
};

position: Position,

pub fn from(position: u64) @This() {
    return .{ .position = @bitCast(position) };
}
