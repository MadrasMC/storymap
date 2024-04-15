const std = @import("std");
const util = @import("./util.zig");
const zstd = @import("zstd");

pub const ArrayConvert = struct {
    pub fn GetRoundedUpSize(value: usize) usize {
        const num1 = value - 1;
        const num2 = num1 | num1 >> 1;
        const num3 = num2 | num2 >> 2;
        const num4 = num3 | num3 >> 4;
        const num5 = num4 | num4 >> 8;
        return (num5 | num5 >> 16) + 1;
    }
};

pub const Compression = struct {
    pub fn DecompressCombined(
        allocator: std.mem.Allocator,
        blocksCompressed: []const u8,
        blocks: *[][]i32,
        refCount: *usize,
    ) !?[]i32 {
        var length1 = util.readI32(blocksCompressed);
        if (length1 == 0) return null;
        var length2: usize = 0;
        const output = if (length1 < 0) b: {
            length1 *= -1;
            length2 = @intCast(@divTrunc(length1, 4));
            if (length2 == 1) return null;
            const out = try allocator.alloc(i32, ArrayConvert.GetRoundedUpSize(length2));
            @memcpy(out, @as(
                [*]align(1) const i32,
                @ptrCast(@alignCast(blocksCompressed.ptr + 4)),
            )[0..out.len]);
            break :b out;
        } else b: {
            var buffer: []u8 = &.{};
            length2 = try Compression.Compression1.DecompressAndSizeOffset(allocator, blocksCompressed, 4, length1, &buffer) / 4;
            defer allocator.free(buffer);
            if (length2 == 1) return null;
            const out = try allocator.alloc(i32, ArrayConvert.GetRoundedUpSize(length2));
            @memcpy(out, @as([*]i32, @ptrCast(@alignCast(buffer.ptr)))[0..out.len]);
            break :b out;
        };
        var count: usize = 0;
        var length3 = output.len;
        while ((length3 >> 1) > 0) : (length3 >>= 1) count += 1;
        if (blocks.len == 0) blocks.* = try allocator.alloc([]i32, 15);
        for (blocks.*) |*block| block.* = &.{};
        const data = try Compression.Compression1.Decompress(
            allocator,
            blocksCompressed,
            length1 + 4,
            @as(i32, @intCast(blocksCompressed.len)) - (length1 + 4),
        );
        defer allocator.free(data);
        if (data.len < count * 1024 * 4) return error.InvalidData;
        var ptr: [*]const i32 = @ptrCast(@alignCast(data.ptr));
        for (0..count) |i| if (blocks.*[i].len == 0) {
            blocks.*[i] = try allocator.alloc(i32, 1024);
            @memcpy(blocks.*[i], ptr[0..1024]);
            ptr += 1024;
        };
        refCount.* = length2;
        return output;
    }
    pub const Compression1 = struct {
        pub fn DecompressAndSizeOffset(
            allocator: std.mem.Allocator,
            compressedData: []const u8,
            offset: i32,
            length: i32,
            buffer: *[]u8,
        ) !usize {
            const compressedFrame = compressedData[@intCast(offset)..@intCast(offset + length)];
            const decompressedSize = zstd.ZSTD_getFrameContentSize(compressedFrame.ptr, compressedFrame.len);
            buffer.* = try allocator.alloc(u8, decompressedSize);
            const decompressor = try ZStdWrapper.CreateDecompressor(allocator);
            defer decompressor.deinit();
            return decompressor.Decompress(buffer.*, compressedFrame);
        }
        pub fn Decompress(allocator: std.mem.Allocator, fi: []const u8, offset: i32, length: i32) ![]u8 {
            var buffer: []u8 = &.{};
            const length1 = try DecompressAndSizeOffset(allocator, fi, offset, length, &buffer);
            defer allocator.free(buffer);
            return allocator.dupe(u8, buffer[0..@intCast(length1)]);
        }
    };
};

pub const ZStdWrapper = struct {
    allocator_ptr: *const std.mem.Allocator,
    dCtx: *zstd.ZSTD_DCtx,
    pub fn Decompress(self: ZStdWrapper, output: []u8, input: []const u8) usize {
        return zstd.ZSTD_decompressDCtx(self.dCtx, output.ptr, output.len, input.ptr, input.len);
    }
    pub fn deinit(self: ZStdWrapper) void {
        _ = zstd.ZSTD_freeDCtx(self.dCtx);
        const allocator = self.allocator_ptr.*;
        allocator.destroy(self.allocator_ptr);
    }

    pub fn CreateDecompressor(allocator: std.mem.Allocator) !ZStdWrapper {
        const allocator_ptr = try allocator.create(std.mem.Allocator);
        allocator_ptr.* = allocator;
        const ZstdAllocator = struct {
            fn alloc(ctx: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
                const ally: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
                const slice = ally.alignedAlloc(u8, 16, size + 16) catch return null;
                @as(*usize, @ptrCast(slice.ptr)).* = slice.len;
                return slice.ptr + 16;
            }
            fn free(ctx: ?*anyopaque, ptr: ?*anyopaque) callconv(.C) void {
                const ally: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
                const base = @as([*]u8, @ptrCast(ptr.?)) - 16;
                const slice = base[0..@as(*const usize, @ptrCast(@alignCast(base))).*];
                ally.free(slice);
            }
        };
        return .{
            .allocator_ptr = allocator_ptr,
            .dCtx = zstd.ZSTD_createDCtx_advanced(.{
                .@"opaque" = allocator_ptr,
                .customAlloc = ZstdAllocator.alloc,
                .customFree = ZstdAllocator.free,
            }).?,
        };
    }
};
