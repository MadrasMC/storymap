const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // zstd

    const zstd = b.dependency("zstd", .{});

    const zstd_lib = b.addLibrary(.{
        .name = "zstd",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast, // UB gets hit inside the lib in Debug / Safe, let's just ignore that
            .link_libc = true,
        }),
    });
    zstd_lib.root_module.addCSourceFiles(.{
        .root = zstd.path("lib"),
        .files = &.{
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress_block.c",
            "decompress/zstd_decompress.c",
        },
        .flags = &.{"-DZSTD_DISABLE_ASM=1"},
    });

    const zstd_translate_c = b.addTranslateC(.{
        .root_source_file = zstd.path("lib/zstd.h"),
        .target = target,
        .optimize = optimize,
    });
    zstd_translate_c.defineCMacroRaw("ZSTD_STATIC_LINKING_ONLY");

    exe_mod.addImport("zstd", zstd_translate_c.createModule());
    exe_mod.linkLibrary(zstd_lib);

    // sqlite3

    const sqlite3 = b.dependency("sqlite3", .{});

    const sqlite3_lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sqlite3_lib.root_module.addCSourceFile(.{
        .file = sqlite3.path("sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });

    const sqlite3_translate_c = b.addTranslateC(.{
        .root_source_file = sqlite3.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("sqlite3", sqlite3_translate_c.createModule());
    exe_mod.linkLibrary(sqlite3_lib);

    // stb_image_write

    const stb = b.dependency("stb", .{});

    const stb_impl = b.addWriteFiles().add("stb_image_write.c",
        \\#define STB_IMAGE_WRITE_IMPLEMENTATION
        \\#include "stb_image_write.h"
        \\
    );
    exe_mod.addCSourceFile(.{ .file = stb_impl });
    exe_mod.addIncludePath(stb.path("."));

    const stb_translate_c = b.addTranslateC(.{
        .root_source_file = stb.path("stb_image_write.h"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("stb_image_write", stb_translate_c.createModule());

    // storymap

    const exe = b.addExecutable(.{
        .name = "storymap",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
