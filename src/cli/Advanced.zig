//! Settings of how Storymap works inside (`--advanced`), which change as it does: a key goes when
//! what it tunes is replaced.
const Advanced = @This();

const std = @import("std");
const maxLibdeflateLevel = @import("libdeflate").maxLevel;

/// libdeflate's level for PNG tiles and images.
libdeflate: u4 = 1,

/// Every setting, for messages.
pub const expected = std.fmt.comptimePrint("libdeflate=<level from 0 to {}>, joined by commas", .{maxLibdeflateLevel});

pub const Outcome = enum { set, unknownKey, invalidValue, missingValue };

/// Sets what `setting`, `key=value`, names.
pub fn set(self: *Advanced, setting: []const u8) Outcome {
    const equals = std.mem.indexOfScalar(u8, setting, '=') orelse return .missingValue;
    const key = setting[0..equals];
    const value = setting[equals + 1 ..];
    if (std.mem.eql(u8, key, "libdeflate")) {
        const level = std.fmt.parseInt(u4, value, 10) catch return .invalidValue;
        if (level > maxLibdeflateLevel) return .invalidValue;
        self.libdeflate = level;
        return .set;
    }
    return .unknownKey;
}

/// The key of `setting`, for messages.
pub fn keyOf(setting: []const u8) []const u8 {
    return setting[0 .. std.mem.indexOfScalar(u8, setting, '=') orelse setting.len];
}

test set {
    var advanced: Advanced = .{};
    try std.testing.expectEqual(.set, advanced.set("libdeflate=6"));
    try std.testing.expectEqual(6, advanced.libdeflate);
    try std.testing.expectEqual(.set, advanced.set("libdeflate=0"));
    try std.testing.expectEqual(.set, advanced.set("libdeflate=12"));
    try std.testing.expectEqual(12, advanced.libdeflate);
    try std.testing.expectEqual(.invalidValue, advanced.set("libdeflate=13"));
    try std.testing.expectEqual(.invalidValue, advanced.set("libdeflate=fast"));
    try std.testing.expectEqual(.invalidValue, advanced.set("libdeflate="));
    try std.testing.expectEqual(.missingValue, advanced.set("libdeflate"));
    try std.testing.expectEqual(.unknownKey, advanced.set("zopfli=15"));
    try std.testing.expectEqual(12, advanced.libdeflate);
    try std.testing.expectEqualStrings("zopfli", keyOf("zopfli=15"));
    try std.testing.expectEqualStrings("libdeflate", keyOf("libdeflate"));
}
