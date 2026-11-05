//! Minecraft's client jar, whose assets hold its blocks' states, models and textures: found where
//! the official launcher keeps it, `versions/<version>/<version>.jar` in the game folder, and
//! read in place. The game folder is only ever read.
const Jar = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

file: Io.File,
/// The needed entries, by path below `assets/minecraft/`, e.g. "blockstates/stone.json".
entries: std.StringHashMapUnmanaged(std.zip.Iterator.Entry),
/// The game version, from the jar's `version.json`, e.g. "26.3"; empty if it has none.
version: []const u8,

/// The folders below `assets/minecraft/` that preparing blocks reads.
const neededFolders = [_][]const u8{ "blockstates/", "models/block/", "textures/block/", "textures/colormap/" };

/// The largest file read; the biggest block texture in 26.3 is a few KiB.
const maxFileBytes = 16 << 20;

/// The jar at `path`, its entries kept in `arena`.
pub fn open(arena: std.mem.Allocator, io: Io, path: []const u8) !Jar {
    const file = try Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var it = try std.zip.Iterator.init(&reader);
    var entries: std.StringHashMapUnmanaged(std.zip.Iterator.Entry) = .empty;
    var versionEntry: ?std.zip.Iterator.Entry = null;
    var name: [Dir.max_path_bytes]u8 = undefined;
    while (try it.next()) |entry| {
        const entryPath = try entry.getFilename(&reader, &name, .{});
        if (std.mem.eql(u8, entryPath, "version.json")) versionEntry = entry;
        const prefix = "assets/minecraft/";
        if (!std.mem.startsWith(u8, entryPath, prefix) or entryPath[entryPath.len - 1] == '/') continue;
        const key = entryPath[prefix.len..];
        if (!isNeeded(key)) continue;
        try entries.put(arena, try arena.dupe(u8, key), entry);
    }
    if (entries.count() == 0) return error.NotAClientJar;
    var self: Jar = .{ .file = file, .entries = entries, .version = "" };
    if (versionEntry) |entry| self.version = try versionOf(arena, try self.extract(arena, io, entry));
    return self;
}

pub fn close(self: *Jar, io: Io) void {
    self.file.close(io);
}

fn isNeeded(path: []const u8) bool {
    for (neededFolders) |folder| if (std.mem.startsWith(u8, path, folder)) return true;
    return false;
}

/// The `id` in a `version.json`; empty if it has none.
fn versionOf(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { id: []const u8 = "" }, arena, json, .{ .ignore_unknown_fields = true }) catch return "";
    return parsed.id;
}

/// Reads `path` below `assets/minecraft/`, e.g. "blockstates/stone.json"; null if the jar
/// doesn't have it or it isn't needed.
pub fn read(self: *const Jar, allocator: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    const entry = self.entries.get(path) orelse return null;
    return try self.extract(allocator, io, entry);
}

fn extract(self: *const Jar, allocator: std.mem.Allocator, io: Io, entry: std.zip.Iterator.Entry) ![]u8 {
    if (entry.uncompressed_size > maxFileBytes) return error.FileTooBig;
    const bytes = try allocator.alloc(u8, @intCast(entry.uncompressed_size));
    errdefer allocator.free(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = self.file.reader(io, &buffer);
    var writer: Io.Writer = .fixed(bytes);
    try entry.extractTo(&reader, &writer);
    return bytes;
}

/// The official launcher's game folder, if it's there.
pub fn standardFolder(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) ?[]const u8 {
    const folder = switch (builtin.os.tag) {
        .windows => std.fs.path.join(arena, &.{ env.get("APPDATA") orelse return null, ".minecraft" }),
        .macos => std.fs.path.join(arena, &.{ env.get("HOME") orelse return null, "Library/Application Support/minecraft" }),
        else => std.fs.path.join(arena, &.{ env.get("HOME") orelse return null, ".minecraft" }),
    } catch return null;
    return if (isGameFolder(io, folder)) folder else null;
}

/// Whether `path` is a game folder: one with a `versions` folder.
pub fn isGameFolder(io: Io, path: []const u8) bool {
    var folder = Dir.cwd().openDir(io, path, .{}) catch return false;
    defer folder.close(io);
    var versions = folder.openDir(io, "versions", .{}) catch return false;
    versions.close(io);
    return true;
}

/// The jar of `version` in game folder `folder`, or of its highest release without one; null if
/// it isn't there.
pub fn inGameFolder(arena: std.mem.Allocator, io: Io, folder: []const u8, version: ?[]const u8) !?[]const u8 {
    const versions = try std.fs.path.join(arena, &.{ folder, "versions" });
    if (version) |wanted| return inVersionFolder(arena, io, try std.fs.path.join(arena, &.{ versions, wanted }), wanted);
    var dir = Dir.cwd().openDir(io, versions, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var highest: ?[]const u8 = null;
    var highestJar: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !isRelease(entry.name)) continue;
        if (highest) |other| if (compareVersions(entry.name, other) != .gt) continue;
        const name = try arena.dupe(u8, entry.name);
        const jar = try inVersionFolder(arena, io, try std.fs.path.join(arena, &.{ versions, name }), name) orelse continue;
        highest = name;
        highestJar = jar;
    }
    return highestJar;
}

/// The jar in a version's folder, `<version>.jar`, as the launcher names it; null if it isn't
/// there.
pub fn inVersionFolder(arena: std.mem.Allocator, io: Io, folder: []const u8, version: []const u8) !?[]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}.jar", .{version});
    const path = try std.fs.path.join(arena, &.{ folder, name });
    Dir.cwd().access(io, path, .{}) catch return null;
    return path;
}

/// Whether a version is a release, such as "26.3" or "1.21.4": numbers between dots, unlike a
/// snapshot's ("26.4-snapshot-1", "25w14a") or a mod loader's ("fabric-loader-0.16.14-26.3").
fn isRelease(version: []const u8) bool {
    if (version.len == 0) return false;
    var parts = std.mem.splitScalar(u8, version, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Orders two releases by their numbers, part by part: "1.21.4" < "1.21.10" < "26.3".
fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var aParts = std.mem.splitScalar(u8, a, '.');
    var bParts = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const aPart = aParts.next();
        const bPart = bParts.next();
        if (aPart == null and bPart == null) return .eq;
        const aNumber = std.fmt.parseInt(u64, aPart orelse "0", 10) catch 0;
        const bNumber = std.fmt.parseInt(u64, bPart orelse "0", 10) catch 0;
        const order = std.math.order(aNumber, bNumber);
        if (order != .eq) return order;
    }
}

test isRelease {
    try std.testing.expect(isRelease("26.3"));
    try std.testing.expect(isRelease("1.21.4"));
    try std.testing.expect(!isRelease("26.4-snapshot-1"));
    try std.testing.expect(!isRelease("25w14a"));
    try std.testing.expect(!isRelease("fabric-loader-0.16.14-26.3"));
    try std.testing.expect(!isRelease("1..2"));
}

test compareVersions {
    try std.testing.expectEqual(.lt, compareVersions("1.21.4", "1.21.10"));
    try std.testing.expectEqual(.lt, compareVersions("1.21.10", "26.3"));
    try std.testing.expectEqual(.gt, compareVersions("26.3.1", "26.3"));
    try std.testing.expectEqual(.eq, compareVersions("26.3", "26.3.0"));
}

test "the highest release in a game folder" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "1.21.4", "1.21.10", "26.4-snapshot-1" }) |version| {
        const path = try std.fmt.allocPrint(arena.allocator(), "game/versions/{s}/{s}.jar", .{ version, version });
        try tmp.dir.createDirPath(io, std.fs.path.dirname(path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "" });
    }
    // A release without its jar, as the launcher leaves one it hasn't downloaded.
    try tmp.dir.createDirPath(io, "game/versions/26.3");

    const folder = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path, "game" });
    try std.testing.expect(isGameFolder(io, folder));
    const highest = (try inGameFolder(arena.allocator(), io, folder, null)).?;
    try std.testing.expectEqualStrings("1.21.10.jar", std.fs.path.basename(highest));
    try std.testing.expect(try inGameFolder(arena.allocator(), io, folder, "26.4-snapshot-1") != null);
    try std.testing.expectEqual(null, try inGameFolder(arena.allocator(), io, folder, "26.3"));
}
