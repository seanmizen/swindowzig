const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const sw_app = b.addModule("sw_app", .{
        .root_source_file = b.path("libs/sw_app/src/app_root.zig"),
    });
    sw_app.addImport("sw_core", sw_core);
    sw_app.addImport("sw_platform", sw_platform);
    sw_app.addImport("sw_gpu", sw_gpu);

    // Example app - WASM build
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const example = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple_demo/src/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("sw_app", sw_app);
    example.rdynamic = true; // Export symbols for WASM

    const install_example = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_example.step);

    // Web build step
    const web_step = b.step("web", "Build for web (WASM)");
    web_step.dependOn(&install_example.step);

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
