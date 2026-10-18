//! The game's wildcard codes, as in `skipVariants: ["rock-*"]`: `*` stands for any run of
//! characters, anything else for itself. A code starting with `@` is a regular expression
//! instead, which isn't supported yet: neither the game nor the mods checked use one where
//! block codes are decided (docs/rendering.md#block-codes).
const std = @import("std");

/// Whether `pattern` is a wildcard or a regular expression, rather than one exact code.
pub fn isWildcard(pattern: []const u8) bool {
    return std.mem.indexOfScalar(u8, pattern, '*') != null or (pattern.len > 0 and pattern[0] == '@');
}

/// Whether `text` matches `pattern`, both lowercase.
pub fn match(pattern: []const u8, text: []const u8) error{RegexUnsupported}!bool {
    if (pattern.len > 0 and pattern[0] == '@') return error.RegexUnsupported;
    // Backtracking to the last `*` is enough: a later `*` can absorb whatever an earlier
    // one would have.
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = t;
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            retry += 1;
            t = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test match {
    try std.testing.expect(try match("rock-*", "rock-granite"));
    try std.testing.expect(try match("*-north-*", "slab-north-up"));
    try std.testing.expect(try match("*", ""));
    try std.testing.expect(try match("a*b*c", "aXbYbZc"));
    try std.testing.expect(!try match("rock-*", "rocks"));
    try std.testing.expect(!try match("*-up", "slab-down"));
    try std.testing.expect(!try match("rock", "rock-granite"));
    try std.testing.expectError(error.RegexUnsupported, match("@rock-(a|b)", "rock-a"));
}
