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
        sdl_c.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
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
    example.root_module.addImport("sw_assets", web_libs.assets);
    // sw_platform is needed by examples that drive their own wasm entry
    // (e.g. voxel, which constructs a WasmBackend directly in its
    // swindowzig_init export).
    example.root_module.addImport("sw_platform", web_libs.platform);
    example.rdynamic = true; // Export symbols for WASM
    // Voxel's Chunk.init() constructs a stack-allocated struct value.
    // At CHUNK_W=16: 16×256×16 blocks + skylight ≈ 128 KB. At CHUNK_W=48
    // (the old size) it was ~1.17 MB. Keep 16 MB for headroom — recursive
    // meshing + several chunk call frames can still stack up.
    example.stack_size = 16 * 1024 * 1024;

    const install_example = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_example.step);

    // Web build step
    const web_step_desc = b.fmt("Build '{s}' example for web (WASM)", .{example_name});
    const web_step = b.step("web", web_step_desc);
    web_step.dependOn(&install_example.step);

    // Native executable (for SDL2/desktop). This step translates the SDL2
    // headers and gives them to sw_platform as the "sdl" module.
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("libs/sw_platform/src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
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
    native_exe.root_module.addImport("sw_assets", native_libs.assets);

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
        "libs/sw_platform/src/storage.zig",
        // sw_gfx2d: the batching and the projection maths have no GPU code.
        "libs/sw_gfx2d/src/batch.zig",
        "libs/sw_gfx2d/src/projection.zig",
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

    // Mesher benchmark (no GPU): zig build bench-mesher -Doptimize=ReleaseFast
    const bench_mesher = b.addExecutable(.{
        .name = "bench_mesher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/bench_mesher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_mesher.root_module.addImport("sw_gpu", web_libs.gpu);
    const bench_mesher_step = b.step("bench-mesher", "Time the voxel mesher on a fixed world (no GPU)");
    bench_mesher_step.dependOn(&b.addRunArtifact(bench_mesher).step);

    // Voxel mesher tests: the packed-quad round trip checks that vs_chunk's
    // decode (mirrored in mesher.unpackCorner) gives back the CPU vertices.
    const mesher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/mesher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mesher_tests.root_module.addImport("sw_gpu", web_libs.gpu);
    test_step.dependOn(&b.addRunArtifact(mesher_tests).step);
    const frustum_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/frustum.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(frustum_tests).step);
    // Chunk tests: the fast skylight matches the bucket-pass reference.
    const chunk_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/chunk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(chunk_tests).step);
    // Async chunk tests: meshing through border copies matches full chunks.
    const async_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/voxel/async_chunks.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    async_tests.root_module.addImport("sw_gpu", web_libs.gpu);
    test_step.dependOn(&b.addRunArtifact(async_tests).step);
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
    assets: *std.Build.Module,
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
    const math = libModule(b, exported, "sw_math", "libs/sw_math/src/math_root.zig");
    const assets = libModule(b, exported, "sw_assets", "libs/sw_assets/src/assets_root.zig");
    addAssetsC(b, assets);
    const gfx2d = libModule(b, exported, "sw_gfx2d", "libs/sw_gfx2d/src/gfx2d_root.zig");
    gfx2d.addImport("sw_gpu", gpu);
    gfx2d.addImport("sw_assets", assets);
    const app = libModule(b, exported, "sw_app", "libs/sw_app/src/app_root.zig");
    app.addImport("sw_core", core);
    app.addImport("sw_platform", platform);
    app.addImport("sw_gpu", gpu);
    app.addImport("sw_audio", audio);
    app.addImport("sw_math", math);
    return .{ .core = core, .platform = platform, .gpu = gpu, .audio = audio, .math = math, .gfx2d = gfx2d, .assets = assets, .app = app };
}
