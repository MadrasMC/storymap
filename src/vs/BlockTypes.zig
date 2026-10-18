//! The blocks the game and its mods define: every block type file in `blocktypes/`, expanded
//! into one block code per variant the way the game does it, with what the map needs to know
//! about each (docs/rendering.md#block-codes). Run once, when preparing; everything is
//! allocated in an arena.
const std = @import("std");
const Io = std.Io;
const Assets = @import("Assets.zig");
const Json = @import("Json.zig");
const Wildcard = @import("Wildcard.zig");

/// One block.
pub const Block = struct {
    /// As a save names it: "rock-granite" in the game's domain, "primitivesurvival:…" in a mod's.
    code: []const u8,
    /// Its block material, one of `materials`, e.g. "Stone".
    material: []const u8,
    /// Which colour of the game's map palette it is, e.g. "land" or "forest": its
    /// `mapColorCode` attribute, or else the default for its material (docs/rendering.md#block-colours).
    colorCode: []const u8,
};

/// The game's block materials (vsapi `EnumBlockMaterial`).
pub const materials = [_][]const u8{
    "Air",   "Soil",   "Gravel", "Sand",  "Wood",    "Leaves", "Stone", "Ore",   "Water", "Snow", "Ice",
    "Metal", "Mantle", "Plant",  "Glass", "Ceramic", "Cloth",  "Lava",  "Brick", "Fire",  "Meta", "Other",
};

/// A block without a material is stone (vsapi `Block.BlockMaterial`).
const defaultMaterial = "Stone";

/// The game map's colour for a material, for blocks without a `mapColorCode`; "land" for the
/// others (vsessentialsmod `ChunkMapLayer.defaultMapColorCodes`).
fn defaultColorCode(material: []const u8) []const u8 {
    const defaults = [_][2][]const u8{
        .{ "Soil", "land" },    .{ "Sand", "desert" },   .{ "Ore", "land" },    .{ "Gravel", "desert" },
        .{ "Stone", "land" },   .{ "Leaves", "forest" }, .{ "Plant", "plant" }, .{ "Wood", "forest" },
        .{ "Snow", "glacier" }, .{ "Water", "lake" },    .{ "Ice", "glacier" }, .{ "Lava", "lava" },
    };
    for (defaults) |pair| if (std.mem.eql(u8, pair[0], material)) return pair[1];
    return "land";
}

/// One variant of a block type: its code, and the state of each variant group that made it.
const Variant = struct {
    code: Location,
    parts: []const Part,
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
        const blockType = expander.blockType(name) catch |err| {
            std.debug.print("storymap: skipping the block type {s}:{s} ({s})\n", .{ name.domain, name.path, @errorName(err) });
            continue;
        };
        var warned = false;
        for (blockType.variants) |variant| {
            const code = variant.code;
            const saved = if (std.mem.eql(u8, code.domain, Assets.gameDomain))
                code.path
            else
                try std.fmt.allocPrint(arena, "{s}:{s}", .{ code.domain, code.path });
            const entry = try seen.getOrPut(arena, saved);
            if (entry.found_existing) continue;
            const look = describe(arena, blockType.json, variant) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => look: {
                    // As the game does, a variant whose …ByType properties can't be resolved
                    // keeps the defaults.
                    if (!warned) std.debug.print("storymap: can't resolve the …ByType properties of {s}:{s} ({s})\n", .{ name.domain, name.path, @errorName(err) });
                    warned = true;
                    break :look Look{ .material = defaultMaterial, .colorCode = defaultColorCode(defaultMaterial) };
                },
            };
            try blocks.append(arena, .{ .code = saved, .material = look.material, .colorCode = look.colorCode });
        }
    }
    return blocks.items;
}

const Look = struct {
    material: []const u8,
    colorCode: []const u8,
};

/// A variant's material and map colour code, from its block type's `blockmaterial` and
/// `attributes.mapColorCode`, after resolving their `…ByType` forms for the variant.
fn describe(arena: std.mem.Allocator, json: Json.Value, variant: Variant) !Look {
    const materialValue = try property(arena, json, "blockmaterial", variant);
    const material = canonicalMaterial(if (materialValue) |m| m.asString() orelse defaultMaterial else defaultMaterial);
    const attributes = try property(arena, json, "attributes", variant);
    const colorCode = if (attributes) |a| if (a.get("mapColorCode")) |c| c.asString() else null else null;
    return .{ .material = material, .colorCode = colorCode orelse defaultColorCode(material) };
}

/// The material named `name`, in the game's spelling, or the default for an unknown one.
fn canonicalMaterial(name: []const u8) []const u8 {
    for (materials) |material| if (std.ascii.eqlIgnoreCase(material, name)) return material;
    return defaultMaterial;
}

/// Property `key` of a block type for one variant, as the game resolves it
/// (vsessentialsmod `RegistryObjectType.solveByType`): `keyByType` gives the value of its
/// first key matching the variant's code, merged into `key` if both are objects; `…ByType`
/// properties inside are resolved the same way, and `{group}` placeholders in strings are
/// filled from the variant. Only `key` and `keyByType` are resolved, as nothing else is needed.
fn property(arena: std.mem.Allocator, json: Json.Value, key: []const u8, variant: Variant) !?Json.Value {
    if (json != .object) return null;
    var fields: std.ArrayList(Json.Field) = .empty;
    for (json.object) |field| {
        const isKey = std.ascii.eqlIgnoreCase(field.key, key);
        const isByType = std.ascii.endsWithIgnoreCase(field.key, byType) and std.ascii.eqlIgnoreCase(field.key[0 .. field.key.len - byType.len], key);
        if (isKey or isByType) try fields.append(arena, field);
    }
    if (fields.items.len == 0) return null;
    const resolved = try solveByType(arena, .{ .object = fields.items }, variant);
    return resolved.get(key);
}

const byType = "byType";

fn solveByType(arena: std.mem.Allocator, value: Json.Value, variant: Variant) !Json.Value {
    switch (value) {
        .object => |fields| {
            var kept: std.ArrayList(Json.Field) = .empty;
            var added: std.ArrayList(Json.Field) = .empty;
            for (fields) |field| {
                if (field.key.len < byType.len or !std.ascii.endsWithIgnoreCase(field.key, byType)) {
                    try kept.append(arena, field);
                    continue;
                }
                if (field.value != .object) return error.InvalidByType;
                for (field.value.object) |candidate| {
                    if (try Wildcard.match(candidate.key, variant.code.path)) {
                        try added.append(arena, .{ .key = field.key[0 .. field.key.len - byType.len], .value = candidate.value });
                        break;
                    }
                }
            }
            for (added.items) |addition| {
                for (kept.items) |*existing| {
                    // The game looks the property up minding case.
                    if (!std.mem.eql(u8, existing.key, addition.key)) continue;
                    existing.value = if (existing.value == .object) try Json.merge(arena, existing.value, addition.value) else addition.value;
                    break;
                } else try kept.append(arena, addition);
            }
            for (kept.items) |*field| field.value = try solveByType(arena, field.value, variant);
            return .{ .object = kept.items };
        },
        .array => |items| {
            const resolved = try arena.alloc(Json.Value, items.len);
            for (resolved, items) |*out, item| out.* = try solveByType(arena, item, variant);
            return .{ .array = resolved };
        },
        .string => |text| return .{ .string = try fillPlaceholders(arena, text, variant.parts) },
        else => return value,
    }
}

/// `text` with each `{group}` placeholder replaced by the variant's state of that group.
/// A placeholder may list alternatives, `{wood|rock}`, and is replaced if any is one of the
/// variant's groups (vsapi `RegistryObject.FillPlaceHolder`).
fn fillPlaceholders(arena: std.mem.Allocator, text: []const u8, parts: []const Part) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '{') == null) return text;
    var current = text;
    for (parts) |part| {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < current.len) {
            if (current[i] == '{') {
                if (std.mem.indexOfAnyPos(u8, current, i + 1, "{}")) |end| if (current[end] == '}') {
                    var names = std.mem.splitScalar(u8, current[i + 1 .. end], '|');
                    const named = while (names.next()) |name| {
                        if (std.mem.eql(u8, name, part.group)) break true;
                    } else false;
                    if (named) {
                        try out.appendSlice(arena, part.state);
                        i = end + 1;
                        continue;
                    }
                };
            }
            try out.append(arena, current[i]);
            i += 1;
        }
        current = out.items;
    }
    return current;
}

test fillPlaceholders {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parts = [_]Part{ .{ .group = "rock", .state = "granite" }, .{ .group = "side", .state = "up" } };
    try std.testing.expectEqualStrings("block/stone/rock/granite1", try fillPlaceholders(arena.allocator(), "block/stone/rock/{rock}1", &parts));
    try std.testing.expectEqualStrings("granite-up", try fillPlaceholders(arena.allocator(), "{wood|rock}-{side}", &parts));
    try std.testing.expectEqualStrings("{wood}", try fillPlaceholders(arena.allocator(), "{wood}", &parts));
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

    /// One block type file and its variants, as RegistryObjectType.CreateBasetype and
    /// ModRegistryObjectTypeLoader.GatherVariants make them.
    fn blockType(self: *Expander, name: Assets.Name) !struct { json: Json.Value, variants: []const Variant } {
        var json = try self.readJson(name.domain, name.path) orelse return error.FileNotFound;
        json = try self.inherit(json, name.domain, 0);
        const base = try Location.parse(self.arena, (json.get("code") orelse return error.NoCode).asString() orelse return error.NoCode, name.domain);
        if (json.get("enabled")) |enabled| if (enabled.isFalse()) return .{ .json = json, .variants = &.{} };

        const groups = json.getArray("variantgroups");
        if (groups.len == 0) return .{ .json = json, .variants = try self.one(base) };
        const skipped = try self.locations(json.get("skipVariants"), name.domain);
        const allowed = try self.locations(json.get("allowedVariants"), name.domain);
        const variants = try self.gather(base, groups, skipped, allowed, name);
        return .{ .json = json, .variants = if (variants.len == 0) try self.one(base) else variants };
    }

    fn one(self: *Expander, code: Location) ![]const Variant {
        const list = try self.arena.alloc(Variant, 1);
        list[0] = .{ .code = code, .parts = &.{} };
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
    fn gather(self: *Expander, base: Location, groups: []const Json.Value, skipped: ?[]const Location, allowed: ?[]const Location, name: Assets.Name) ![]const Variant {
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

        var codes: std.ArrayList(Variant) = .empty;
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
            try codes.append(arena, .{ .code = code, .parts = parts });
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
    return pattern.matches(code) catch |err| {
        std.debug.print("storymap: {s}:{s} filters its variants with the pattern {s}, which can't be read ({s})\n", .{ name.domain, name.path, pattern.path, @errorName(err) });
        return false;
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

test "materials and map colour codes, resolved per variant" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{
            "game/assets/survival/blocktypes/soil.json",
            \\{ code: "soil", variantgroups: [ { code: "kind", states: ["loam", "sand", "leafy", "snowy"] } ],
            \\  blockmaterialByType: { "@soil-(sand)": "sand", "soil-leafy": "Leaves", "*-snowy": "Snow", "*": "soil" },
            \\  attributes: { mapColorCodeByType: { "soil-loam": "{kind}-colour" }, other: 1 },
            \\  attributesByType: { "soil-sand": { mapColorCode: "settlement" } } }
        },
        .{ "game/assets/survival/blocktypes/plain.json", "{ code: 'plain' }" },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var game = try tmp.dir.openDir(io, "game", .{});
    defer game.close(io);
    var assets = try Assets.open(std.testing.allocator, io, game, null);
    defer assets.close(io);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try expand(arena.allocator(), io, &assets);
    const expected = [_][3][]const u8{
        // A placeholder filled from the variant, in a mapColorCode from a nested …ByType.
        .{ "plain", "Stone", "land" },
        .{ "soil-loam", "Soil", "loam-colour" },
        // attributesByType merged into attributes; the regex key picks the material.
        .{ "soil-sand", "Sand", "settlement" },
        // No mapColorCode: the material's default.
        .{ "soil-leafy", "Leaves", "forest" },
        .{ "soil-snowy", "Snow", "glacier" },
    };
    try std.testing.expectEqual(expected.len, blocks.len);
    for (expected) |want| {
        const block = for (blocks) |block| {
            if (std.mem.eql(u8, block.code, want[0])) break block;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want[1], block.material);
        try std.testing.expectEqualStrings(want[2], block.colorCode);
    }
}
