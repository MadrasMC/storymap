//! The needed files from the install's `assets/` and from each mod in `Mods/` (a zip or a
//! folder with its own `assets/<domain>/…`), read in place. The install's `creative`, `game`
//! and `survival` folders are all the `game` domain. Files are looked up by domain and path,
//! ignoring case as the game does; a mod's file replaces the game's
//! (docs/rendering.md#reading-them).
//!
//! The game and data folders are only ever read.
const Assets = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

arena: std.heap.ArenaAllocator,
/// The game, then the mods in name order, so a later one's files replace an earlier one's.
sources: std.ArrayList(Source) = .empty,
domains: std.StringArrayHashMapUnmanaged(void) = .empty,
/// The game version, from assets/version-<version>.txt.
version: ?[]const u8 = null,

pub const Source = struct {
    /// "Vintage Story", or a mod's zip or folder name in Mods.
    name: []const u8,
    kind: union(enum) {
        /// The source's `assets` subfolders, in name order.
        folders: []const Folder,
        zip: Zip,
    },
};

pub const Folder = struct {
    domain: []const u8,
    dir: Dir,
};

pub const gameDomain = "game";

/// A zip has no lookup by name, so the needed entries are mapped on opening, by lowercased
/// "domain/path" below `assets/`.
const Zip = struct {
    file: Io.File,
    entries: std.StringHashMapUnmanaged(std.zip.Iterator.Entry),
};

/// E.g. "game" and "blocktypes/stone/rock.json", both lowercase.
pub const Name = struct {
    domain: []const u8,
    path: []const u8,
};

/// The largest asset file read; the biggest in 1.22.7 is a few MB.
const maxFileBytes = 64 << 20;

/// `game` is the install folder, `data` the data folder. A mod that can't be read is skipped
/// with a warning.
pub fn open(allocator: std.mem.Allocator, io: Io, game: Dir, data: ?Dir) !Assets {
    var self: Assets = .{ .arena = .init(allocator) };
    errdefer self.close(io);
    const arena = self.arena.allocator();

    var assets = game.openDir(io, "assets", .{ .iterate = true }) catch return error.NoAssetsFolder;
    defer assets.close(io);
    self.version = try findVersion(arena, io, assets);
    try self.addFolders(io, "Vintage Story", assets, gameDomain);

    var mods = (data orelse return self).openDir(io, "Mods", .{ .iterate = true }) catch return self;
    defer mods.close(io);
    // In name order, so which mod's file wins doesn't depend on the file system.
    var names: std.ArrayList([]const u8) = .empty;
    var it = mods.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or std.ascii.endsWithIgnoreCase(entry.name, ".zip"))
            try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        self.addMod(io, mods, name) catch |err| {
            std.debug.print("storymap: skipped mod {s}: could not read ({s})\n", .{ name, @errorName(err) });
        };
    }
    return self;
}

pub fn close(self: *Assets, io: Io) void {
    for (self.sources.items) |source| switch (source.kind) {
        .folders => |folders| for (folders) |folder| folder.dir.close(io),
        .zip => |zip| zip.file.close(io),
    };
    self.arena.deinit();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A mod folder without `assets/`, such as a code-only mod, is left out.
fn addMod(self: *Assets, io: Io, mods: Dir, name: []const u8) !void {
    const arena = self.arena.allocator();
    if (std.ascii.endsWithIgnoreCase(name, ".zip")) {
        const file = try mods.openFile(io, name, .{});
        errdefer file.close(io);
        const entries = try mapZip(arena, io, file);
        try self.sources.append(arena, .{ .name = name, .kind = .{ .zip = .{ .file = file, .entries = entries } } });
        var it = entries.keyIterator();
        while (it.next()) |key| try self.domains.put(arena, domainOf(key.*), {});
    } else {
        var mod = try mods.openDir(io, name, .{});
        defer mod.close(io);
        var assets = mod.openDir(io, "assets", .{ .iterate = true }) catch return;
        defer assets.close(io);
        try self.addFolders(io, name, assets, null);
    }
}

/// Adds the folders in `assets` as one source, all in `domain`, or each in the domain its
/// name gives.
fn addFolders(self: *Assets, io: Io, name: []const u8, assets: Dir, domain: ?[]const u8) !void {
    const arena = self.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = assets.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var folders: std.ArrayList(Folder) = .empty;
    errdefer for (folders.items) |folder| folder.dir.close(io);
    for (names.items) |folderName| {
        const folderDomain = domain orelse lowered: {
            const copy = try arena.dupe(u8, folderName);
            break :lowered std.ascii.lowerString(copy, copy);
        };
        try folders.append(arena, .{ .domain = folderDomain, .dir = try assets.openDir(io, folderName, .{ .iterate = true }) });
        try self.domains.put(arena, folderDomain, {});
    }
    try self.sources.append(arena, .{ .name = name, .kind = .{ .folders = folders.items } });
}

fn domainOf(key: []const u8) []const u8 {
    return key[0 .. std.mem.indexOfScalar(u8, key, '/') orelse key.len];
}

fn mapZip(arena: std.mem.Allocator, io: Io, file: Io.File) !std.StringHashMapUnmanaged(std.zip.Iterator.Entry) {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var it = try std.zip.Iterator.init(&reader);
    var entries: std.StringHashMapUnmanaged(std.zip.Iterator.Entry) = .empty;
    var name: [Dir.max_path_bytes]u8 = undefined;
    while (try it.next()) |entry| {
        const path = try entry.getFilename(&reader, &name, .{ .allow_backslashes = true });
        if (path.len == 0 or path[path.len - 1] == '/') continue; // a folder
        if (!std.ascii.startsWithIgnoreCase(path, "assets/")) continue;
        const key = try arena.dupe(u8, path["assets/".len..]);
        if (!needed(std.ascii.lowerString(key, key))) continue;
        try entries.put(arena, key, entry);
    }
    return entries;
}

/// Whether `path` below `assets/`, e.g. "survival/blocktypes/stone/rock.json", is needed:
/// `actionFor` enters every folder on the way and takes the file.
fn needed(path: []const u8) bool {
    var parts: [maxDepth][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| : (count += 1) {
        if (count == maxDepth) return false;
        parts[count] = part;
    }
    if (count < 3) return false;
    for (1..count) |depth| if (actionFor(parts[0..depth], true) != .enter) return false;
    return actionFor(parts[0..count], false) == .take;
}

const maxDepth = 32;

test needed {
    try std.testing.expect(needed("survival/blocktypes/stone/rock.json"));
    try std.testing.expect(needed("primitivesurvival/textures/block/x.png"));
    try std.testing.expect(!needed("survival/lang/en.json"));
    try std.testing.expect(!needed("game/textures/gui/x.png"));
    try std.testing.expect(!needed("version-1.22.7.txt"));
    try std.testing.expect(needed("survival/config/colormaps.json"));
}

/// Reads `path` in `domain`, e.g. "game" and "blocktypes/stone/rock.json", ignoring case.
/// Null if no source has it.
pub fn read(self: *const Assets, allocator: std.mem.Allocator, io: Io, domain: []const u8, path: []const u8) !?[]u8 {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ domain, path }) catch return null;
    if (!needed(std.ascii.lowerString(key, key))) return null;
    const lowerDomain = key[0..domain.len];
    const lowerPath = key[domain.len + 1 ..];
    // The last mod first: its file replaces the others'.
    var i = self.sources.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.sources.items[i].kind) {
            .zip => |zip| if (zip.entries.get(key)) |entry| return try readZip(allocator, io, zip.file, entry),
            .folders => |folders| {
                var j = folders.len;
                while (j > 0) {
                    j -= 1;
                    if (!std.mem.eql(u8, folders[j].domain, lowerDomain)) continue;
                    if (try readFolder(allocator, io, folders[j].dir, lowerPath)) |bytes| return bytes;
                }
            },
        }
    }
    return null;
}

fn readZip(allocator: std.mem.Allocator, io: Io, file: Io.File, entry: std.zip.Iterator.Entry) ![]u8 {
    if (entry.uncompressed_size > maxFileBytes) return error.FileTooBig;
    const bytes = try allocator.alloc(u8, @intCast(entry.uncompressed_size));
    errdefer allocator.free(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var writer: Io.Writer = .fixed(bytes);
    try entry.extractTo(&reader, &writer);
    return bytes;
}

/// `path` is lowercase. The game names nearly all its assets in lowercase, but not all
/// (`shapes/block/clutter/pipes/h-EW.json`), so on a case-sensitive file system a file not
/// found by its lowercase path is searched for ignoring case.
fn readFolder(allocator: std.mem.Allocator, io: Io, folder: Dir, path: []const u8) !?[]u8 {
    return folder.readFileAlloc(io, path, allocator, .limited(maxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => {
            var buffer: [Dir.max_path_bytes]u8 = undefined;
            const named = try findIgnoringCase(io, folder, path, &buffer) orelse return null;
            return try folder.readFileAlloc(io, named, allocator, .limited(maxFileBytes));
        },
        else => return err,
    };
}

/// `path` with each part as named on disk, written into `out`. `dir` must be open for
/// iterating.
fn findIgnoringCase(io: Io, dir: Dir, path: []const u8, out: []u8) !?[]const u8 {
    var current = dir;
    var opened: ?Dir = null;
    defer if (opened) |folder| folder.close(io);
    var len: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        var entries = current.iterate();
        const name = while (try entries.next(io)) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, part)) break entry.name;
        } else return null;
        if (len + 1 + name.len > out.len) return null;
        if (len > 0) {
            out[len] = '/';
            len += 1;
        }
        @memcpy(out[len..][0..name.len], name);
        if (parts.peek() != null) {
            const next = current.openDir(io, out[len..][0..name.len], .{ .iterate = true }) catch return null;
            if (opened) |folder| folder.close(io);
            opened = next;
            current = next;
        }
        len += name.len;
    }
    return out[0..len];
}

/// Every needed file in `folder` (e.g. "blocktypes") of each domain, once each, in name order.
pub fn list(self: *const Assets, arena: std.mem.Allocator, io: Io, folder: []const u8) ![]const Name {
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (self.sources.items) |source| switch (source.kind) {
        .zip => |zip| {
            var it = zip.entries.keyIterator();
            while (it.next()) |key| {
                const rest = key.*[domainOf(key.*).len..];
                if (rest.len > folder.len + 1 and rest[folder.len + 1] == '/' and std.mem.eql(u8, rest[1 .. folder.len + 1], folder))
                    try keys.put(arena, key.*, {});
            }
        },
        .folders => |folders| for (folders) |domainFolder| try listFolder(arena, io, domainFolder, folder, &keys),
    };
    const sorted = keys.keys();
    std.mem.sort([]const u8, sorted, {}, lessThan);
    const names = try arena.alloc(Name, sorted.len);
    for (names, sorted) |*name, key| {
        const domain = domainOf(key);
        name.* = .{ .domain = domain, .path = key[domain.len + 1 ..] };
    }
    return names;
}

fn listFolder(arena: std.mem.Allocator, io: Io, domainFolder: Folder, folder: []const u8, keys: *std.StringArrayHashMapUnmanaged(void)) !void {
    var dir = domainFolder.dir.openDir(io, folder, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const key = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ domainFolder.domain, folder, entry.path });
        std.mem.replaceScalar(u8, key, std.fs.path.sep, '/');
        if (needed(std.ascii.lowerString(key, key))) try keys.put(arena, key, {});
    }
}

test "assets from the game, a mod zip and a mod folder" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "game/assets/version-1.22.7.txt", "" },
        .{ "game/assets/survival/blocktypes/a.json", "rock" },
        .{ "game/assets/survival/blocktypes/stone/b.json", "stone" },
        .{ "game/assets/creative/blocktypes/c.json", "creative" },
        .{ "game/assets/survival/shapes/block/pipes/h-EW.json", "pipe" },
        .{ "game/assets/game/textures/block/override.png", "from the game" },
        .{ "game/assets/game/music/song.ogg", "music" },
        .{ "data/Mods/folder-mod/assets/othermod/shapes/s.json", "shape" },
        .{ "data/Mods/code-only/othercode.dll", "MZ" },
        .{ "data/Mods/notes.txt", "not a mod" },
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

    var assets = try open(std.testing.allocator, io, game, data);
    defer assets.close(io);
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("1.22.7", assets.version.?);
    // Vintage Story, the folder mod and the zip; the code-only mod has no assets.
    try std.testing.expectEqual(3, assets.sources.items.len);

    // The install's survival and creative folders are the game domain.
    const rock = (try assets.read(allocator, io, "Game", "blocktypes/A.json")).?;
    defer allocator.free(rock);
    try std.testing.expectEqualStrings("rock", rock);
    const pipe = (try assets.read(allocator, io, "game", "shapes/block/pipes/h-ew.json")).?;
    defer allocator.free(pipe);
    try std.testing.expectEqualStrings("pipe", pipe);
    // The zip's own file, deflated, and its override of the game's, named in another case.
    const thing = (try assets.read(allocator, io, "testmod", "blocktypes/thing.json")).?;
    defer allocator.free(thing);
    try std.testing.expectEqual(394, thing.len);
    const override = (try assets.read(allocator, io, "game", "textures/block/override.png")).?;
    defer allocator.free(override);
    try std.testing.expectEqualStrings("from the mod", override);
    const shape = (try assets.read(allocator, io, "othermod", "shapes/s.json")).?;
    defer allocator.free(shape);
    try std.testing.expectEqualStrings("shape", shape);
    // What rendering doesn't need isn't read, from the install or a mod.
    try std.testing.expectEqual(null, try assets.read(allocator, io, "game", "music/song.ogg"));
    try std.testing.expectEqual(null, try assets.read(allocator, io, "testmod", "lang/en.json"));
    try std.testing.expectEqual(null, try assets.read(allocator, io, "game", "blocktypes/missing.json"));
    try std.testing.expectEqual(null, try assets.read(allocator, io, "survival", "blocktypes/a.json"));

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const blocktypes = try assets.list(arena.allocator(), io, "blocktypes");
    try std.testing.expectEqual(4, blocktypes.len);
    try std.testing.expectEqualStrings("game", blocktypes[0].domain);
    try std.testing.expectEqualStrings("blocktypes/a.json", blocktypes[0].path);
    try std.testing.expectEqualStrings("blocktypes/c.json", blocktypes[1].path);
    try std.testing.expectEqualStrings("blocktypes/stone/b.json", blocktypes[2].path);
    try std.testing.expectEqualStrings("testmod", blocktypes[3].domain);
    const textures = try assets.list(arena.allocator(), io, "textures");
    try std.testing.expectEqual(1, textures.len);
    try std.testing.expectEqualStrings("textures/block/override.png", textures[0].path);

    try std.testing.expect(assets.domains.contains("game"));
    try std.testing.expect(assets.domains.contains("testmod"));
    try std.testing.expect(assets.domains.contains("othermod"));
    try std.testing.expect(!assets.domains.contains("survival"));
}

test findIgnoringCase {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Shapes/Block");
    try tmp.dir.writeFile(io, .{ .sub_path = "Shapes/Block/h-EW.json", .data = "" });
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Shapes/Block/h-EW.json", (try findIgnoringCase(io, tmp.dir, "shapes/block/h-ew.json", &buffer)).?);
    try std.testing.expectEqual(null, try findIgnoringCase(io, tmp.dir, "shapes/block/missing.json", &buffer));
    try std.testing.expectEqual(null, try findIgnoringCase(io, tmp.dir, "shapes/other/h-ew.json", &buffer));
}

const Action = enum { take, enter, skip };

const wholeCategories = [_][]const u8{ "blocktypes", "itemtypes", "shapes", "textures", "worldproperties", "patches" };
const skippedTextures = [_][]const u8{ "gui", "icons" };

/// `parts` is a path below `assets/` split into its components (domain, category, …).
/// docs/rendering.md#what-the-renderer-needs-from-them says why these assets are needed.
fn actionFor(parts: []const []const u8, isDir: bool) Action {
    const eql = std.mem.eql;
    switch (parts.len) {
        0 => return .skip,
        // assets/version-1.22.7.txt, and the domain folders.
        1 => return if (isDir) .enter else if (std.mem.startsWith(u8, parts[0], "version-")) .take else .skip,
        2 => {
            if (!isDir) return .skip;
            for (wholeCategories) |category| if (eql(u8, parts[1], category)) return .enter;
            return if (eql(u8, parts[1], "config")) .enter else .skip;
        },
        else => {
            // Only the colour map definitions are needed from config/.
            if (eql(u8, parts[1], "config"))
                return if (parts.len == 3 and !isDir and eql(u8, parts[2], "colormaps.json")) .take else .skip;
            if (parts.len == 3 and isDir and eql(u8, parts[1], "textures")) {
                for (skippedTextures) |skipped| if (eql(u8, parts[2], skipped)) return .skip;
            }
            return if (isDir) .enter else .take;
        },
    }
}

test actionFor {
    const cases = .{
        .{ &.{"version-1.22.7.txt"}, false, Action.take },
        .{ &.{"gameicon.png"}, false, Action.skip },
        .{ &.{"survival"}, true, Action.enter },
        .{ &.{ "survival", "music" }, true, Action.skip },
        .{ &.{ "survival", "blocktypes" }, true, Action.enter },
        .{ &.{ "survival", "blocktypes", "stone", "rock.json" }, false, Action.take },
        .{ &.{ "game", "textures", "gui" }, true, Action.skip },
        .{ &.{ "game", "textures", "block" }, true, Action.enter },
        .{ &.{ "survival", "config", "colormaps.json" }, false, Action.take },
        .{ &.{ "survival", "config", "traits.json" }, false, Action.skip },
        .{ &.{ "survival", "config", "handbook" }, true, Action.skip },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[2], actionFor(case[0], case[1]));
}

fn findVersion(allocator: std.mem.Allocator, io: Io, assetsDir: Dir) !?[]const u8 {
    var it = assetsDir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "version-") and std.mem.endsWith(u8, entry.name, ".txt"))
            return try allocator.dupe(u8, entry.name["version-".len .. entry.name.len - ".txt".len]);
    }
    return null;
}

pub const StandardFolder = enum { game, data };

/// The first standard location that exists. The Windows paths are verified on a 1.22.7
/// install; the Linux data folders come from https://wiki.vintagestory.at/VintagestoryData_folder
/// and the Linux game folders from forum reports, unverified.
pub fn findFolder(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, folder: StandardFolder) ?[]const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    const join = std.fs.path.join;
    if (builtin.os.tag == .windows) {
        if (env.get("APPDATA")) |appData| candidates.append(arena, join(arena, &.{ appData, switch (folder) {
            .game => "Vintagestory",
            .data => "VintagestoryData",
        } }) catch return null) catch return null;
    } else if (env.get("HOME")) |home| {
        const paths: []const []const u8 = switch (folder) {
            .game => &.{ ".local/share/vintagestory", ".local/share/flatpak/app/at.vintagestory.VintageStory/current/active/files/extra/vintagestory" },
            .data => &.{ ".config/VintagestoryData", ".var/app/at.vintagestory.VintageStory/config/VintagestoryData" },
        };
        if (folder == .data) {
            if (env.get("XDG_CONFIG_HOME")) |config|
                candidates.append(arena, join(arena, &.{ config, "VintagestoryData" }) catch return null) catch return null;
        }
        for (paths) |path| candidates.append(arena, join(arena, &.{ home, path }) catch return null) catch return null;
    }
    for (candidates.items) |candidate| {
        const marker = if (folder == .game) join(arena, &.{ candidate, "assets" }) catch return null else candidate;
        Dir.cwd().access(io, marker, .{}) catch continue;
        return candidate;
    }
    return null;
}
