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

    const stb = b.dependency("stb", .{});
    const stb_image_impl = b.addWriteFiles().add("stb_image.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#define STBI_ONLY_PNG
        \\#define STBI_NO_STDIO
        \\#include "stb_image.h"
        \\
    );

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

    const png_mod = b.createModule(.{
        .root_source_file = b.path("lib/png/png.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libjxl's fast lossless encoder alone, which needs nothing else of libjxl when standalone.
    const libjxl = b.dependency("libjxl", .{});
    const jxl_lib = b.addLibrary(.{
        .name = "jxl_fast_lossless",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        }),
    });
    jxl_lib.root_module.addCSourceFile(.{
        .file = libjxl.path("lib/jxl/enc_fast_lossless.cc"),
        .flags = &.{ "-std=c++17", "-DFJXL_STANDALONE=1" },
    });
    jxl_lib.root_module.addIncludePath(libjxl.path("."));

    const jxl_mod = b.createModule(.{
        .root_source_file = b.path("lib/jxl/jxl.zig"),
        .target = target,
        .optimize = optimize,
    });
    jxl_mod.linkLibrary(jxl_lib);

    // libwebp's encoder, and what it shares with the decoder, without the decoder itself.
    const libwebp = b.dependency("libwebp", .{});
    const webp_lib = b.addLibrary(.{
        .name = "webp_encoder",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    webp_lib.root_module.addCSourceFiles(.{
        .root = libwebp.path("."),
        .files = &.{
            "sharpyuv/sharpyuv.c",                  "sharpyuv/sharpyuv_cpu.c",               "sharpyuv/sharpyuv_csp.c",
            "sharpyuv/sharpyuv_dsp.c",              "sharpyuv/sharpyuv_gamma.c",             "sharpyuv/sharpyuv_neon.c",
            "sharpyuv/sharpyuv_sse2.c",             "src/dsp/alpha_processing.c",            "src/dsp/alpha_processing_neon.c",
            "src/dsp/alpha_processing_sse2.c",      "src/dsp/alpha_processing_sse41.c",      "src/dsp/cpu.c",
            "src/dsp/dec.c",                        "src/dsp/dec_clip_tables.c",             "src/dsp/dec_neon.c",
            "src/dsp/dec_sse2.c",                   "src/dsp/dec_sse41.c",                   "src/dsp/filters.c",
            "src/dsp/filters_neon.c",               "src/dsp/filters_sse2.c",                "src/dsp/lossless.c",
            "src/dsp/lossless_neon.c",              "src/dsp/lossless_sse2.c",               "src/dsp/lossless_sse41.c",
            "src/dsp/rescaler.c",                   "src/dsp/rescaler_neon.c",               "src/dsp/rescaler_sse2.c",
            "src/dsp/upsampling.c",                 "src/dsp/upsampling_neon.c",             "src/dsp/upsampling_sse2.c",
            "src/dsp/upsampling_sse41.c",           "src/dsp/yuv.c",                         "src/dsp/yuv_neon.c",
            "src/dsp/yuv_sse2.c",                   "src/dsp/yuv_sse41.c",                   "src/dsp/cost.c",
            "src/dsp/cost_neon.c",                  "src/dsp/cost_sse2.c",                   "src/dsp/enc.c",
            "src/dsp/enc_neon.c",                   "src/dsp/enc_sse2.c",                    "src/dsp/enc_sse41.c",
            "src/dsp/lossless_enc.c",               "src/dsp/lossless_enc_neon.c",           "src/dsp/lossless_enc_sse2.c",
            "src/dsp/lossless_enc_sse41.c",         "src/dsp/ssim.c",                        "src/dsp/ssim_sse2.c",
            "src/dsp/lossless_avx2.c",              "src/dsp/lossless_enc_avx2.c",
            "src/enc/alpha_enc.c",                  "src/enc/analysis_enc.c",                "src/enc/backward_references_cost_enc.c",
            "src/enc/backward_references_enc.c",    "src/enc/config_enc.c",                  "src/enc/cost_enc.c",
            "src/enc/filter_enc.c",                 "src/enc/frame_enc.c",                   "src/enc/histogram_enc.c",
            "src/enc/iterator_enc.c",               "src/enc/near_lossless_enc.c",           "src/enc/picture_enc.c",
            "src/enc/picture_csp_enc.c",            "src/enc/picture_psnr_enc.c",            "src/enc/picture_rescale_enc.c",
            "src/enc/picture_tools_enc.c",          "src/enc/predictor_enc.c",               "src/enc/quant_enc.c",
            "src/enc/syntax_enc.c",                 "src/enc/token_enc.c",                   "src/enc/tree_enc.c",
            "src/enc/vp8l_enc.c",                   "src/enc/webp_enc.c",                    "src/utils/bit_reader_utils.c",
            "src/utils/color_cache_utils.c",        "src/utils/filters_utils.c",             "src/utils/huffman_utils.c",
            "src/utils/palette.c",                  "src/utils/quant_levels_dec_utils.c",    "src/utils/random_utils.c",
            "src/utils/rescaler_utils.c",           "src/utils/thread_utils.c",              "src/utils/utils.c",
            "src/utils/bit_writer_utils.c",         "src/utils/huffman_encode_utils.c",      "src/utils/quant_levels_utils.c",
        },
    });
    webp_lib.root_module.addIncludePath(libwebp.path("."));
    webp_lib.root_module.addIncludePath(libwebp.path("src"));

    const webp_translate_c = b.addTranslateC(.{
        .root_source_file = libwebp.path("src/webp/encode.h"),
        .target = target,
        .optimize = optimize,
    });
    const webp_mod = b.createModule(.{
        .root_source_file = b.path("lib/webp/webp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "encode", .module = webp_translate_c.createModule() }},
    });
    webp_mod.linkLibrary(webp_lib);

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const options_mod = options.createModule();

    // Storymap's modules. Each is given only the modules it may import, so the renderers can't
    // import the game's reader (CONVENTIONS.md, "Keeping the game apart").

    const tiles_mod = b.createModule(.{
        .root_source_file = b.path("src/tiles/tiles.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "png", .module = png_mod },
            .{ .name = "jxl", .module = jxl_mod },
            .{ .name = "webp", .module = webp_mod },
        },
    });

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
            .{ .name = "console", .module = console_mod },
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
            .{ .name = "tiles", .module = tiles_mod },
            .{ .name = "console", .module = console_mod },
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

    const test_step = b.step("test", "Run unit tests");
    const tested = [_]*std.Build.Module{
        args_mod,    sqlite_mod,   protobuf_mod, png_mod, jxl_mod, webp_mod, tiles_mod, world_mod, theme_mod, viewer_mod,
        console_mod, renderer_mod, vs_mod,       cli_mod,
    };
    for (tested) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
}
