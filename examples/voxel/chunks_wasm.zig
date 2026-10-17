//! The root of chunks.wasm, the chunk worker of the Web Worker pool (C9).
//!
//! A module can import only files under the directory of its root, and the
//! worker code imports chunk.zig and world_gen.zig. So the root is here, and
//! the exports are in pipeline/chunk_worker_main.zig.
//!
//! `zig build web -Dexample=voxel` writes zig-out/bin/chunks.wasm. `zig build
//! test` compiles it, so a change that breaks the wasm32 build of the worker
//! code stops the tests.
const std = @import("std");
const chunk_worker = @import("pipeline/chunk_worker_main.zig");

pub const std_options: std.Options = .{ .logFn = chunk_worker.log, .log_level = .warn };

comptime {
    _ = chunk_worker;
}
