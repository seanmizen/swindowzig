const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build option to select which example to build
    const example_name = b.option(
        []const u8,
        "example",
        "Which example to build (default: windows)",
    ) orelse "windows";

    // Modules
    const sw_core = b.addModule("sw_core", .{
        .root_source_file = b.path("libs/sw_core/src/core.zig"),
    });

    const sw_platform = b.addModule("sw_platform", .{
        .root_source_file = b.path("libs/sw_platform/src/platform_root.zig"),
    });
    sw_platform.addImport("sw_core", sw_core);

    const sw_gpu = b.addModule("sw_gpu", .{
        .root_source_file = b.path("libs/sw_gpu/src/gpu_root.zig"),
    });

    const sw_audio = b.addModule("sw_audio", .{
        .root_source_file = b.path("libs/sw_audio/src/audio_root.zig"),
    });

    const sw_app = b.addModule("sw_app", .{
        .root_source_file = b.path("libs/sw_app/src/app_root.zig"),
    });
    sw_app.addImport("sw_core", sw_core);
    sw_app.addImport("sw_platform", sw_platform);
    sw_app.addImport("sw_gpu", sw_gpu);
    sw_app.addImport("sw_audio", sw_audio);

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
        var src_file = std.fs.cwd().openFile(src_path, .{}) catch {
            // Fall back to root main.zig
            break :blk root_path;
        };
        src_file.close();
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
    example.root_module.addImport("sw_app", sw_app);
    example.rdynamic = true; // Export symbols for WASM

    const install_example = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_example.step);

    // Web build step
    const web_step_desc = b.fmt("Build '{s}' example for web (WASM)", .{example_name});
    const web_step = b.step("web", web_step_desc);
    web_step.dependOn(&install_example.step);

    // Native executable (for SDL2/desktop)
    const native_exe = b.addExecutable(.{
        .name = b.fmt("{s}", .{example_name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_path),
            .target = target,
            .optimize = optimize,
        }),
    });
    native_exe.root_module.addImport("sw_app", sw_app);

    // Link SDL2 for native builds
    native_exe.linkSystemLibrary("SDL2");
    native_exe.linkLibC();

    // Link wgpu-native from ~/.local
    const home = std.process.getEnvVarOwned(b.allocator, "HOME") catch unreachable;
    defer b.allocator.free(home);
    const wgpu_lib_path = std.fs.path.join(b.allocator, &[_][]const u8{ home, ".local", "lib" }) catch unreachable;
    const wgpu_include_path = std.fs.path.join(b.allocator, &[_][]const u8{ home, ".local", "include" }) catch unreachable;

    native_exe.addLibraryPath(.{ .cwd_relative = wgpu_lib_path });
    native_exe.addIncludePath(.{ .cwd_relative = wgpu_include_path });
    native_exe.linkSystemLibrary("wgpu_native");

    // Platform-specific frameworks
    if (target.result.os.tag == .macos) {
        native_exe.linkFramework("Metal");
        native_exe.linkFramework("QuartzCore");
        native_exe.linkFramework("Foundation");
        native_exe.linkFramework("IOKit");
        native_exe.linkFramework("IOSurface");
    }

    const install_native = b.addInstallArtifact(native_exe, .{});

    // Native build step
    const native_step_desc = b.fmt("Build '{s}' example for native", .{example_name});
    const native_step = b.step("native", native_step_desc);
    native_step.dependOn(&install_native.step);

    // Run step
    const run_cmd = b.addRunArtifact(native_exe);
    run_cmd.step.dependOn(&install_native.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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
}
