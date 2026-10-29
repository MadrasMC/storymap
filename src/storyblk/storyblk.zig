//! The container of a prepared blocks file (`.storyblk`, docs/storyblk/spec.md): its `header`,
//! `info` and `section_table`, and its sections as bytes, each on a multiple of 8. What the
//! sections hold is left to whoever writes and reads them; the container knows only their
//! names and versions.
//!
//! Every way a file can be invalid is `error.NotPreparedBlocks` (spec §5).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

/// The container's version, `header.version` (spec §7).
pub const version: u8 = 1;

const magic = "STORYBLK";

/// The bytes in `header`, which `header.hash` ends.
const headerLength = 24;

const Header = struct {
    version: u8 = version,
    sectionCount: u16,
    infoLength: u32,
    hash: u64,
};

/// The game, and the mods the file was prepared with.
pub const Info = struct {
    game: []const u8,
    /// Empty if unknown.
    gameVersion: []const u8,
    mods: []const Mod,
};

pub const Mod = struct {
    /// Its zip or folder name in `Mods/`.
    file: []const u8,
    /// Its `modid`, `name` and `version` from its `modinfo.json`: empty where it doesn't give
    /// them, or the mod has none.
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
};

pub const Section = struct {
    name: []const u8,
    layoutVersion: u8,
    generatorVersion: u16,
    /// Without the zeros after it. In a parsed file, where the file is, on a multiple of 8 from
    /// its start.
    bytes: []const u8,
};

/// A parsed file, read in place.
pub const File = struct {
    header: Header,
    info: Info,
    /// In the order of `section_table`, each name once.
    sections: []const Section,

    /// The section `name`, if it has layout version `layoutVersion`.
    pub fn section(self: *const File, name: []const u8, layoutVersion: u8) error{NotPreparedBlocks}!Section {
        for (self.sections) |each| {
            if (std.mem.eql(u8, each.name, name)) return if (each.layoutVersion == layoutVersion) each else error.NotPreparedBlocks;
        }
        return error.NotPreparedBlocks;
    }
};

/// Reads `info`'s or a section's fields one at a time, little-endian, wherever they lie.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn int(self: *Reader, comptime T: type) error{NotPreparedBlocks}!T {
        const size = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, (try self.take(size))[0..size], .little);
    }

    pub fn string(self: *Reader) error{NotPreparedBlocks}![]const u8 {
        return self.take(try self.int(u16));
    }

    pub fn take(self: *Reader, length: usize) error{NotPreparedBlocks}![]const u8 {
        if (length > self.bytes.len - self.at) return error.NotPreparedBlocks;
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }
};

const LimitError = error{ StringTooLong, TooManyMods, TooManySections, SectionTooLong, InfoTooLong };

pub fn writeString(w: *Io.Writer, text: []const u8) (Io.Writer.Error || error{StringTooLong})!void {
    if (text.len > std.math.maxInt(u16)) return error.StringTooLong;
    try w.writeInt(u16, @intCast(text.len), .little);
    try w.writeAll(text);
}

/// The lengths of `info` and of everything before the first section.
const Lengths = struct {
    info: u32,
    beforeSections: u64,
};

/// Checks that every count and length fits its field.
fn measure(info: Info, sections: []const Section) LimitError!Lengths {
    if (info.mods.len > std.math.maxInt(u16)) return error.TooManyMods;
    if (sections.len > std.math.maxInt(u16)) return error.TooManySections;
    var infoLength: u64 = try stringLength(info.game) + try stringLength(info.gameVersion) + 2;
    for (info.mods) |mod| {
        infoLength += try stringLength(mod.file) + try stringLength(mod.id) + try stringLength(mod.name) + try stringLength(mod.version);
    }
    if (infoLength > std.math.maxInt(u32)) return error.InfoTooLong;
    var end = headerLength + infoLength;
    for (sections) |section| {
        if (section.bytes.len > std.math.maxInt(u32)) return error.SectionTooLong;
        end += 8 + 4 + 1 + 2 + try stringLength(section.name);
    }
    return .{ .info = @intCast(infoLength), .beforeSections = end };
}

fn stringLength(text: []const u8) error{StringTooLong}!u64 {
    if (text.len > std.math.maxInt(u16)) return error.StringTooLong;
    return 2 + text.len;
}

/// Writes a whole file of `sections`, each name once, in their order.
fn write(w: *Io.Writer, hash: u64, info: Info, sections: []const Section) (Io.Writer.Error || LimitError)!void {
    const lengths = try measure(info, sections);
    try w.writeAll(magic);
    try w.writeAll(&.{ version, 0 });
    try w.writeInt(u16, @intCast(sections.len), .little);
    try w.writeInt(u32, lengths.info, .little);
    try w.writeInt(u64, hash, .little);

    try writeString(w, info.game);
    try writeString(w, info.gameVersion);
    try w.writeInt(u16, @intCast(info.mods.len), .little);
    for (info.mods) |mod| {
        inline for (.{ "file", "id", "name", "version" }) |field| try writeString(w, @field(mod, field));
    }

    var offset = std.mem.alignForward(u64, lengths.beforeSections, 8);
    for (sections) |section| {
        try w.writeInt(u64, offset, .little);
        try w.writeInt(u32, @intCast(section.bytes.len), .little);
        try w.writeByte(section.layoutVersion);
        try w.writeInt(u16, section.generatorVersion, .little);
        try writeString(w, section.name);
        offset = std.mem.alignForward(u64, offset + section.bytes.len, 8);
    }

    try w.splatByteAll(0, @intCast(std.mem.alignForward(u64, lengths.beforeSections, 8) - lengths.beforeSections));
    for (sections) |section| {
        try w.writeAll(section.bytes);
        try w.splatByteAll(0, std.mem.alignForward(usize, section.bytes.len, 8) - section.bytes.len);
    }
}

/// `header`, from the file's first `headerLength` bytes.
fn parseHeader(bytes: []const u8) error{NotPreparedBlocks}!Header {
    if (bytes.len < headerLength or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.NotPreparedBlocks;
    var reader: Reader = .{ .bytes = bytes[magic.len..headerLength] };
    const headerVersion = try reader.int(u8);
    _ = try reader.take(1);
    const header: Header = .{
        .version = headerVersion,
        .sectionCount = try reader.int(u16),
        .infoLength = try reader.int(u32),
        .hash = try reader.int(u64),
    };
    if (header.version != version) return error.NotPreparedBlocks;
    return header;
}

/// `info`, from its `header.infoLength` bytes. Its strings are in `bytes`.
fn parseInfo(arena: std.mem.Allocator, bytes: []const u8) error{ NotPreparedBlocks, OutOfMemory }!Info {
    var reader: Reader = .{ .bytes = bytes };
    const game = try reader.string();
    const gameVersion = try reader.string();
    const mods = try arena.alloc(Mod, try reader.int(u16));
    for (mods) |*mod| mod.* = .{
        .file = try reader.string(),
        .id = try reader.string(),
        .name = try reader.string(),
        .version = try reader.string(),
    };
    return .{ .game = game, .gameVersion = gameVersion, .mods = mods };
}

/// `header` and `info` from the start of a file, without reading the rest: enough to tell
/// whether to read it.
pub fn readInfo(arena: std.mem.Allocator, reader: *Io.Reader) error{ NotPreparedBlocks, ReadFailed, OutOfMemory }!struct { Header, Info } {
    const start = reader.takeArray(headerLength) catch |err| switch (err) {
        error.EndOfStream => return error.NotPreparedBlocks,
        error.ReadFailed => return error.ReadFailed,
    };
    const header = try parseHeader(start);
    const info = reader.readAllocAll(arena, header.infoLength) catch |err| switch (err) {
        error.EndOfStream => return error.NotPreparedBlocks,
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ header, try parseInfo(arena, info) };
}

/// The file in `bytes`, read in place: they must outlive the result.
pub fn parse(arena: std.mem.Allocator, bytes: []align(8) const u8) error{ NotPreparedBlocks, OutOfMemory }!File {
    const header = try parseHeader(bytes);
    if (header.infoLength > bytes.len - headerLength) return error.NotPreparedBlocks;
    const infoEnd = headerLength + header.infoLength;
    const info = try parseInfo(arena, bytes[headerLength..infoEnd]);

    var table: Reader = .{ .bytes = bytes[infoEnd..] };
    const sections = try arena.alloc(Section, header.sectionCount);
    const offsets = try arena.alloc(u64, header.sectionCount);
    for (sections, offsets) |*section, *offset| {
        offset.* = try table.int(u64);
        const length = try table.int(u32);
        section.* = .{
            .layoutVersion = try table.int(u8),
            .generatorVersion = try table.int(u16),
            .name = try table.string(),
            .bytes = &.{},
        };
        if (offset.* > bytes.len or length > bytes.len - offset.*) return error.NotPreparedBlocks;
        section.bytes = bytes[@intCast(offset.*)..][0..length];
    }
    const tableEnd = infoEnd + table.at;
    for (sections, offsets, 0..) |section, offset, i| {
        if (offset % 8 != 0 or offset < tableEnd) return error.NotPreparedBlocks;
        for (sections[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, section.name)) return error.NotPreparedBlocks;
    }
    return .{ .header = header, .info = info, .sections = sections };
}

/// Writes the file at `path` in `dir` (spec §1): first beside it, as `<path>.<process id>.partial`,
/// then renamed over it, so a write that fails leaves the old file whole. Never replaces a file
/// that isn't a prepared blocks file (`error.NotPreparedBlocks`). Removes partial files of the
/// same name that are over an hour old, which a killed writer leaves behind.
pub fn writeFile(io: Io, dir: Dir, path: []const u8, hash: u64, info: Info, sections: []const Section) !void {
    _ = try measure(info, sections);
    try checkReplaceable(io, dir, path);
    removeOldPartials(io, dir, path);

    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const partial = std.fmt.bufPrint(&buffer, "{s}.{d}.partial", .{ path, processId() }) catch return error.NameTooLong;
    const file = try dir.createFile(io, partial, .{});
    errdefer dir.deleteFile(io, partial) catch {};
    {
        defer file.close(io);
        var fileBuffer: [1 << 16]u8 = undefined;
        var writer = file.writer(io, &fileBuffer);
        write(&writer.interface, hash, info, sections) catch |err| return switch (err) {
            error.WriteFailed => writer.err.?,
            else => |e| e,
        };
        writer.interface.flush() catch return writer.err.?;
    }
    try dir.rename(partial, dir, path, io);
}

fn checkReplaceable(io: Io, dir: Dir, path: []const u8) !void {
    const stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // Renaming a file over a folder fails.
    if (stat.kind == .directory) return;
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var start: [magic.len]u8 = undefined;
    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(&start) catch |err| switch (err) {
        error.EndOfStream => return error.NotPreparedBlocks,
        error.ReadFailed => return reader.err.?,
    };
    if (!std.mem.eql(u8, &start, magic)) return error.NotPreparedBlocks;
}

/// The age at which another writer's partial file counts as left behind.
const partialMaxAge: i64 = 60 * 60;

fn removeOldPartials(io: Io, dir: Dir, path: []const u8) void {
    var folder = dir.openDir(io, std.fs.path.dirname(path) orelse ".", .{ .iterate = true }) catch return;
    defer folder.close(io);
    const name = std.fs.path.basename(path);
    const now = Io.Timestamp.now(io, .real);
    var it = folder.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file or !isPartial(entry.name, name)) continue;
        const stat = folder.statFile(io, entry.name, .{}) catch continue;
        if (stat.mtime.durationTo(now).toSeconds() > partialMaxAge) folder.deleteFile(io, entry.name) catch {};
    }
}

/// Whether `entry` is `<name>.<process id>.partial`.
fn isPartial(entry: []const u8, name: []const u8) bool {
    const suffix = ".partial";
    if (entry.len <= name.len + 1 + suffix.len) return false;
    if (!std.mem.startsWith(u8, entry, name) or entry[name.len] != '.' or !std.mem.endsWith(u8, entry, suffix)) return false;
    for (entry[name.len + 1 .. entry.len - suffix.len]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

const testInfo: Info = .{
    .game = "vintagestory",
    .gameVersion = "1.22.7",
    .mods = &.{
        .{ .file = "primitivesurvival_5.1.4.zip", .id = "primitivesurvival", .name = "Primitive Survival", .version = "5.1.4" },
        .{ .file = "bare-mod" },
    },
};

const testSections = [_]Section{
    .{ .name = "blocks", .layoutVersion = 1, .generatorVersion = 18, .bytes = "five!" },
    .{ .name = "empty", .layoutVersion = 1, .generatorVersion = 18, .bytes = "" },
    .{ .name = "sprites", .layoutVersion = 1, .generatorVersion = 4, .bytes = "sixteen bytes..." },
    // A section from a later Storymap, which a reader that doesn't know it skips.
    .{ .name = "future", .layoutVersion = 7, .generatorVersion = 1, .bytes = "nine byte" },
};

/// `sections` written as a file, in memory aligned as a mapped file is.
fn testFile(allocator: std.mem.Allocator, sections: []const Section) ![]align(8) u8 {
    var file: Io.Writer.Allocating = .init(allocator);
    defer file.deinit();
    try write(&file.writer, 0x0123456789abcdef, testInfo, sections);
    const bytes = try allocator.alignedAlloc(u8, .@"8", file.written().len);
    @memcpy(bytes, file.written());
    return bytes;
}

test "write and parse" {
    const allocator = std.testing.allocator;
    const bytes = try testFile(allocator, &testSections);
    defer allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const file = try parse(arena.allocator(), bytes);
    try std.testing.expectEqual(0x0123456789abcdef, file.header.hash);
    try std.testing.expectEqualDeep(testInfo, file.info);
    try std.testing.expectEqual(0, bytes.len % 8);
    for (testSections, file.sections) |written, read| {
        try std.testing.expectEqualDeep(written, read);
        // On a multiple of 8, with zeros up to the next.
        const offset = @intFromPtr(read.bytes.ptr) - @intFromPtr(bytes.ptr);
        try std.testing.expectEqual(0, offset % 8);
        const end = offset + read.bytes.len;
        try std.testing.expect(std.mem.allEqual(u8, bytes[end..std.mem.alignForward(usize, end, 8)], 0));
    }
    const sprites = try file.section("sprites", 1);
    try std.testing.expectEqual(4, sprites.generatorVersion);
    try std.testing.expectEqualStrings("sixteen bytes...", sprites.bytes);
    // A section that isn't there, or of a layout the reader doesn't know.
    try std.testing.expectError(error.NotPreparedBlocks, file.section("materials", 1));
    try std.testing.expectError(error.NotPreparedBlocks, file.section("future", 1));

    // The header and info alone, read from the start of the file.
    var reader: Io.Reader = .fixed(bytes);
    const header, const info = try readInfo(arena.allocator(), &reader);
    try std.testing.expectEqual(file.header, header);
    try std.testing.expectEqualDeep(testInfo, info);
    var short: Io.Reader = .fixed(bytes[0 .. headerLength + 3]);
    try std.testing.expectError(error.NotPreparedBlocks, readInfo(arena.allocator(), &short));
}

test "invalid files" {
    const allocator = std.testing.allocator;
    const bytes = try testFile(allocator, &testSections);
    defer allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const infoLength = (try parseHeader(bytes)).infoLength;
    // The first section's offset in `section_table`.
    const firstOffset = headerLength + infoLength;

    const Change = struct { at: usize, value: u8 };
    const changes = [_]Change{
        // Not STORYBLK, or another container version.
        .{ .at = 0, .value = 'X' },
        .{ .at = 8, .value = 2 },
        // More sections than the table holds.
        .{ .at = 10, .value = 200 },
        // `info` past the end of the file, or its fields past `info_length`.
        .{ .at = 14, .value = 0xff },
        .{ .at = 12, .value = @truncate(infoLength - 1) },
        // A section not on a multiple of 8, inside the section table, or past the end.
        .{ .at = firstOffset, .value = bytes[firstOffset] + 1 },
        .{ .at = firstOffset, .value = 24 },
        .{ .at = firstOffset + 8 + 2, .value = 1 },
    };
    for (changes) |change| {
        const before = bytes[change.at];
        bytes[change.at] = change.value;
        defer bytes[change.at] = before;
        try std.testing.expectError(error.NotPreparedBlocks, parse(a, bytes));
    }
    try std.testing.expectError(error.NotPreparedBlocks, parse(a, bytes[0 .. headerLength - 1]));
    try std.testing.expectError(error.NotPreparedBlocks, parse(a, bytes[0 .. bytes.len - 8]));

    const twice = [_]Section{ testSections[0], testSections[0] };
    const doubled = try testFile(allocator, &twice);
    defer allocator.free(doubled);
    try std.testing.expectError(error.NotPreparedBlocks, parse(a, doubled));

    // A section's fields past its length.
    var fields: Reader = .{ .bytes = "\x05\x00abc" };
    try std.testing.expectError(error.NotPreparedBlocks, fields.string());
    var short: Reader = .{ .bytes = "\x01\x02\x03" };
    try std.testing.expectError(error.NotPreparedBlocks, short.int(u32));
    try std.testing.expectEqual(0x0201, try short.int(u16));
}

test "counts and lengths that don't fit" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const long: [std.math.maxInt(u16) + 1]u8 = @splat('x');
    try std.testing.expectError(error.StringTooLong, write(&discarding.writer, 0, .{ .game = &long, .gameVersion = "", .mods = &.{} }, &.{}));
    try std.testing.expectError(error.StringTooLong, write(&discarding.writer, 0, testInfo, &.{.{ .name = &long, .layoutVersion = 1, .generatorVersion = 1, .bytes = "" }}));
}

test writeFile {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    try tmp.dir.createDirPath(io, "out");

    // Partial files left behind: an old one, which goes, and a new one, which stays.
    const old = "out/prepared.storyblk.1.partial";
    const new = "out/prepared.storyblk.2.partial";
    try tmp.dir.writeFile(io, .{ .sub_path = new, .data = "" });
    {
        const file = try tmp.dir.createFile(io, old, .{});
        defer file.close(io);
        const now = Io.Timestamp.now(io, .real);
        try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = now.nanoseconds - 2 * std.time.ns_per_hour } } });
    }

    try writeFile(io, tmp.dir, "out/prepared.storyblk", 1, testInfo, testSections[0..2]);
    try writeFile(io, tmp.dir, "out/prepared.storyblk", 2, testInfo, &testSections);
    const bytes = try tmp.dir.readFileAllocOptions(io, "out/prepared.storyblk", allocator, .unlimited, .@"8", null);
    defer allocator.free(bytes);
    const file = try parse(arena.allocator(), bytes);
    try std.testing.expectEqual(2, file.header.hash);
    try std.testing.expectEqual(testSections.len, file.sections.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, old, .{}));
    try tmp.dir.access(io, new, .{});

    // A file that isn't prepared blocks is never replaced.
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "STORYBL" });
    try std.testing.expectError(error.NotPreparedBlocks, writeFile(io, tmp.dir, "notes.txt", 1, testInfo, &testSections));
    const notes = try tmp.dir.readFileAlloc(io, "notes.txt", allocator, .unlimited);
    defer allocator.free(notes);
    try std.testing.expectEqualStrings("STORYBL", notes);

    // A write that fails leaves no partial file behind: here, renaming over a folder.
    try tmp.dir.createDirPath(io, "folder.storyblk");
    try std.testing.expectError(error.IsDir, writeFile(io, tmp.dir, "folder.storyblk", 1, testInfo, &testSections));
    var out = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer out.close(io);
    var it = out.iterate();
    while (try it.next(io)) |entry| try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
}
