//! The root of chunks.wasm, the chunk worker of the Web Worker pool (C9).
//! The worker code is in sw_voxel (`pipeline/chunk_worker_main.zig`). This
//! file gives it the demo content (through the build) and the build id.
//!
//! `zig build web -Dexample=voxel` writes zig-out/bin/chunks.wasm. `zig build
//! test` compiles it, so a change that breaks the wasm32 build of the worker
//! code stops the tests.
const std = @import("std");
const chunk_worker = @import("sw_voxel").chunk_worker;
const chunk_build = @import("chunk_build");

pub const std_options: std.Options = .{ .logFn = chunk_worker.log, .log_level = .warn };

comptime {
    chunk_worker.exportFunctions(chunk_build.id);
}
