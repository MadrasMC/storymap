//! What rendering needs to know about the game's and mods' blocks, prepared once from their
//! assets and kept, so a render never reads assets itself (docs/rendering.md#preparing-blocks).
//! For each block: its code, its material and its colour on the game's map.
//!
//! A prepared set is a folder `<blocks folder>/<key>/` holding `blocks.txt`, where the key
//! depends on the game version and the mods, so each combination is prepared once:
//!
//!     storymap blocks 2
//!     game 1.22.7
//!     mod primitivesurvival_5.1.4.zip
//!     domain game
//!     domain primitivesurvival
//!     block rock-granite Stone land
//!     …
const Prepared = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Assets = @import("Assets.zig");
const BlockTypes = @import("BlockTypes.zig");

arena: std.heap.ArenaAllocator,
gameVersion: []const u8 = "",
mods: std.ArrayList([]const u8) = .empty,
/// The domains the game and mods have assets in.
domains: std.StringHashMapUnmanaged(void) = .empty,
/// Every block, by its code as a save names it.
blocks: std.StringHashMapUnmanaged(Block) = .empty,

pub const Block = struct {
    /// One of `BlockTypes.materials`, e.g. "Stone".
    material: []const u8,
    /// Its colour on the game's map, e.g. "land" or "forest" (docs/rendering.md#block-colours).
    colorCode: []const u8,
};

/// The format of `blocks.txt`, and of what goes into it: raise it when either changes, so
/// sets prepared before are prepared again.
const formatVersion = 2;
const fileName = "blocks.txt";

/// Blocks the game registers itself rather than from a block type file.
const builtInBlocks = [_][]const u8{ "air", "mantle" };

pub fn deinit(self: *Prepared) void {
    self.arena.deinit();
}

/// Where prepared sets go when no folder is given: `blocks` in the current folder, beside a
/// render's `out`.
pub const defaultFolder = "blocks";

/// The folder name for the set prepared from `assets`: changes with the game version, the
/// mods (their names, sizes and times) and `formatVersion`.
pub fn key(buffer: *[16]u8, io: Io, assets: *const Assets) ![]const u8 {
    var hasher: std.hash.Wyhash = .init(formatVersion);
    hasher.update(assets.version orelse "");
    for (assets.sources.items[1..]) |source| {
        hasher.update(&.{0});
        hasher.update(source.name);
        switch (source.kind) {
            .zip => |zip| {
                const stat = try zip.file.stat(io);
                hasher.update(std.mem.asBytes(&stat.size));
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            },
            .folders => |folders| for (folders) |folder| {
                const stat = try folder.dir.stat(io);
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            },
        }
    }
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{hasher.final()}) catch unreachable;
}

/// Prepares the blocks of `assets` into `folder`, replacing what was there. Returns how
/// many blocks there are.
pub fn prepare(arena: std.mem.Allocator, io: Io, assets: *const Assets, folder: Dir) !usize {
    const blocks = try BlockTypes.expand(arena, io, assets);
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.print("storymap blocks {}\ngame {s}\n", .{ formatVersion, assets.version orelse "" });
    for (assets.sources.items[1..]) |source| try w.print("mod {s}\n", .{source.name});
    for (assets.domains.keys()) |domain| try w.print("domain {s}\n", .{domain});
    for (blocks) |block| try w.print("block {s} {s} {s}\n", .{ block.code, block.material, block.colorCode });
    // Written beside it first, so a set is never left half written.
    const partial = fileName ++ ".partial";
    try folder.writeFile(io, .{ .sub_path = partial, .data = text.written() });
    try folder.rename(partial, folder, fileName, io);
    return blocks.len;
}

/// Whether `folder` holds a prepared set.
pub fn exists(io: Io, folder: Dir) bool {
    folder.access(io, fileName, .{}) catch return false;
    return true;
}

/// Loads the set prepared in `folder`.
pub fn load(allocator: std.mem.Allocator, io: Io, folder: Dir) !Prepared {
    var self: Prepared = .{ .arena = .init(allocator) };
    errdefer self.deinit();
    const arena = self.arena.allocator();
    const text = try folder.readFileAlloc(io, fileName, arena, .limited(256 << 20));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const header = lines.next() orelse return error.NotPreparedBlocks;
    if (!std.mem.eql(u8, header, std.fmt.comptimePrint("storymap blocks {}", .{formatVersion}))) return error.NotPreparedBlocks;
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        const kind = words.next() orelse continue;
        const first = words.next() orelse "";
        if (std.mem.eql(u8, kind, "game")) {
            self.gameVersion = first;
        } else if (std.mem.eql(u8, kind, "mod")) {
            try self.mods.append(arena, first);
        } else if (std.mem.eql(u8, kind, "domain")) {
            try self.domains.put(arena, first, {});
        } else if (std.mem.eql(u8, kind, "block")) {
            const material = words.next() orelse return error.NotPreparedBlocks;
            const colorCode = words.next() orelse return error.NotPreparedBlocks;
            try self.blocks.put(arena, first, .{ .material = material, .colorCode = colorCode });
        }
    }
    return self;
}

/// The newest set prepared in the blocks folder `blocks`, by when it was prepared, for when
/// the game isn't there to say which one fits: its folder's name, or null without any.
pub fn newest(arena: std.mem.Allocator, io: Io, blocks: Dir) !?[]const u8 {
    var best: ?[]const u8 = null;
    var bestTime: i96 = std.math.minInt(i96);
    var it = blocks.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ entry.name, fileName });
        const stat = blocks.statFile(io, path, .{}) catch continue;
        if (stat.mtime.nanoseconds > bestTime) {
            bestTime = stat.mtime.nanoseconds;
            best = try arena.dupe(u8, entry.name);
        }
    }
    return best;
}

/// What a save's blocks have that the prepared set doesn't: the mods (domains) it lacks, and
/// how many codes in its domains it doesn't know, with one of them.
pub const Unknown = struct {
    mods: []const []const u8,
    codes: usize,
    example: ?[]const u8,
};

pub fn unknown(self: *const Prepared, allocator: std.mem.Allocator, codes: []const ?[]const u8) !Unknown {
    var mods: std.ArrayList([]const u8) = .empty;
    errdefer mods.deinit(allocator);
    var count: usize = 0;
    var example: ?[]const u8 = null;
    codes: for (codes) |maybeCode| {
        const code = maybeCode orelse continue;
        if (self.blocks.contains(code)) continue;
        for (builtInBlocks) |builtIn| if (std.mem.eql(u8, code, builtIn)) continue :codes;
        const colon = std.mem.indexOfScalar(u8, code, ':');
        const domain = if (colon) |c| code[0..c] else Assets.gameDomain;
        if (!self.domains.contains(domain)) {
            for (mods.items) |seen| {
                if (std.mem.eql(u8, seen, domain)) break;
            } else try mods.append(allocator, domain);
            continue;
        }
        count += 1;
        if (example == null) example = code;
    }
    return .{ .mods = try mods.toOwnedSlice(allocator), .codes = count, .example = example };
}

test "prepare, load and compare with a save" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "game/assets/version-1.22.7.txt", "" },
        .{ "game/assets/survival/worldproperties/block/rock.json", "{ code: 'rock', variants: [ { code: 'granite' } ] }" },
        .{ "game/assets/survival/blocktypes/rock.json", "{ code: 'rock', variantgroups: [ { loadFromProperties: 'block/rock' } ] }" },
        .{ "data/Mods/testmod.zip", @embedFile("testdata/testmod.zip") },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var game = try tmp.dir.openDir(io, "game", .{});
    defer game.close(io);
    var data = try tmp.dir.openDir(io, "data", .{});
    defer data.close(io);
    var assets = try Assets.open(std.testing.allocator, io, game, data);
    defer assets.close(io);

    var buffer: [16]u8 = undefined;
    const name = try key(&buffer, io, &assets);
    try std.testing.expectEqual(16, name.len);
    try tmp.dir.createDirPath(io, name);
    var folder = try tmp.dir.openDir(io, name, .{});
    defer folder.close(io);
    try std.testing.expect(!exists(io, folder));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // rock-granite, and the test mod's thing.
    try std.testing.expectEqual(2, try prepare(arena.allocator(), io, &assets, folder));
    try std.testing.expect(exists(io, folder));

    var prepared = try load(std.testing.allocator, io, folder);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("1.22.7", prepared.gameVersion);
    try std.testing.expectEqualStrings("testmod.zip", prepared.mods.items[0]);
    try std.testing.expectEqualStrings("Stone", prepared.blocks.get("rock-granite").?.material);
    try std.testing.expectEqualStrings("land", prepared.blocks.get("rock-granite").?.colorCode);
    try std.testing.expect(prepared.blocks.contains("testmod:thing"));

    const codes = [_]?[]const u8{ "air", "rock-granite", "rock-basalt", null, "testmod:thing", "othermod:x", "othermod:y" };
    const missing = try prepared.unknown(std.testing.allocator, &codes);
    defer std.testing.allocator.free(missing.mods);
    try std.testing.expectEqual(1, missing.mods.len);
    try std.testing.expectEqualStrings("othermod", missing.mods[0]);
    try std.testing.expectEqual(1, missing.codes);
    try std.testing.expectEqualStrings("rock-basalt", missing.example.?);
}
