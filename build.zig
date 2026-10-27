const std = @import("std");
const builtin = @import("builtin");

// The Zig version this code targets. build.zig.zon is the one place that names
// it (minimum_zig_version). Zig changes its std API between minor versions, so
// a different major.minor stops the build here with one clear error, before
// the API errors. The minecraft dockerfile reads the same field.
const zig_target = blk: {
    const zon = @embedFile("build.zig.zon");
    const key = ".minimum_zig_version = \"";
    const start = (std.mem.indexOf(u8, zon, key) orelse
        @compileError("build.zig.zon has no minimum_zig_version")) + key.len;
    const end = std.mem.indexOfScalarPos(u8, zon, start, '"').?;
    break :blk std.SemanticVersion.parse(zon[start..end]) catch
        @compileError("build.zig.zon: minimum_zig_version is not a version");
};

comptime {
    const have = builtin.zig_version;
    if (have.major != zig_target.major or have.minor != zig_target.minor) {
        @compileError(std.fmt.comptimePrint(
            "swindowzig needs Zig {d}.{d}.x (minimum_zig_version in build.zig.zon). This is Zig {s}.",
            .{ zig_target.major, zig_target.minor, builtin.zig_version_string },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build option to select which example to build
    const example_name = b.option(
        []const u8,
        "example",
        "Which example to build (default: windows)",
    ) orelse "justabox";

    // Which platform the exported modules (sw_app, sw_platform, ...) use. A
    // dependent package gets web by default: no SDL, no system libraries.
    const platform = b.option(
        Platform,
        "platform",
        "Platform of the exported modules: web (default, no SDL) or native (SDL2)",
    ) orelse .web;

    // The exported modules. `b.addModule` makes them importable from a
    // dependent package.
    const exported_sdl: ?*std.Build.Module = if (platform == .native) blk: {
        const sdl_c = b.addTranslateC(.{
            .root_source_file = b.path("libs/sw_platform/src/sdl.h"),
            .target = target,
            .optimize = optimize,
        });
        if (target.result.os.tag == .macos) sdl_c.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        break :blk sdl_c.createModule();
    } else null;
    const exported = addLibs(b, exported_sdl, true);

    // A dependent package stops here. The examples, steps and tests below
    // belong to this package alone, and they need HOME and SDL.
    if (b.dep_prefix.len != 0) return;

    // The web build gets its own set of library modules, with no SDL. The
    // minecraft dockerfile has no SDL headers.
    const web_libs = if (platform == .web) exported else addLibs(b, null, false);

    // Example app - WASM build
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Construct path to example (try src/main.zig first, then main.zig)
    const example_path = blk: {
        const src_path = b.fmt("examples/{s}/src/main.zig", .{example_name});
        const root_path = b.fmt("examples/{s}/main.zig", .{example_name});

        // Check if src/main.zig exists
        b.root.access(b.graph.io, src_path, .{}) catch {
            // Fall back to root main.zig
            break :blk root_path;
        };
        break :blk src_path;
    };

    const example = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_path),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("sw_app", web_libs.app);
    example.root_module.addImport("sw_math", web_libs.math);
    example.root_module.addImport("sw_gpu", web_libs.gpu);
    example.root_module.addImport("sw_core", web_libs.core);
    example.root_module.addImport("sw_gfx2d", web_libs.gfx2d);
    example.root_module.addImport("sw_text", web_libs.text);
    example.root_module.addImport("sw_ui", web_libs.ui);
    example.root_module.addImport("sw_assets", web_libs.assets);
    example.root_module.addImport("sw_render", web_libs.render);
    // sw_platform is needed by examples that drive their own wasm entry
    // (e.g. voxel, which constructs a WasmBackend directly in its
    // swindowzig_init export).
    example.root_module.addImport("sw_platform", web_libs.platform);
    // The voxel demo: sw_voxel with the demo content (examples/voxel/content.zig).
    const web_voxel = addVoxel(b, web_libs.gpu, .{ .root_source_file = b.path("libs/sw_voxel/src/sw_voxel.zig") }, .{ .root_source_file = b.path("examples/voxel/content.zig") });
    example.root_module.addImport("sw_voxel", web_voxel.voxel);
    example.root_module.addImport("voxel_content", web_voxel.content);
    example.rdynamic = true; // Export symbols for WASM
    // Voxel's Chunk.init() constructs a stack-allocated struct value.
    // At CHUNK_W=16: 16×256×16 blocks + skylight ≈ 128 KB. At CHUNK_W=48
    // (the old size) it was ~1.17 MB. Keep 16 MB for headroom — recursive
    // meshing + several chunk call frames can still stack up.
    example.stack_size = 16 * 1024 * 1024;

    const install_example = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_example.step);

    // The build id of the voxel web pair (C9): app.wasm and chunks.wasm
    // export it, and the worker pool starts only when the two are equal.
    const chunk_build = b.addOptions();
    chunk_build.addOption(u64, "id", voxelBuildId(b));
    example.root_module.addOptions("chunk_build", chunk_build);

    // chunks.wasm: the chunk worker of the Web Worker pool (C9). Its only
    // wasm imports are the clock and the log. It has no GPU code.
    const chunks_wasm = b.addExecutable(.{
        .name = "chunks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/chunks_wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .single_threaded = true,
            // Each Web Worker downloads it: no debug info in a release.
            .strip = optimize != .debug,
        }),
    });
    // sw_voxel takes the AO and lighting enums from sw_gpu. They are types
    // only: chunks.wasm imports no WebGPU function.
    chunks_wasm.root_module.addImport("sw_voxel", web_voxel.voxel);
    chunks_wasm.root_module.addOptions("chunk_build", chunk_build);
    chunks_wasm.entry = .disabled;
    chunks_wasm.rdynamic = true;
    // The light stage scratch is on the heap. The stages use a small stack.
    chunks_wasm.stack_size = 16 * 1024 * 1024;
    const install_chunks = b.addInstallArtifact(chunks_wasm, .{});

    // Web build step. The voxel web build also installs chunks.wasm.
    const web_step_desc = b.fmt("Build '{s}' example for web (WASM)", .{example_name});
    const web_step = b.step("web", web_step_desc);
    web_step.dependOn(&install_example.step);
    if (std.mem.eql(u8, example_name, "voxel")) web_step.dependOn(&install_chunks.step);

    // Native executable (for SDL2/desktop). This step translates the SDL2
    // headers and gives them to sw_platform as the "sdl" module.
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("libs/sw_platform/src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) sdl_c.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    const native_libs = if (platform == .native) exported else addLibs(b, sdl_c.createModule(), false);

    const native_exe = b.addExecutable(.{
        .name = b.fmt("{s}", .{example_name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_path),
            .target = target,
            .optimize = optimize,
        }),
    });
    native_exe.root_module.addImport("sw_app", native_libs.app);
    native_exe.root_module.addImport("sw_math", native_libs.math);
    native_exe.root_module.addImport("sw_gpu", native_libs.gpu);
    native_exe.root_module.addImport("sw_core", native_libs.core);
    native_exe.root_module.addImport("sw_gfx2d", native_libs.gfx2d);
    native_exe.root_module.addImport("sw_text", native_libs.text);
    native_exe.root_module.addImport("sw_ui", native_libs.ui);
    native_exe.root_module.addImport("sw_assets", native_libs.assets);
    native_exe.root_module.addImport("sw_render", native_libs.render);
    native_exe.root_module.addOptions("chunk_build", chunk_build);
    const native_voxel = addVoxel(b, native_libs.gpu, .{ .root_source_file = b.path("libs/sw_voxel/src/sw_voxel.zig") }, .{ .root_source_file = b.path("examples/voxel/content.zig") });
    native_exe.root_module.addImport("sw_voxel", native_voxel.voxel);
    native_exe.root_module.addImport("voxel_content", native_voxel.content);

    // Link SDL2 for native builds.
    native_exe.root_module.linkSystemLibrary("SDL2", .{});
    native_exe.root_module.link_libc = true;

    // Link wgpu-native from ~/.local
    const home = b.graph.environ_map.get("HOME") orelse @panic("HOME is not set");
    const wgpu_lib_path = std.fs.path.join(b.allocator, &[_][]const u8{ home, ".local", "lib" }) catch unreachable;
    const wgpu_include_path = std.fs.path.join(b.allocator, &[_][]const u8{ home, ".local", "include" }) catch unreachable;

    native_exe.root_module.addLibraryPath(.{ .cwd_relative = wgpu_lib_path });
    native_exe.root_module.addIncludePath(.{ .cwd_relative = wgpu_include_path });
    native_exe.root_module.linkSystemLibrary("wgpu_native", .{});

    // Platform-specific frameworks
    if (target.result.os.tag == .macos) {
        native_exe.root_module.linkFramework("Metal", .{});
        native_exe.root_module.linkFramework("QuartzCore", .{});
        native_exe.root_module.linkFramework("Foundation", .{});
        native_exe.root_module.linkFramework("IOKit", .{});
        native_exe.root_module.linkFramework("IOSurface", .{});
    }

    // libwgpu_native.a is a Rust static library and needs the _Unwind_*
    // symbols. libSystem supplies them on macOS. On Linux, libc++ brings
    // the libunwind that Zig bundles.
    if (target.result.os.tag == .linux) {
        native_exe.root_module.link_libcpp = true;
    }

    const install_native = b.addInstallArtifact(native_exe, .{});

    // Native build step
    const native_step_desc = b.fmt("Build '{s}' example for native", .{example_name});
    const native_step = b.step("native", native_step_desc);
    native_step.dependOn(&install_native.step);

    // Run step
    const run_cmd = b.addRunArtifact(native_exe);
    run_cmd.step.dependOn(&install_native.step);
    run_cmd.addPassthruArgs();

    const run_step_desc = b.fmt("Run '{s}' example natively", .{example_name});
    const run_step = b.step("run", run_step_desc);
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "libs/sw_core/src/event.zig",
        "libs/sw_core/src/bus.zig",
        "libs/sw_core/src/timeline.zig",
        "libs/sw_core/src/input.zig",
        "libs/sw_core/src/serialize.zig",
        "libs/sw_core/src/record.zig",
        "libs/sw_core/src/replay.zig",
        "libs/sw_core/src/tas.zig",
        "libs/sw_core/src/action.zig",
        "libs/sw_platform/src/storage.zig",
        // sw_platform: the DPI scale and the window and cursor mode numbers.
        "libs/sw_platform/src/platform.zig",
        // sw_platform: the gamepad slots and the SDL axis scaling.
        "libs/sw_platform/src/gamepad.zig",
        // sw_gpu: the mip chain maths and the descriptor checks have no
        // GPU code.
        "libs/sw_gpu/src/mip_chain.zig",
        "libs/sw_gpu/src/types.zig",
        "libs/sw_gpu/src/fxaa.zig",
        // sw_gfx2d: the batching and the projection maths have no GPU code.
        "libs/sw_gfx2d/src/batch.zig",
        "libs/sw_gfx2d/src/projection.zig",
        // sw_text: UTF-8, measuring and wrapping, the atlas packer, the
        // bidirectional algorithm and the caret geometry.
        "libs/sw_text/src/utf8.zig",
        "libs/sw_text/src/layout.zig",
        "libs/sw_text/src/atlas.zig",
        "libs/sw_text/src/bidi.zig",
        "libs/sw_text/src/caret.zig",
        // sw_ui: the tree, layout, focus, semantic tree, on-screen keyboard
        // and screen stack have no GPU or font code. draw.zig is built with
        // the examples.
        "libs/sw_ui/src/ui.zig",
        "libs/sw_ui/src/osk.zig",
        "libs/sw_ui/src/screen.zig",
        // sw_audio: the sample type and the WAV decoder.
        "libs/sw_audio/src/sample.zig",
        "libs/sw_audio/src/wav.zig",
        // sw_render: the frame timing of animated sprites.
        "libs/sw_render/src/animation.zig",
        // sw_math: vectors, matrices, quaternions, boxes, rays and planes.
        "libs/sw_math/src/math_root.zig",
    };

    // sw_assets: byte loading and PNG decoding. The PNG decoder is C
    // (stb_image), so these tests link libc.
    const assets_test_files = [_][]const u8{
        "libs/sw_assets/src/assets.zig",
        "libs/sw_assets/src/png.zig",
    };
    inline for (assets_test_files) |file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        addAssetsC(b, unit_tests.root_module);
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    // sw_assets: the zip reader reads archives that the zip tool made
    // (libs/sw_assets/testdata). The player files and the cache test their
    // native backends.
    const zip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/sw_assets/src/zip.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zip_tests.root_module.addAnonymousImport("test_zip_standard", .{ .root_source_file = b.path("libs/sw_assets/testdata/standard.zip") });
    zip_tests.root_module.addAnonymousImport("test_zip_streamed", .{ .root_source_file = b.path("libs/sw_assets/testdata/streamed.zip") });
    test_step.dependOn(&b.addRunArtifact(zip_tests).step);
    inline for (.{ "libs/sw_assets/src/files.zig", "libs/sw_assets/src/cache.zig" }) |file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    // The web build of sw_assets (zip, player files, cache) must compile and
    // link for wasm32-freestanding.
    const assets_wasm = b.addExecutable(.{
        .name = "assets_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/sw_assets/src/wasm_check.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    assets_wasm.root_module.addImport("sw_assets", web_libs.assets);
    assets_wasm.entry = .disabled;
    assets_wasm.rdynamic = true;
    test_step.dependOn(&assets_wasm.step);

    inline for (test_files) |file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // sw_platform input settings: a save and a load through the file store.
    // The test makes an sw_core ActionMap.
    const input_settings_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/sw_platform/src/input_settings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    input_settings_tests.root_module.addImport("sw_core", web_libs.core);
    test_step.dependOn(&b.addRunArtifact(input_settings_tests).step);

    // sw_platform clipboard state and the null backend: the clipboard
    // results arrive as sw_core events (REQ-PLATFORM-002).
    const platform_core_tests = [_][]const u8{
        "libs/sw_platform/src/clipboard.zig",
        "libs/sw_platform/src/null_backend.zig",
    };
    inline for (platform_core_tests) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("sw_core", web_libs.core);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // sw_render atlas layout tests: no GPU code. The layout uses the
    // sw_text shelf packer and the sw_gpu mip chain maths. The sw_text
    // module brings C code (stb), so the tests link libc.
    const render_layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/sw_render/src/layout.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    render_layout_tests.root_module.addImport("sw_gpu", web_libs.gpu);
    render_layout_tests.root_module.addImport("sw_text", web_libs.text);
    test_step.dependOn(&b.addRunArtifact(render_layout_tests).step);

    // sw_render frame graph tests: the plan, the uniform ring, the staged
    // uploads, the WGSL prefix and the post chain plan. No GPU code runs.
    const render_graph_test_files = [_][]const u8{
        "libs/sw_render/src/plan.zig",
        "libs/sw_render/src/ring.zig",
        "libs/sw_render/src/upload.zig",
        "libs/sw_render/src/wgsl.zig",
        "libs/sw_render/src/post_plan.zig",
    };
    inline for (render_graph_test_files) |file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("sw_gpu", web_libs.gpu);
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // sw_text font tests: they read a real font through stb_truetype (C).
    // text.zig also needs sw_gfx2d, but its tests use no GPU.
    const font_test_files = [_][]const u8{
        "libs/sw_text/src/font.zig",
        "libs/sw_text/src/bitmap_font.zig",
        "libs/sw_text/src/face.zig",
        "libs/sw_text/src/text.zig",
    };
    inline for (font_test_files) |file| {
        const font_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        addStbTruetype(b, font_tests.root_module);
        font_tests.root_module.addAnonymousImport("test_font", .{
            .root_source_file = b.path("examples/flat2d/assets/Lato-Regular.ttf"),
        });
        font_tests.root_module.addImport("sw_gfx2d", web_libs.gfx2d);
        test_step.dependOn(&b.addRunArtifact(font_tests).step);
    }

    // sw_audio tests: the Ogg Vorbis decoder (stb_vorbis, C), the stream and
    // the mixer. testdata/tone.ogg is the "test_ogg" import.
    const audio_test_files = [_][]const u8{
        "libs/sw_audio/src/vorbis.zig",
        "libs/sw_audio/src/mixer.zig",
    };
    inline for (audio_test_files) |file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        addAudioC(b, unit_tests.root_module);
        unit_tests.root_module.addAnonymousImport("test_ogg", .{ .root_source_file = b.path("libs/sw_audio/testdata/tone.ogg") });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    // The Audio API with the SDL2 backend. SDL_AUDIODRIVER=dummy: the SDL
    // audio thread runs the mixer, and no sound goes to a speaker.
    const audio_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/sw_audio/src/audio.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = &.{ "waveform API", "decode:", "Audio:" },
    });
    addAudioC(b, audio_api_tests.root_module);
    audio_api_tests.root_module.addImport("sdl", sdl_c.createModule());
    audio_api_tests.root_module.addAnonymousImport("test_ogg", .{ .root_source_file = b.path("libs/sw_audio/testdata/tone.ogg") });
    audio_api_tests.root_module.linkSystemLibrary("SDL2", .{});
    const run_audio_api_tests = b.addRunArtifact(audio_api_tests);
    run_audio_api_tests.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    test_step.dependOn(&run_audio_api_tests.step);
    // The web build of sw_audio (the Web Audio backend and stb_vorbis with no
    // C library) must compile and link for wasm32-freestanding.
    const audio_wasm = b.addExecutable(.{
        .name = "audio_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/sw_audio/src/wasm_check.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    audio_wasm.root_module.addImport("sw_audio", web_libs.audio);
    audio_wasm.entry = .disabled;
    audio_wasm.rdynamic = true;
    test_step.dependOn(&audio_wasm.step);

    // Mesher benchmark (no GPU): zig build bench-mesher -Doptimize=ReleaseFast
    const bench_mesher = b.addExecutable(.{
        .name = "bench_mesher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/bench_mesher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addVoxelDemo(bench_mesher.root_module, web_voxel);
    const bench_mesher_step = b.step("bench-mesher", "Time the voxel mesher on a fixed world (no GPU)");
    bench_mesher_step.dependOn(&b.addRunArtifact(bench_mesher).step);

    // Terrain hash (no GPU): the block hash of a 9×9 hilly area for a seed,
    // from a native build and from a wasm build. CI runs both and compares
    // the output. zig build terrain-hash -Doptimize=ReleaseFast
    const terrain_hash_native = b.addExecutable(.{
        .name = "terrain_hash",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/terrain_hash.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addVoxelDemo(terrain_hash_native.root_module, web_voxel);
    const terrain_hash_wasm = b.addExecutable(.{
        .name = "terrain_hash",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/terrain_hash_wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    addVoxelDemo(terrain_hash_wasm.root_module, web_voxel);
    terrain_hash_wasm.entry = .disabled;
    terrain_hash_wasm.rdynamic = true;
    // A Chunk value is about 128 KB on the stack. See the app stack above.
    terrain_hash_wasm.stack_size = 16 * 1024 * 1024;
    const terrain_hash_step = b.step("terrain-hash", "Build the terrain hash tool: zig-out/bin/terrain_hash and terrain_hash.wasm");
    terrain_hash_step.dependOn(&b.addInstallArtifact(terrain_hash_native, .{}).step);
    terrain_hash_step.dependOn(&b.addInstallArtifact(terrain_hash_wasm, .{}).step);

    // Terrain hash tests: seed 0 keeps its block hash, seed 1 changes it.
    const terrain_hash_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/terrain_hash.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Only the tests of terrain_hash.zig. The steps above already run
        // the tests of the files that it imports.
        .filters = &.{"block hash"},
    });
    addVoxelDemo(terrain_hash_tests.root_module, web_voxel);
    test_step.dependOn(&b.addRunArtifact(terrain_hash_tests).step);

    // Chunk stage benchmark (no GPU), native and wasm. See stage_bench.zig.
    //   zig build bench-stages -Doptimize=ReleaseFast
    //   zig build bench-stages-wasm -Doptimize=ReleaseFast
    //   node examples/voxel/scripts/bench_stages.mjs zig-out/bin/stage_bench.wasm
    const stage_bench_native = b.addExecutable(.{
        .name = "stage_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/stage_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addVoxelDemo(stage_bench_native.root_module, web_voxel);
    const stage_bench_step = b.step("bench-stages", "Time each voxel chunk stage natively and print the terrain hashes");
    stage_bench_step.dependOn(&b.addRunArtifact(stage_bench_native).step);
    const stage_bench_wasm = b.addExecutable(.{
        .name = "stage_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/stage_bench.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    addVoxelDemo(stage_bench_wasm.root_module, web_voxel);
    stage_bench_wasm.entry = .disabled;
    stage_bench_wasm.rdynamic = true;
    // Chunk.init makes a large value on the stack. Use the same stack as app.wasm.
    stage_bench_wasm.stack_size = 16 * 1024 * 1024;
    const stage_bench_wasm_step = b.step("bench-stages-wasm", "Build zig-out/bin/stage_bench.wasm (run it with examples/voxel/scripts/bench_stages.mjs)");
    stage_bench_wasm_step.dependOn(&b.addInstallArtifact(stage_bench_wasm, .{}).step);

    // sw_voxel unit tests, with the test content (libs/sw_voxel/testing):
    // the chunk storage, the light, the mesher, World and the frustum.
    // They run two times: with the default world height (y 0 to 255), and
    // with a tall world (y -64 to 319) to test the height setting.
    inline for (.{ .{ 0, 256 }, .{ -64, 384 } }) |d| {
        const voxel_lib_tests = addVoxel(b, web_libs.gpu, .{
            .root_source_file = b.path("libs/sw_voxel/src/sw_voxel.zig"),
            .target = target,
            .optimize = optimize,
        }, .{ .root_source_file = b.path("libs/sw_voxel/testing/content.zig") });
        const test_dims = b.addOptions();
        test_dims.addOption(i32, "min_y", d[0]);
        test_dims.addOption(u32, "height", d[1]);
        voxel_lib_tests.content.addImport("sw_voxel_test_dims", test_dims.createModule());
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = voxel_lib_tests.voxel,
            .name = std.fmt.comptimePrint("sw_voxel_{d}_{d}", .{ d[0], d[1] }),
        })).step);
    }
    // The demo content (examples/voxel/content.zig): the GenConfig bytes
    // and the world_gen tests.
    const demo_content_tests = addVoxel(b, web_libs.gpu, .{
        .root_source_file = b.path("libs/sw_voxel/src/sw_voxel.zig"),
    }, .{
        .root_source_file = b.path("examples/voxel/content.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = demo_content_tests.content })).step);
    // Demo tests: sw_voxel World on the demo terrain, and the demo shader
    // against the mesher.
    inline for (.{ .{ "examples/voxel/world_test.zig", "world: " }, .{ "examples/voxel/shader_test.zig", "shader: " } }) |t| {
        const demo_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(t[0]),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{t[1]},
        });
        addVoxelDemo(demo_tests.root_module, web_voxel);
        test_step.dependOn(&b.addRunArtifact(demo_tests).step);
    }
    // Chunk stage tests (pipeline/stages.zig): equivalence with World,
    // install order, and edits with versions (C2, C3, P3).
    const stages_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/stages_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Only the tests of stages_test.zig. The steps above already run
        // the tests of the files that it imports.
        .filters = &.{"stages: "},
    });
    addVoxelDemo(stages_tests.root_module, web_voxel);
    test_step.dependOn(&b.addRunArtifact(stages_tests).step);
    // Chunk scheduler tests (pipeline/scheduler.zig, pipeline/exec_inline.zig):
    // priority order, stale results, eviction and the render distance (C3, C8).
    const scheduler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/scheduler_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"scheduler: "},
    });
    addVoxelDemo(scheduler_tests.root_module, web_voxel);
    test_step.dependOn(&b.addRunArtifact(scheduler_tests).step);
    // Chunk protocol tests (pipeline/protocol.zig): round trip, layout and
    // fuzz (P6).
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/protocol_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"protocol: "},
    });
    addVoxelDemo(protocol_tests.root_module, web_voxel);
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    // Executor tests (pipeline/worker_world.zig, pipeline/exec_threads.zig):
    // the cache limit, and Inline and ThreadPool give the same bytes (C14,
    // P4). Run them again to look for races: zig build test-exec.
    const exec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/exec_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"exec: "},
    });
    addVoxelDemo(exec_tests.root_module, web_voxel);
    const run_exec_tests = b.addRunArtifact(exec_tests);
    test_step.dependOn(&run_exec_tests.step);
    const exec_test_step = b.step("test-exec", "Run the chunk executor tests only (no cache: run it again to look for races)");
    const run_exec_again = b.addRunArtifact(exec_tests);
    run_exec_again.has_side_effects = true;
    exec_test_step.dependOn(&run_exec_again.step);
    // chunks.wasm must build for wasm32-freestanding: no threads and no
    // OS (C9). zig build test compiles it.
    test_step.dependOn(&chunks_wasm.step);
    const worker_wasm_step = b.step("worker-wasm", "Build zig-out/bin/chunks.wasm: the chunk worker of the Web Worker pool");
    worker_wasm_step.dependOn(&install_chunks.step);
}

/// The build id of the voxel web build (C9): a hash of the path and the
/// bytes of each .zig file under examples/voxel and libs/sw_voxel. app.wasm
/// and chunks.wasm of one build have the same id. A browser cache that keeps
/// an old chunks.wasm gives another id, and the worker pool does not start.
fn voxelBuildId(b: *std.Build) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ "examples/voxel", "libs/sw_voxel" }) |root| hashZigFiles(b, root, &h);
    return h.final();
}

fn hashZigFiles(b: *std.Build, root: []const u8, h: *std.hash.Wyhash) void {
    const io = b.graph.io;
    var dir = b.root.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        paths.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    for (paths.items) |p| {
        const data = dir.readFileAlloc(io, p, b.allocator, .limited(64 << 20)) catch @panic("cannot read a voxel source file");
        h.update(root);
        h.update(p);
        h.update(data);
    }
}

const VoxelModules = struct {
    voxel: *std.Build.Module,
    content: *std.Build.Module,
};

/// Make a sw_voxel module with the content module at `content_options`.
/// sw_voxel imports the content as `sw_voxel_content`, and the content can
/// import `sw_voxel` (libs/sw_voxel/src/content.zig gives the contract).
fn addVoxel(
    b: *std.Build,
    gpu: *std.Build.Module,
    voxel_options: std.Build.Module.CreateOptions,
    content_options: std.Build.Module.CreateOptions,
) VoxelModules {
    const voxel = b.createModule(voxel_options);
    const content = b.createModule(content_options);
    voxel.addImport("sw_gpu", gpu);
    voxel.addImport("sw_voxel_content", content);
    content.addImport("sw_voxel", voxel);
    return .{ .voxel = voxel, .content = content };
}

/// Give a voxel demo tool or test sw_voxel and the demo content.
fn addVoxelDemo(module: *std.Build.Module, demo: VoxelModules) void {
    module.addImport("sw_voxel", demo.voxel);
    module.addImport("voxel_content", demo.content);
}

/// Compile stb_image (libs/sw_assets/c) into `module`. The shim headers stand
/// in for the C library on freestanding wasm.
fn addAssetsC(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("libs/sw_assets/c/shim"));
    module.addIncludePath(b.path("libs/sw_assets/c"));
    module.addCSourceFile(.{
        .file = b.path("libs/sw_assets/c/sw_stb.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });
}

const Platform = enum { web, native };

const Libs = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    gpu: *std.Build.Module,
    audio: *std.Build.Module,
    math: *std.Build.Module,
    gfx2d: *std.Build.Module,
    text: *std.Build.Module,
    ui: *std.Build.Module,
    assets: *std.Build.Module,
    voxel: *std.Build.Module,
    render: *std.Build.Module,
    app: *std.Build.Module,
};

/// Make a library module. `exported` makes it public under `name`, so a
/// dependent package can import it. Otherwise it is private to this build.
fn libModule(
    b: *std.Build,
    exported: bool,
    name: []const u8,
    path: []const u8,
) *std.Build.Module {
    const options: std.Build.Module.CreateOptions = .{ .root_source_file = b.path(path) };
    return if (exported) b.addModule(name, options) else b.createModule(options);
}

/// Create the swindowzig library modules. `sdl` is the translated SDL2 headers
/// for a native build, or null for the web build.
fn addLibs(b: *std.Build, sdl: ?*std.Build.Module, exported: bool) Libs {
    const core = libModule(b, exported, "sw_core", "libs/sw_core/src/core.zig");
    const platform = libModule(b, exported, "sw_platform", "libs/sw_platform/src/platform_root.zig");
    platform.addImport("sw_core", core);
    if (sdl) |m| platform.addImport("sdl", m);
    const gpu = libModule(b, exported, "sw_gpu", "libs/sw_gpu/src/gpu_root.zig");
    const audio = libModule(b, exported, "sw_audio", "libs/sw_audio/src/audio_root.zig");
    addAudioC(b, audio);
    if (sdl) |m| audio.addImport("sdl", m);
    const math = libModule(b, exported, "sw_math", "libs/sw_math/src/math_root.zig");
    const assets = libModule(b, exported, "sw_assets", "libs/sw_assets/src/assets_root.zig");
    addAssetsC(b, assets);
    const gfx2d = libModule(b, exported, "sw_gfx2d", "libs/sw_gfx2d/src/gfx2d_root.zig");
    gfx2d.addImport("sw_gpu", gpu);
    gfx2d.addImport("sw_assets", assets);
    const text = libModule(b, exported, "sw_text", "libs/sw_text/src/text_root.zig");
    text.addImport("sw_gfx2d", gfx2d);
    addStbTruetype(b, text);
    const ui = libModule(b, exported, "sw_ui", "libs/sw_ui/src/ui_root.zig");
    ui.addImport("sw_gfx2d", gfx2d);
    ui.addImport("sw_text", text);
    // sw_voxel needs a content module from the dependent package:
    // voxel.addImport("sw_voxel_content", content). See
    // libs/sw_voxel/src/content.zig.
    const voxel = libModule(b, exported, "sw_voxel", "libs/sw_voxel/src/sw_voxel.zig");
    voxel.addImport("sw_gpu", gpu);
    const render = libModule(b, exported, "sw_render", "libs/sw_render/src/render_root.zig");
    render.addImport("sw_gpu", gpu);
    render.addImport("sw_text", text);
    const app = libModule(b, exported, "sw_app", "libs/sw_app/src/app_root.zig");
    app.addImport("sw_core", core);
    app.addImport("sw_platform", platform);
    app.addImport("sw_gpu", gpu);
    app.addImport("sw_audio", audio);
    app.addImport("sw_math", math);
    return .{ .core = core, .platform = platform, .gpu = gpu, .audio = audio, .math = math, .gfx2d = gfx2d, .assets = assets, .text = text, .ui = ui, .voxel = voxel, .render = render, .app = app };
}

/// Compile stb_vorbis (libs/sw_audio/c) into `module`. The file needs no C
/// library, so it builds for freestanding wasm too.
fn addAudioC(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{
        .file = b.path("libs/sw_audio/c/sw_vorbis.c"),
        // STB_VORBIS_NO_CRT gives `malloc(s)` as an int 0. With a memory
        // buffer, the decoder never calls it.
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined", "-Wno-int-conversion", "-Wno-tautological-compare" },
    });
}

/// Compile stb_truetype (with the C API that font.zig declares) into a module.
/// The file needs no libc, so it builds for freestanding WASM too.
fn addStbTruetype(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{
        .file = b.path("libs/sw_text/src/stb_impl.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });
}
