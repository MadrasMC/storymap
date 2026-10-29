//! Climate and season tint: grass, leaves and water take a colour from a climate map by
//! temperature and rainfall, mixed with one from a season map by the time of year
//! (docs/blocks.md#climate-and-season-tint). Follows the game's world shader,
//! `shaderincludes/colormap.vsh` and `.fsh`, as its map does this in closed code.
const std = @import("std");
const world = @import("world");
const stb = @import("stb_image");

const Rgb = world.Rgb;

/// White, which leaves a colour as it is.
pub const none: Rgb = .{ 255, 255, 255 };

/// One of the game's colour maps (`config/colormaps.json`): an image a block's colour is
/// multiplied by.
pub const ColourMap = struct {
    /// E.g. "climatePlantTint".
    code: []const u8,
    width: usize,
    height: usize,
    /// Row by row. A climate map runs from cold to warm across and from dry to wet down; a
    /// season map through the year across.
    pixels: []const Rgb,
    /// Pixels around the edge that aren't part of the map.
    padding: usize = 0,
    /// A tropical season map (`extraFlags` 1), weighted by rainfall rather than temperature.
    tropical: bool = false,

    /// Null if the PNG can't be decoded or is all padding.
    pub fn decode(arena: std.mem.Allocator, code: []const u8, png: []const u8, padding: usize, tropical: bool) !?ColourMap {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const data = stb.stbi_load_from_memory(png.ptr, @intCast(png.len), &width, &height, &channels, 3) orelse return null;
        defer stb.stbi_image_free(data);
        const count: usize = @intCast(width * height);
        if (width <= 2 * padding or height <= 2 * padding) return null;
        const pixels = try arena.alloc(Rgb, count);
        @memcpy(std.mem.sliceAsBytes(pixels), data[0 .. count * 3]);
        return .{ .code = code, .width = @intCast(width), .height = @intCast(height), .pixels = pixels, .padding = padding, .tropical = tropical };
    }

    /// The colour at (`across`, `down`), each from 0 to 1 within the padding.
    fn at(self: ColourMap, across: f32, down: f32) Rgb {
        const innerWidth: f32 = @floatFromInt(self.width - 2 * self.padding);
        const innerHeight: f32 = @floatFromInt(self.height - 2 * self.padding);
        const x = self.padding + @min(@as(usize, @intFromFloat(across * innerWidth)), self.width - 2 * self.padding - 1);
        const y = self.padding + @min(@as(usize, @intFromFloat(down * innerHeight)), self.height - 2 * self.padding - 1);
        return self.pixels[y * self.width + x];
    }

    /// A season map's colour at `progress` through the year, averaged down its rows: the
    /// shader picks a row by noise at each place, which averages out over an area.
    fn seasonAt(self: ColourMap, progress: f32) Rgb {
        const x = @min(@as(usize, @intFromFloat(std.math.clamp(progress, 0.01, 0.99) * @as(f32, @floatFromInt(self.width)))), self.width - 1);
        var sums: [3]u32 = .{ 0, 0, 0 };
        for (0..self.height) |y| {
            for (&sums, self.pixels[y * self.width + x]) |*sum, channel| sum.* += channel;
        }
        var out: Rgb = undefined;
        for (&out, sums) |*channel, sum| channel.* = @intCast(sum / self.height);
        return out;
    }
};

/// The climate at a place, as the game keeps it: temperature and rainfall, each 0 to 255.
pub const Climate = struct {
    temperature: f32,
    rainfall: f32,
};

/// A map region's climate map (field 3 of a map region, docs/save-format/README.md#8-map-regions):
/// a grid of packed values over the region, temperature in bits 16–23 and rainfall in
/// bits 8–15, with padding from the regions around it.
pub const ClimateMap = struct {
    /// `size` × `size`, row by row.
    values: []i32,
    size: usize = 0,
    padding: usize = 0,
    innerSize: usize = 0,

    /// The largest grid read; the game's is 20 × 20.
    pub const maxSize = 64;

    /// Reads an `IntDataMap2D` message into `values`, which holds `maxSize` × `maxSize`. False
    /// if it doesn't fit or is incomplete.
    pub fn decode(self: *ClimateMap, message: []const u8) !bool {
        const ProtoBuf = @import("protobuf");
        var count: usize = 0;
        var bottomRight: usize = 0;
        self.padding = 0;
        self.size = 0;
        var parser: ProtoBuf = .{ .buf = message };
        while (try parser.next()) |field| switch (field.field_number) {
            1 => switch (field.data) {
                .LEN => |bytes| {
                    var values: ProtoBuf = .{ .buf = bytes };
                    while (values.cur < bytes.len) : (count += 1) {
                        if (count == self.values.len) return false;
                        self.values[count] = @truncate(@as(i64, @bitCast(try values.parseVarInt())));
                    }
                },
                .VARINT => |value| {
                    if (count == self.values.len) return false;
                    self.values[count] = @truncate(@as(i64, @bitCast(value)));
                    count += 1;
                },
                else => {},
            },
            2 => if (field.data == .VARINT) {
                self.size = field.data.VARINT;
            },
            3 => if (field.data == .VARINT) {
                self.padding = field.data.VARINT;
            },
            4 => if (field.data == .VARINT) {
                bottomRight = field.data.VARINT;
            },
            else => {},
        };
        if (self.size == 0 or self.size > maxSize or count != self.size * self.size) return false;
        if (self.padding + bottomRight >= self.size or bottomRight == 0) return false;
        self.innerSize = self.size - self.padding - bottomRight;
        return true;
    }

    /// `x` and `z` run from 0 to 1 across the region. Interpolated between the four values
    /// around, each channel rounded down (vsapi `IntDataMap2D.GetUnpaddedColorLerped`).
    pub fn at(self: ClimateMap, x: f32, z: f32) Climate {
        const fx = x * @as(f32, @floatFromInt(self.innerSize));
        const fz = z * @as(f32, @floatFromInt(self.innerSize));
        const ix: usize = @intFromFloat(fx);
        const iz: usize = @intFromFloat(fz);
        const tx = fx - @as(f32, @floatFromInt(ix));
        const tz = fz - @as(f32, @floatFromInt(iz));
        const i = (iz + self.padding) * self.size + ix + self.padding;
        const corners = [4]i32{ self.values[i], self.values[i + 1], self.values[i + self.size], self.values[i + self.size + 1] };
        return .{ .temperature = lerped(corners, 16, tx, tz), .rainfall = lerped(corners, 8, tx, tz) };
    }

    fn lerped(corners: [4]i32, shift: u5, tx: f32, tz: f32) f32 {
        var c: [4]f32 = undefined;
        for (&c, corners) |*out, value| out.* = @floatFromInt((value >> shift) & 0xff);
        const top = c[0] + (c[1] - c[0]) * tx;
        const bottom = c[2] + (c[3] - c[2]) * tx;
        return @floor(top + (bottom - top) * tz);
    }
};

/// The tint at height `y`, where `here` is the climate at ground level and `progress` the time
/// of year. As in the game's shader, temperature falls and rainfall changes with height (vsapi
/// `Climate.GetAdjustedTemperature` and `GetRainFall`); the climate map gives a colour by them,
/// and the season map's colour is mixed in, more where it's cold.
pub fn tint(climate: ?*const ColourMap, season: ?*const ColourMap, here: Climate, y: i32, sea: i32, progress: f32) Rgb {
    const above: f32 = @floatFromInt(y - sea);
    const temperature = std.math.clamp(here.temperature - above / 1.5, 0, 255);
    const rainfall = std.math.clamp(here.rainfall + @as(f32, @floatFromInt(@divTrunc(y - sea, 2) + 5 * std.math.clamp(8 - (y - sea), 0, 8))), 0, 255);
    const temperatureRel = std.math.clamp(temperature / 255, 0.001, 0.999);
    const rainfallRel = std.math.clamp(rainfall / 255, 0.001, 0.999);

    var out: [3]f32 = .{ 255, 255, 255 };
    if (climate) |map| {
        const colour = map.at(temperatureRel, rainfallRel);
        for (&out, colour) |*channel, value| channel.* = @floatFromInt(value);
    }
    if (season) |map| {
        const weight = if (map.tropical)
            std.math.clamp(temperatureRel * 0.9 - 0.1, 0, 1) * std.math.clamp(2 * (0.5 - @cos(rainfallRel * 255 / 42)) / 2.1, 0.1, 0.75)
        else weight: {
            // By the temperature at ground level, undoing the height's.
            const x = temperatureRel * 255 + @max(0, above * 1.5);
            break :weight std.math.clamp(0.5 - @cos(x / 42) / 2.3 + @max(0, 128 - x) / 256 / 2 - @max(0, x - 130) / 200, 0, 1);
        };
        const colour = map.seasonAt(progress);
        for (&out, colour) |*channel, value| channel.* += (@as(f32, @floatFromInt(value)) - channel.*) * weight;
    }
    var result: Rgb = undefined;
    for (&result, out) |*channel, value| channel.* = @intFromFloat(std.math.clamp(@round(value), 0, 255));
    return result;
}

test tint {
    // A 2 × 2 climate map without padding: cold and dry is red, warm and dry green, cold and
    // wet blue, warm and wet white.
    const climatePixels = [_]Rgb{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 255 } };
    const climate: ColourMap = .{ .code = "c", .width = 2, .height = 2, .pixels = &climatePixels };
    // At sea level, warm and dry: green. Rainfall at sea level gains 40.
    try std.testing.expectEqual(Rgb{ 0, 255, 0 }, tint(&climate, null, .{ .temperature = 200, .rainfall = 50 }, 110, 110, 0));
    // Higher up it's colder: 150 blocks up takes 100 off the temperature.
    try std.testing.expectEqual(Rgb{ 255, 0, 0 }, tint(&climate, null, .{ .temperature = 200, .rainfall = 0 }, 260, 110, 0));
    try std.testing.expectEqual(Rgb{ 255, 255, 255 }, tint(null, null, .{ .temperature = 0, .rainfall = 0 }, 110, 110, 0));

    // A season map black in the first half of the year and white in the second, two rows.
    const seasonPixels = [_]Rgb{ .{ 0, 0, 0 }, .{ 255, 255, 255 }, .{ 0, 0, 0 }, .{ 255, 255, 255 } };
    const season: ColourMap = .{ .code = "s", .width = 2, .height = 2, .pixels = &seasonPixels };
    // Mild places are mostly season; the climate's white shows a little.
    const spring = tint(null, &season, .{ .temperature = 100, .rainfall = 100 }, 110, 110, 0.25);
    const autumn = tint(null, &season, .{ .temperature = 100, .rainfall = 100 }, 110, 110, 0.75);
    try std.testing.expect(spring[0] < 64 and spring[0] > 0);
    try std.testing.expectEqual(Rgb{ 255, 255, 255 }, autumn);
}

test "ClimateMap.at" {
    var values: [ClimateMap.maxSize * ClimateMap.maxSize]i32 = undefined;
    // A 3 × 3 grid with one row and column of padding at the bottom right, its inner 2 × 2:
    // temperatures 0, 100 / 50, 150, rainfall 10 everywhere.
    const grid = [_]i32{ 0 << 16 | 10 << 8, 100 << 16 | 10 << 8, 100 << 16 | 10 << 8, 50 << 16 | 10 << 8, 150 << 16 | 10 << 8, 150 << 16 | 10 << 8, 50 << 16 | 10 << 8, 150 << 16 | 10 << 8, 150 << 16 | 10 << 8 };
    @memcpy(values[0..grid.len], &grid);
    const map: ClimateMap = .{ .values = &values, .size = 3, .padding = 0, .innerSize = 2 };
    try std.testing.expectEqual(Climate{ .temperature = 0, .rainfall = 10 }, map.at(0, 0));
    // Halfway between 0 and 100, and between 50 and 150, then between those.
    try std.testing.expectEqual(Climate{ .temperature = 75, .rainfall = 10 }, map.at(0.25, 0.25));
}
