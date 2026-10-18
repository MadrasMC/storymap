//! The blocks the game and its mods define: every block type file in `blocktypes/`, expanded
//! into one block code per variant the way the game does it (docs/rendering.md#block-codes).
//! Run once, when preparing; everything is allocated in an arena.
const std = @import("std");
const Io = std.Io;
const Assets = @import("Assets.zig");
const Json = @import("Json.zig");
const Wildcard = @import("Wildcard.zig");

/// One block.
pub const Block = struct {
    /// As a save names it: "rock-granite" in the game's domain, "primitivesurvival:…" in a mod's.
    code: []const u8,
    /// The block type file it comes from, e.g. "game:blocktypes/stone/rock.json".
    file: []const u8,
};

/// A code or a world property's name, with its domain, both lowercase.
const Location = struct {
    domain: []const u8,
    path: []const u8,

    /// `text` as "domain:path", or a path in `domain`. Lowercase, as the game makes them.
    fn parse(arena: std.mem.Allocator, text: []const u8, domain: []const u8) !Location {
        const lower = try std.ascii.allocLowerString(arena, text);
        if (std.mem.indexOfScalar(u8, lower, ':')) |colon| return .{ .domain = lower[0..colon], .path = lower[colon + 1 ..] };
        return .{ .domain = domain, .path = lower };
    }

    fn eql(a: Location, b: Location) bool {
        return std.mem.eql(u8, a.domain, b.domain) and std.mem.eql(u8, a.path, b.path);
    }

    /// Whether this wildcard or exact code matches `code`. A domain of `*` matches any.
    fn matches(self: Location, code: Location) !bool {
        if (!Wildcard.isWildcard(self.path)) return self.eql(code);
        if (!std.mem.eql(u8, self.domain, "*") and !std.mem.eql(u8, self.domain, code.domain)) return false;
        return Wildcard.match(self.path, code.path);
    }
};

/// One part of a variant's code, from a variant group: its group and its state.
const Part = struct {
    group: []const u8,
    state: []const u8,
};

/// Every block the game and mods in `assets` define, each code once, in the order of their
/// files. A block type that can't be read is skipped with a warning, as the game skips it.
pub fn expand(arena: std.mem.Allocator, io: Io, assets: *const Assets) ![]const Block {
    var expander: Expander = .{ .arena = arena, .io = io, .assets = assets };
    try expander.loadWorldProperties();

    var blocks: std.ArrayList(Block) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try assets.list(arena, io, "blocktypes")) |name| {
        if (!std.mem.endsWith(u8, name.path, ".json")) continue;
        const codes = expander.blockType(name) catch |err| {
            std.debug.print("storymap: skipping the block type {s}:{s} ({s})\n", .{ name.domain, name.path, @errorName(err) });
            continue;
        };
        const file = try std.fmt.allocPrint(arena, "{s}:{s}", .{ name.domain, name.path });
        for (codes) |code| {
            const saved = if (std.mem.eql(u8, code.domain, Assets.gameDomain))
                code.path
            else
                try std.fmt.allocPrint(arena, "{s}:{s}", .{ code.domain, code.path });
            const entry = try seen.getOrPut(arena, saved);
            if (entry.found_existing) continue;
            try blocks.append(arena, .{ .code = saved, .file = file });
        }
    }
    return blocks.items;
}

const Expander = struct {
    arena: std.mem.Allocator,
    io: Io,
    assets: *const Assets,
    /// World property files by their location ("game:block/rock", for
    /// worldproperties/block/rock.json): the property's code ("game:rock").
    properties: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// A property's variant codes, by the property's code.
    propertyVariants: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn loadWorldProperties(self: *Expander) !void {
        for (try self.assets.list(self.arena, self.io, "worldproperties")) |name| {
            if (!std.mem.endsWith(u8, name.path, ".json")) continue;
            const json = try self.readJson(name.domain, name.path) orelse continue;
            const codeText = (json.get("code") orelse continue).asString() orelse continue;
            const code = try Location.parse(self.arena, codeText, name.domain);
            const key = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ name.domain, name.path["worldproperties/".len .. name.path.len - ".json".len] });
            const codeKey = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ code.domain, code.path });
            var variants: std.ArrayList([]const u8) = .empty;
            for (json.getArray("variants")) |variant| {
                const variantCode = (variant.get("code") orelse continue).asString() orelse continue;
                try variants.append(self.arena, (try Location.parse(self.arena, variantCode, name.domain)).path);
            }
            try self.properties.put(self.arena, key, codeKey);
            try self.propertyVariants.put(self.arena, codeKey, variants.items);
        }
    }

    fn readJson(self: *Expander, domain: []const u8, path: []const u8) !?Json.Value {
        const text = try self.assets.read(self.arena, self.io, domain, path) orelse return null;
        return try Json.parse(self.arena, text);
    }

    /// The codes of one block type file, as RegistryObjectType.CreateBasetype and
    /// ModRegistryObjectTypeLoader.GatherVariants make them.
    fn blockType(self: *Expander, name: Assets.Name) ![]const Location {
        var json = try self.readJson(name.domain, name.path) orelse return error.FileNotFound;
        json = try self.inherit(json, name.domain, 0);
        const base = try Location.parse(self.arena, (json.get("code") orelse return error.NoCode).asString() orelse return error.NoCode, name.domain);
        if (json.get("enabled")) |enabled| if (enabled.isFalse()) return &.{};

        const groups = json.getArray("variantgroups");
        if (groups.len == 0) return self.one(base);
        const skipped = try self.locations(json.get("skipVariants"), name.domain);
        const allowed = try self.locations(json.get("allowedVariants"), name.domain);
        const codes = try self.gather(base, groups, skipped, allowed, name);
        return if (codes.len == 0) self.one(base) else codes;
    }

    fn one(self: *Expander, code: Location) ![]const Location {
        const list = try self.arena.alloc(Location, 1);
        list[0] = code;
        return list;
    }

    /// A block type laid over the file it inherits from (`inheritFrom`), which may inherit too.
    fn inherit(self: *Expander, json: Json.Value, domain: []const u8, depth: usize) !Json.Value {
        const from = (json.get("inheritFrom") orelse return json).asString() orelse return json;
        if (depth == 16) return error.InheritsTooDeep;
        const parent = try Location.parse(self.arena, from, domain);
        const path = if (std.mem.endsWith(u8, parent.path, ".json")) parent.path else try std.fmt.allocPrint(self.arena, "{s}.json", .{parent.path});
        const base = try self.readJson(parent.domain, path) orelse return error.InheritedFileMissing;
        const merged = try Json.merge(self.arena, try self.inherit(base, domain, depth + 1), json);
        if (merged != .object) return merged;
        var fields: std.ArrayList(Json.Field) = .empty;
        for (merged.object) |field| {
            if (!std.ascii.eqlIgnoreCase(field.key, "inheritFrom")) try fields.append(self.arena, field);
        }
        return .{ .object = fields.items };
    }

    fn locations(self: *Expander, value: ?Json.Value, domain: []const u8) !?[]const Location {
        const items = (value orelse return null).asArray();
        const list = try self.arena.alloc(Location, items.len);
        for (list, items) |*location, item| location.* = try Location.parse(self.arena, item.asString() orelse "", domain);
        return list;
    }

    /// Every variant of a block type with variant groups: groups that multiply give every
    /// combination of their states, groups that add give one variant per state.
    fn gather(self: *Expander, base: Location, groups: []const Json.Value, skipped: ?[]const Location, allowed: ?[]const Location, name: Assets.Name) ![]const Location {
        const arena = self.arena;
        var added: std.ArrayList([]const Part) = .empty;
        // Each multiplying group's entries, in the order the groups first appear.
        var multiplied: std.StringArrayHashMapUnmanaged(std.ArrayList([]const Part)) = .empty;

        for (groups) |group| {
            const groupCode = if (group.get("code")) |code| code.asString() else null;
            const combine = if (group.get("combine")) |c| c.asString() orelse "multiply" else "multiply";
            const adds = std.ascii.eqlIgnoreCase(combine, "add");
            const multiplies = std.ascii.eqlIgnoreCase(combine, "multiply");

            // World properties: loadFromProperties, then loadFromPropertiesCombine.
            var propertyNames: std.ArrayList([]const u8) = .empty;
            if (group.get("loadFromProperties")) |p| if (p.asString()) |s| try propertyNames.append(arena, s);
            for (group.getArray("loadFromPropertiesCombine")) |p| {
                if (p.asString()) |s| try propertyNames.append(arena, s);
            }
            for (propertyNames.items) |propertyName| {
                const location = try Location.parse(arena, propertyName, Assets.gameDomain);
                const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ location.domain, location.path });
                const codeKey = self.properties.get(key) orelse {
                    std.debug.print("storymap: {s}:{s} names the world property {s}, which doesn't exist\n", .{ name.domain, name.path, key });
                    break;
                };
                const typeName = groupCode orelse codeKey[std.mem.indexOfScalar(u8, codeKey, ':').? + 1 ..];
                for (self.propertyVariants.get(codeKey).?) |state| {
                    const entry = try onePart(arena, typeName, state);
                    if (adds) try added.append(arena, entry);
                    if (multiplies) {
                        const list = try multiplied.getOrPut(arena, typeName);
                        if (!list.found_existing) list.value_ptr.* = .empty;
                        try list.value_ptr.append(arena, entry);
                    }
                }
            }

            const states = (group.get("states") orelse continue).asArray();
            const code = groupCode orelse continue;
            if (adds) for (states) |state| try added.append(arena, try onePart(arena, code, state.asString() orelse ""));
            if (multiplies) {
                var stateList: std.ArrayList([]const Part) = .empty;
                for (states) |state| try stateList.append(arena, try onePart(arena, code, state.asString() orelse ""));
                try self.selectivelyMultiply(&stateList, groups, code);
                const list = try multiplied.getOrPut(arena, code);
                if (list.found_existing) {
                    // A state list goes before what the group already has.
                    try stateList.appendSlice(arena, list.value_ptr.items);
                }
                list.value_ptr.* = stateList;
            }
        }

        // Every combination of the multiplying groups' entries, the first group varying fastest.
        const lists = multiplied.values();
        var total: usize = if (lists.len == 0) 0 else 1;
        for (lists) |list| total = std.math.mul(usize, total, list.items.len) catch return error.TooManyVariants;
        var variants: std.ArrayList([]const Part) = try .initCapacity(arena, added.items.len + total);
        variants.appendSliceAssumeCapacity(added.items);
        for (0..total) |i| {
            var parts: std.ArrayList(Part) = .empty;
            var index = i;
            for (lists) |list| {
                try parts.appendSlice(arena, list.items[index % list.items.len]);
                index /= list.items.len;
            }
            variants.appendAssumeCapacity(parts.items);
        }

        var codes: std.ArrayList(Location) = .empty;
        next: for (variants.items) |parts| {
            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(arena, base.path);
            for (parts) |part| {
                if (part.state.len == 0) continue;
                try path.append(arena, '-');
                try path.appendSlice(arena, part.state);
            }
            const code: Location = .{ .domain = base.domain, .path = std.ascii.lowerString(path.items, path.items) };
            if (skipped) |patterns| for (patterns) |pattern| {
                if (matchOrWarn(pattern, code, name)) continue :next;
            };
            if (allowed) |patterns| {
                for (patterns) |pattern| {
                    if (matchOrWarn(pattern, code, name)) break;
                } else continue :next;
            }
            try codes.append(arena, code);
        }
        return codes.items;
    }

    /// A selectively multiplying group (`combine: "selectiveMultiply", onVariant: <group>`)
    /// splits the entry of `group` whose code is the selective group's code into one entry
    /// per state of its own. No asset in 1.22.7 or the mods checked uses it.
    fn selectivelyMultiply(self: *Expander, stateList: *std.ArrayList([]const Part), groups: []const Json.Value, group: []const u8) !void {
        for (groups) |selective| {
            const combine = (selective.get("combine") orelse continue).asString() orelse continue;
            if (!std.ascii.eqlIgnoreCase(combine, "selectivemultiply")) continue;
            const onVariant = (selective.get("onVariant") orelse continue).asString() orelse continue;
            if (!std.mem.eql(u8, onVariant, group)) continue;
            const code = (selective.get("code") orelse continue).asString() orelse continue;
            var k: usize = 0;
            while (k < stateList.items.len) : (k += 1) {
                const old = stateList.items[k];
                if (!try codeIs(self.arena, old, code)) continue;
                _ = stateList.orderedRemove(k);
                for (selective.getArray("states")) |state| {
                    const parts = try self.arena.alloc(Part, old.len + 1);
                    @memcpy(parts[0..old.len], old);
                    parts[old.len] = .{ .group = code, .state = state.asString() orelse "" };
                    try stateList.insert(self.arena, k, parts);
                }
            }
        }
    }
};

fn matchOrWarn(pattern: Location, code: Location, name: Assets.Name) bool {
    return pattern.matches(code) catch |err| switch (err) {
        error.RegexUnsupported => {
            std.debug.print("storymap: {s}:{s} filters its variants with the regular expression {s}, which isn't supported yet\n", .{ name.domain, name.path, pattern.path });
            return false;
        },
    };
}

fn onePart(arena: std.mem.Allocator, group: []const u8, state: []const u8) ![]const Part {
    const parts = try arena.alloc(Part, 1);
    parts[0] = .{ .group = group, .state = state };
    return parts;
}

/// Whether an entry's states, joined with "-", are `code`.
fn codeIs(arena: std.mem.Allocator, parts: []const Part, code: []const u8) !bool {
    var joined: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        if (part.state.len == 0) continue;
        if (joined.items.len > 0) try joined.append(arena, '-');
        try joined.appendSlice(arena, part.state);
    }
    return std.mem.eql(u8, joined.items, code);
}

test "variants multiply, add, inherit and filter" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "game/assets/survival/worldproperties/block/rock.json", "{ code: 'rock', variants: [ { code: 'granite' }, { code: 'basalt' } ] }" },
        .{ "game/assets/survival/blocktypes/stone/rock.json", "{ code: 'rock', variantgroups: [ { loadFromProperties: 'block/rock' } ] }" },
        .{
            "game/assets/survival/blocktypes/slab.json",
            \\{ code: "slab",
            \\  variantgroups: [ { code: "rock", loadFromProperties: "block/rock" }, { code: "side", states: ["up", "down"] } ],
            \\  skipVariants: [ "slab-basalt-*" ], }
        },
        .{ "game/assets/survival/blocktypes/torch.json", "{ code: 'torch', variantgroups: [ { code: 'state', states: ['lit', 'out'], combine: 'add' } ] }" },
        .{ "game/assets/survival/blocktypes/off.json", "{ code: 'off', enabled: 0 }" },
        .{ "game/assets/survival/blocktypes/fence.json", "{ code: 'fence', inheritFrom: 'blocktypes/base/fencebase', }" },
        .{ "game/assets/survival/blocktypes/base/fencebase.json", "{ code: 'base', variantgroups: [ { code: 'wood', states: ['oak'] } ] }" },
        .{ "data/Mods/mod/assets/mymod/blocktypes/thing.json", "{ code: 'Thing', variantgroups: [ { code: 'size', states: ['big', ''] } ], allowedVariants: ['thing-big', 'thing'] }" },
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

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try expand(arena.allocator(), io, &assets);
    var codes: std.ArrayList([]const u8) = .empty;
    for (blocks) |block| try codes.append(arena.allocator(), block.code);
    std.mem.sort([]const u8, codes.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    // The base a block type inherits from is in blocktypes/ too, so it's a block type itself.
    const expected = [_][]const u8{
        "base-oak",
        "fence-oak",
        "mymod:thing",
        "mymod:thing-big",
        "rock-basalt",
        "rock-granite",
        "slab-granite-down",
        "slab-granite-up",
        "torch-lit",
        "torch-out",
    };
    try std.testing.expectEqual(expected.len, codes.items.len);
    for (expected, codes.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
