//! The game's wildcard codes (vsapi `WildcardUtil.cs`), as in `skipVariants: ["rock-*"]`: `*`
//! is any run of characters, and case is ignored. A code starting with `@` is a regular
//! expression matching the whole code, minding case. Only the regex syntax assets use is
//! supported: literals, `.`, `*` and groups `(a|b)`; anything else is an error rather than
//! misread (docs/blocks.md#block-codes).
const std = @import("std");

pub const Error = error{ RegexUnsupported, InvalidRegex };

/// Also true for a regular expression.
pub fn isWildcard(pattern: []const u8) bool {
    return std.mem.indexOfScalar(u8, pattern, '*') != null or (pattern.len > 0 and pattern[0] == '@');
}

pub fn match(pattern: []const u8, text: []const u8) Error!bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '@') {
        const regex = pattern[1..];
        try validate(regex);
        return matchAlternatives(regex, text, 0, null);
    }
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
        } else if (p < pattern.len and std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t])) {
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

fn validate(regex: []const u8) Error!void {
    var depth: usize = 0;
    var canRepeat = false;
    for (regex) |c| switch (c) {
        '(' => {
            depth += 1;
            canRepeat = false;
        },
        ')' => {
            if (depth == 0) return error.InvalidRegex;
            depth -= 1;
            canRepeat = true;
        },
        '|' => canRepeat = false,
        '*' => {
            if (!canRepeat) return error.InvalidRegex;
            canRepeat = false;
        },
        '[', ']', '\\', '+', '?', '^', '$', '{', '}' => return error.RegexUnsupported,
        else => canRepeat = true,
    };
    if (depth != 0) return error.InvalidRegex;
}

/// What's left to match after the current part of a regular expression: `rest`, then `next`.
/// A loop (`atom*`) continues with itself, and stops when an iteration matches nothing.
const Continuation = struct {
    rest: []const u8,
    next: ?*const Continuation,
    loopStart: ?usize = null,
};

fn proceed(text: []const u8, pos: usize, k: ?*const Continuation) bool {
    const continuation = k orelse return pos == text.len;
    if (continuation.loopStart == pos) return false;
    return matchSequence(continuation.rest, text, pos, continuation.next);
}

/// `regex`, alternatives separated by `|`, matched at `pos` and followed by `k`.
fn matchAlternatives(regex: []const u8, text: []const u8, pos: usize, k: ?*const Continuation) bool {
    var depth: usize = 0;
    var start: usize = 0;
    for (regex, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '|' => if (depth == 0) {
            if (matchSequence(regex[start..i], text, pos, k)) return true;
            start = i + 1;
        },
        else => {},
    };
    return matchSequence(regex[start..], text, pos, k);
}

/// A sequence of atoms, each a character, `.` or a group, optionally followed by `*`.
fn matchSequence(sequence: []const u8, text: []const u8, pos: usize, k: ?*const Continuation) bool {
    if (sequence.len == 0) return proceed(text, pos, k);
    var end: usize = 1;
    if (sequence[0] == '(') {
        var depth: usize = 0;
        for (sequence, 0..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (depth == 0) {
                end = i + 1;
                break;
            }
        }
    }
    const atom = sequence[0..end];
    if (end < sequence.len and sequence[end] == '*') {
        // Greedy: one more iteration first, then none.
        const loop: Continuation = .{ .rest = sequence, .next = k, .loopStart = pos };
        return matchAtom(atom, text, pos, &loop) or matchSequence(sequence[end + 1 ..], text, pos, k);
    }
    const after: Continuation = .{ .rest = sequence[end..], .next = k };
    return matchAtom(atom, text, pos, &after);
}

fn matchAtom(atom: []const u8, text: []const u8, pos: usize, k: *const Continuation) bool {
    if (atom[0] == '(') return matchAlternatives(atom[1 .. atom.len - 1], text, pos, k);
    if (pos == text.len) return false;
    if (atom[0] != '.' and atom[0] != text[pos]) return false;
    return proceed(text, pos + 1, k);
}

test match {
    try std.testing.expect(try match("rock-*", "rock-granite"));
    try std.testing.expect(try match("*-north-*", "slab-north-up"));
    try std.testing.expect(try match("*", ""));
    try std.testing.expect(try match("a*b*c", "aXbYbZc"));
    try std.testing.expect(try match("Rock-*", "rock-granite"));
    try std.testing.expect(!try match("rock-*", "rocks"));
    try std.testing.expect(!try match("*-up", "slab-down"));
    try std.testing.expect(!try match("rock", "rock-granite"));
}

test "regular expressions" {
    try std.testing.expect(try match("@rock-(granite|basalt)", "rock-basalt"));
    try std.testing.expect(!try match("@rock-(granite|basalt)", "rock-chalk"));
    try std.testing.expect(!try match("@rock-(granite|basalt)", "rock-granite-x"));
    try std.testing.expect(try match("@.*-(aged|veryaged)-.*", "planks-veryaged-north"));
    try std.testing.expect(try match("@(.*-steel|.*-iron)", "anvil-iron"));
    try std.testing.expect(!try match("@(.*-steel|.*-iron)", "anvil-ironx"));
    try std.testing.expect(try match("@a(b|c)*d", "abcbd"));
    try std.testing.expect(try match("@a(b|)*d", "ad"));
    try std.testing.expect(!try match("@Rock-.*", "rock-granite"));
    try std.testing.expectError(error.InvalidRegex, match("@*-(copper|tin)", "x-copper"));
    try std.testing.expectError(error.InvalidRegex, match("@rock-(a|b", "rock-a"));
    try std.testing.expectError(error.RegexUnsupported, match("@rock-[ab]", "rock-a"));
}
