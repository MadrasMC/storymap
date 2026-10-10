//! One block entity (a chunk's field 8 entry): its class name, then a tree attribute.
//! See docs/save-format/README.md §5.
const BlockEntity = @This();

const std = @import("std");
const TreeAttribute = @import("TreeAttribute.zig");

const Position = struct {
    x: i32,
    y: i32,
    z: i32,
};

class: []const u8,
/// Absolute block coordinates.
position: Position,
blockCode: []const u8,
attributes: TreeAttribute,

/// Everything is copied into `arena`, so the result outlives `bytes`.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !BlockEntity {
    var reader: TreeAttribute.Reader = .{ .bytes = bytes };
    const class = try reader.string(arena);
    const attributes = try TreeAttribute.parse(arena, &reader);
    if (reader.pos != bytes.len) return error.TrailingData;
    return .{
        .class = class,
        .position = .{
            .x = attributes.getInt("posx") orelse return error.MissingPosition,
            .y = attributes.getInt("posy") orelse return error.MissingPosition,
            .z = attributes.getInt("posz") orelse return error.MissingPosition,
        },
        .blockCode = attributes.getString("blockCode") orelse return error.MissingBlockCode,
        .attributes = attributes,
    };
}

pub fn format(value: BlockEntity, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("BlockEntity({s} ({s}) [x: {}, z: {}, y: {}])", .{ value.blockCode, value.class, value.position.x, value.position.z, value.position.y });
}

test {
    _ = TreeAttribute;
}
