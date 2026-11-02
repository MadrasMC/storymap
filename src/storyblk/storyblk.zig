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
pub const version: u8 = 2;

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
    /// Listed but not there yet, for `Appender` to add. It has no bytes.
    reserved: bool = false,
};

/// A parsed file, read in place.
pub const File = struct {
    header: Header,
    info: Info,
    /// In the order of `section_table`, each name once.
    sections: []const Section,

    /// The section `name`, if it's there and has layout version `layoutVersion`.
    pub fn section(self: *const File, name: []const u8, layoutVersion: u8) error{NotPreparedBlocks}!Section {
        for (self.sections) |each| {
            if (std.mem.eql(u8, each.name, name)) return if (each.layoutVersion == layoutVersion and !each.reserved) each else error.NotPreparedBlocks;
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

/// Writes a file of `sections`, each name once, in their order; with `placedLength`, all but the
/// last, which is that long and in the file already (`PartialFile.finish`).
fn write(w: *Io.Writer, hash: u64, info: Info, sections: []const Section, placedLength: ?u32) (Io.Writer.Error || LimitError)!void {
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
    for (sections, 0..) |section, i| {
        const length: u32 = if (i + 1 == sections.len) placedLength orelse @intCast(section.bytes.len) else @intCast(section.bytes.len);
        try w.writeInt(u64, if (section.reserved) 0 else offset, .little);
        try w.writeInt(u32, length, .little);
        try w.writeByte(section.layoutVersion);
        try w.writeInt(u16, section.generatorVersion, .little);
        try writeString(w, section.name);
        offset = std.mem.alignForward(u64, offset + length, 8);
    }

    try w.splatByteAll(0, @intCast(std.mem.alignForward(u64, lengths.beforeSections, 8) - lengths.beforeSections));
    for (if (placedLength != null) sections[0 .. sections.len - 1] else sections) |section| {
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
        section.reserved = offset.* == 0;
        if (section.reserved and length != 0) return error.NotPreparedBlocks;
        if (offset.* > bytes.len or length > bytes.len - offset.*) return error.NotPreparedBlocks;
        section.bytes = bytes[@intCast(offset.*)..][0..length];
    }
    const tableEnd = infoEnd + table.at;
    for (sections, offsets, 0..) |section, offset, i| {
        if (!section.reserved and (offset % 8 != 0 or offset < tableEnd)) return error.NotPreparedBlocks;
        for (sections[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, section.name)) return error.NotPreparedBlocks;
    }
    return .{ .header = header, .info = info, .sections = sections };
}

/// A prepared blocks file being written (spec §1): first beside its path, as
/// `<path>.<process id>.partial`, then renamed over it, so a write that fails leaves the old
/// file whole. Its last section can be written into `file` before the rest, as a section too
/// large to hold in memory is (`lastOffset`).
pub const PartialFile = struct {
    io: Io,
    dir: Dir,
    path: []const u8,
    file: Io.File,
    isOpen: bool = true,
    nameBuffer: [Dir.max_path_bytes]u8,
    nameLength: usize,

    /// Never replaces a file that isn't a prepared blocks file (`error.NotPreparedBlocks`).
    /// Removes partial files of the same name that are over an hour old, which a killed writer
    /// leaves behind.
    pub fn create(io: Io, dir: Dir, path: []const u8) !PartialFile {
        try checkReplaceable(io, dir, path);
        removeOldPartials(io, dir, path);
        var self: PartialFile = .{ .io = io, .dir = dir, .path = path, .file = undefined, .nameBuffer = undefined, .nameLength = 0 };
        self.nameLength = (std.fmt.bufPrint(&self.nameBuffer, "{s}.{d}.partial", .{ path, processId() }) catch return error.NameTooLong).len;
        self.file = try dir.createFile(io, self.name(), .{ .read = true });
        return self;
    }

    fn name(self: *const PartialFile) []const u8 {
        return self.nameBuffer[0..self.nameLength];
    }

    /// Removes the partial file, after a failure.
    pub fn discard(self: *PartialFile) void {
        if (self.isOpen) self.file.close(self.io);
        self.isOpen = false;
        self.dir.deleteFile(self.io, self.name()) catch {};
    }

    /// Writes `sections` and renames the file over its path. With `placedLength`, the last is
    /// that long and in `file` already, at `lastOffset`, and its own `bytes` aren't used.
    pub fn finish(self: *PartialFile, hash: u64, info: Info, sections: []const Section, placedLength: ?u32) !void {
        var buffer: [1 << 16]u8 = undefined;
        var writer = self.file.writer(self.io, &buffer);
        write(&writer.interface, hash, info, sections, placedLength) catch |err| return switch (err) {
            error.WriteFailed => writer.err.?,
            else => |e| e,
        };
        writer.interface.flush() catch return writer.err.?;
        if (placedLength) |length| {
            try self.file.setLength(self.io, std.mem.alignForward(u64, try lastOffset(info, sections) + length, 8));
        }
        self.file.close(self.io);
        self.isOpen = false;
        try self.dir.rename(self.name(), self.dir, self.path, self.io);
    }
};

/// A prepared blocks file having reserved sections added, in place (spec §1). New bytes go past
/// the end of the file, and the table names them only once they're safely on disk, so a write
/// that stops leaves the file as it was, with unused bytes at its end.
pub const Appender = struct {
    io: Io,
    file: Io.File,
    /// Where a section placed before the rest goes.
    start: u64,
    /// Where `section_table` starts, and its entries.
    table: u64,
    sectionCount: u16,

    /// The most bytes in a section's name.
    const maxName = 64;

    pub fn open(io: Io, dir: Dir, path: []const u8) !Appender {
        const file = try dir.openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        var start: [headerLength]u8 = undefined;
        if (try file.readPositionalAll(io, &start, 0) != start.len) return error.NotPreparedBlocks;
        const header = try parseHeader(&start);
        return .{
            .io = io,
            .file = file,
            .start = std.mem.alignForward(u64, (try file.stat(io)).size, 8),
            .table = headerLength + header.infoLength,
            .sectionCount = header.sectionCount,
        };
    }

    /// Gives up, leaving the file's sections as they were.
    pub fn close(self: *Appender) void {
        self.file.close(self.io);
    }

    /// Adds `sections`, which the table must list, and closes the file. With `placedLength`, the
    /// last is that long and in the file already, at `start`, and its own `bytes` aren't used.
    pub fn finish(self: *Appender, sections: []const Section, placedLength: ?u32) !void {
        defer self.close();
        const given = if (placedLength != null) sections[0 .. sections.len - 1] else sections;
        const givenStart = std.mem.alignForward(u64, self.start + (placedLength orelse 0), 8);
        var offset = givenStart;
        for (given) |section| {
            if (section.bytes.len > std.math.maxInt(u32)) return error.SectionTooLong;
            try self.file.writePositionalAll(self.io, section.bytes, offset);
            offset = std.mem.alignForward(u64, offset + section.bytes.len, 8);
        }
        try self.file.setLength(self.io, offset);
        try self.file.sync(self.io);

        offset = givenStart;
        for (given) |section| {
            try self.fill(section.name, offset, @intCast(section.bytes.len));
            offset = std.mem.alignForward(u64, offset + section.bytes.len, 8);
        }
        if (placedLength) |length| try self.fill(sections[sections.len - 1].name, self.start, length);
        try self.file.sync(self.io);
    }

    /// Names section `name`'s `offset` and `length` in the table.
    fn fill(self: *Appender, name: []const u8, offset: u64, length: u32) !void {
        var at = self.table;
        for (0..self.sectionCount) |_| {
            // Offset, length, layout version, generator version and the name's length.
            var entry: [8 + 4 + 1 + 2 + 2]u8 = undefined;
            if (try self.file.readPositionalAll(self.io, &entry, at) != entry.len) return error.NotPreparedBlocks;
            const nameLength = std.mem.readInt(u16, entry[entry.len - 2 ..], .little);
            if (nameLength == name.len) {
                var buffer: [maxName]u8 = undefined;
                const found = buffer[0..nameLength];
                if (try self.file.readPositionalAll(self.io, found, at + entry.len) != found.len) return error.NotPreparedBlocks;
                if (std.mem.eql(u8, found, name)) {
                    var fields: [8 + 4]u8 = undefined;
                    std.mem.writeInt(u64, fields[0..8], offset, .little);
                    std.mem.writeInt(u32, fields[8..12], length, .little);
                    return self.file.writePositionalAll(self.io, &fields, at);
                }
            }
            at += entry.len + nameLength;
        }
        return error.NotPreparedBlocks;
    }
};

/// Where the last of `sections` starts in the file, from the sections before it.
pub fn lastOffset(info: Info, sections: []const Section) LimitError!u64 {
    var offset = std.mem.alignForward(u64, (try measure(info, sections)).beforeSections, 8);
    for (sections[0 .. sections.len - 1]) |section| offset = std.mem.alignForward(u64, offset + section.bytes.len, 8);
    return offset;
}

/// Writes the file at `path` in `dir`, all at once (`PartialFile`).
pub fn writeFile(io: Io, dir: Dir, path: []const u8, hash: u64, info: Info, sections: []const Section) !void {
    _ = try measure(info, sections);
    var partial: PartialFile = try .create(io, dir, path);
    errdefer partial.discard();
    try partial.finish(hash, info, sections, null);
}

/// error.NotPreparedBlocks if there's a file at `path` in `dir` that isn't a prepared blocks
/// file, which `writeFile` never replaces: for checking before the sections are made.
pub fn checkReplaceable(io: Io, dir: Dir, path: []const u8) !void {
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
    try write(&file.writer, 0x0123456789abcdef, testInfo, sections, null);
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
        .{ .at = 8, .value = 9 },
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
    try std.testing.expectError(error.StringTooLong, write(&discarding.writer, 0, .{ .game = &long, .gameVersion = "", .mods = &.{} }, &.{}, null));
    try std.testing.expectError(error.StringTooLong, write(&discarding.writer, 0, testInfo, &.{.{ .name = &long, .layoutVersion = 1, .generatorVersion = 1, .bytes = "" }}, null));
}

test "a last section placed before the rest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    // The file is longer than it'll end up, as one written a window at a time is.
    var partial: PartialFile = try .create(io, tmp.dir, "prepared.storyblk");
    errdefer partial.discard();
    const at = try lastOffset(testInfo, &testSections);
    try partial.file.setLength(io, at + 4096);
    try partial.file.writePositionalAll(io, "nine byte", at);
    var sections = testSections;
    sections[sections.len - 1].bytes = "";
    try partial.finish(1, testInfo, &sections, 9);

    const bytes = try tmp.dir.readFileAllocOptions(io, "prepared.storyblk", allocator, .unlimited, .@"8", null);
    defer allocator.free(bytes);
    const whole = try testFile(allocator, &testSections);
    defer allocator.free(whole);
    // The same but for the hash.
    try std.testing.expectEqualSlices(u8, whole[headerLength..], bytes[headerLength..]);
}

test Appender {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reserved = [_]Section{
        .{ .name = "sprites", .layoutVersion = 1, .generatorVersion = 4, .bytes = "sixteen bytes..." },
        .{ .name = "sprites@90", .layoutVersion = 1, .generatorVersion = 4, .bytes = "", .reserved = true },
        .{ .name = "layers@90", .layoutVersion = 1, .generatorVersion = 4, .bytes = "", .reserved = true },
        .{ .name = "layers", .layoutVersion = 1, .generatorVersion = 4, .bytes = "eight by" },
    };
    try writeFile(io, tmp.dir, "prepared.storyblk", 7, testInfo, &reserved);
    const read = struct {
        fn file(arenaAllocator: std.mem.Allocator, dir: Dir) !File {
            return parse(arenaAllocator, try dir.readFileAllocOptions(std.testing.io, "prepared.storyblk", arenaAllocator, .unlimited, .@"8", null));
        }
    }.file;

    // Listed, but not there yet.
    const before = try read(a, tmp.dir);
    try std.testing.expect(before.sections[1].reserved);
    try std.testing.expectError(error.NotPreparedBlocks, before.section("sprites@90", 1));
    try std.testing.expectEqualStrings("eight by", (try before.section("layers", 1)).bytes);

    // Stopped before the table names them: extra bytes, and the same sections.
    {
        var stopped: Appender = try .open(io, tmp.dir, "prepared.storyblk");
        defer stopped.close();
        try stopped.file.writePositionalAll(io, "pixels left unnamed", stopped.start);
    }
    const unnamed = try read(a, tmp.dir);
    try std.testing.expectError(error.NotPreparedBlocks, unnamed.section("layers@90", 1));
    try std.testing.expectEqualStrings("eight by", (try unnamed.section("layers", 1)).bytes);

    // One written first, as pixels too large to hold are, and one given.
    var appender: Appender = try .open(io, tmp.dir, "prepared.storyblk");
    try appender.file.writePositionalAll(io, "placed!", appender.start);
    try appender.finish(&.{
        .{ .name = "sprites@90", .layoutVersion = 1, .generatorVersion = 4, .bytes = "entries" },
        .{ .name = "layers@90", .layoutVersion = 1, .generatorVersion = 4, .bytes = "" },
    }, 7);

    const after = try read(a, tmp.dir);
    try std.testing.expectEqual(7, after.header.hash);
    try std.testing.expectEqualStrings("entries", (try after.section("sprites@90", 1)).bytes);
    try std.testing.expectEqualStrings("placed!", (try after.section("layers@90", 1)).bytes);
    try std.testing.expectEqualStrings("sixteen bytes...", (try after.section("sprites", 1)).bytes);
    try std.testing.expectEqualStrings("eight by", (try after.section("layers", 1)).bytes);

    // Not in the table.
    var unknown: Appender = try .open(io, tmp.dir, "prepared.storyblk");
    try std.testing.expectError(error.NotPreparedBlocks, unknown.finish(&.{.{ .name = "sprites@45", .layoutVersion = 1, .generatorVersion = 4, .bytes = "x" }}, null));

    // A reserved section with bytes isn't one.
    const bytes = try tmp.dir.readFileAllocOptions(io, "prepared.storyblk", a, .unlimited, .@"8", null);
    const firstOffset = headerLength + (try parseHeader(bytes)).infoLength;
    @memset(bytes[firstOffset..][0..8], 0);
    try std.testing.expectError(error.NotPreparedBlocks, parse(a, bytes));
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
