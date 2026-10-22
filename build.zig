const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zstd = b.dependency("zstd", .{});

    const zstd_lib = b.addLibrary(.{
        .name = "zstd",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast, // the lib trips UB checks in Debug and ReleaseSafe
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

    // Each stb implementation is built into the module that uses it.
    const stb = b.dependency("stb", .{});
    const stb_impl = b.addWriteFiles();
    const stb_image_write_impl = stb_impl.add("stb_image_write.c",
        \\#define STB_IMAGE_WRITE_IMPLEMENTATION
        \\#include "stb_image_write.h"
        \\
    );
    const stb_image_impl = stb_impl.add("stb_image.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#define STBI_ONLY_PNG
        \\#define STBI_NO_STDIO
        \\#include "stb_image.h"
        \\
    );

    const stb_translate_c = b.addTranslateC(.{
        .root_source_file = stb.path("stb_image_write.h"),
        .target = target,
        .optimize = optimize,
    });

    const stb_image_translate_c = b.addTranslateC(.{
        .root_source_file = stb.path("stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_image_translate_c.defineCMacroRaw("STBI_NO_STDIO");

    const args_mod = b.createModule(.{
        .root_source_file = b.path("lib/args/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sqlite_mod = b.createModule(.{
        .root_source_file = b.path("lib/sqlite/sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "sqlite3", .module = sqlite3_translate_c.createModule() }},
    });
    sqlite_mod.linkLibrary(sqlite3_lib);

    const protobuf_mod = b.createModule(.{
        .root_source_file = b.path("lib/protobuf/ProtoBuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const options_mod = options.createModule();

    // Storymap's modules. Each is given only the modules it may import, so the renderers can't
    // import the game's reader (CONVENTIONS.md, "Keeping the game apart").

    const tiles_mod = b.createModule(.{
        .root_source_file = b.path("src/tiles/tiles.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "stb_image_write", .module = stb_translate_c.createModule() }},
    });
    tiles_mod.addCSourceFile(.{ .file = stb_image_write_impl });
    tiles_mod.addIncludePath(stb.path("."));

    const world_mod = b.createModule(.{
        .root_source_file = b.path("src/world/world.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tiles", .module = tiles_mod }},
    });

    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/theme/Theme.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "world", .module = world_mod }},
    });

    const viewer_mod = b.createModule(.{
        .root_source_file = b.path("src/viewer/viewer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tiles", .module = tiles_mod },
            .{ .name = "theme", .module = theme_mod },
            .{ .name = "world", .module = world_mod },
        },
    });

    const console_mod = b.createModule(.{
        .root_source_file = b.path("src/console/console.zig"),
        .target = target,
        .optimize = optimize,
    });

    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "world", .module = world_mod },
            .{ .name = "tiles", .module = tiles_mod },
            .{ .name = "theme", .module = theme_mod },
        },
    });

    const vs_mod = b.createModule(.{
        .root_source_file = b.path("src/vs/vs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "world", .module = world_mod },
            .{ .name = "tiles", .module = tiles_mod },
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "protobuf", .module = protobuf_mod },
            .{ .name = "zstd", .module = zstd_translate_c.createModule() },
            .{ .name = "stb_image", .module = stb_image_translate_c.createModule() },
        },
    });
    vs_mod.linkLibrary(zstd_lib);
    vs_mod.addCSourceFile(.{ .file = stb_image_impl });
    vs_mod.addIncludePath(stb.path("."));

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vs", .module = vs_mod },
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "viewer", .module = viewer_mod },
            .{ .name = "theme", .module = theme_mod },
            .{ .name = "console", .module = console_mod },
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "args", .module = args_mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "console", .module = console_mod },
            .{ .name = "args", .module = args_mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });

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

    const bench_cmd = b.addRunArtifact(exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    bench_cmd.addArg("bench");
    bench_cmd.addPassthruArgs();

    const bench_step = b.step("bench", "Time each stage of a render (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&bench_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const tested = [_]*std.Build.Module{
        args_mod,    sqlite_mod,   protobuf_mod, tiles_mod, world_mod, theme_mod, viewer_mod,
        console_mod, renderer_mod, vs_mod,       cli_mod,
    };
    for (tested) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
}
