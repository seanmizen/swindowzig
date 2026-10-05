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

    // The web build gets its own set of library modules, with no SDL. The
    // minecraft dockerfile has no SDL headers.
    const web_libs = addLibs(b, null);

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
    const native_libs = addLibs(b, sdl_c.createModule());

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
    };

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
}

const Libs = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    gpu: *std.Build.Module,
    math: *std.Build.Module,
    app: *std.Build.Module,
};

/// Create the swindowzig library modules. `sdl` is the translated SDL2 headers
/// for a native build, or null for the web build.
fn addLibs(b: *std.Build, sdl: ?*std.Build.Module) Libs {
    const core = b.createModule(.{ .root_source_file = b.path("libs/sw_core/src/core.zig") });
    const platform = b.createModule(.{ .root_source_file = b.path("libs/sw_platform/src/platform_root.zig") });
    platform.addImport("sw_core", core);
    if (sdl) |m| platform.addImport("sdl", m);
    const gpu = b.createModule(.{ .root_source_file = b.path("libs/sw_gpu/src/gpu_root.zig") });
    const audio = b.createModule(.{ .root_source_file = b.path("libs/sw_audio/src/audio_root.zig") });
    const math = b.createModule(.{ .root_source_file = b.path("libs/sw_math/src/math_root.zig") });
    const app = b.createModule(.{ .root_source_file = b.path("libs/sw_app/src/app_root.zig") });
    app.addImport("sw_core", core);
    app.addImport("sw_platform", platform);
    app.addImport("sw_gpu", gpu);
    app.addImport("sw_audio", audio);
    app.addImport("sw_math", math);
    return .{ .core = core, .platform = platform, .gpu = gpu, .math = math, .app = app };
}
