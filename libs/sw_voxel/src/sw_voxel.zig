//! sw_voxel: voxel chunks for games. It holds the chunk storage (paletted
//! 16 × 16 × 16 block sections, skylight and block light), the greedy
//! mesher and the model mesher, the pure chunk stages, the chunk scheduler,
//! the chunk protocol, the executors (Inline, ThreadPool and the Web Worker
//! pool), the frustum cull, and the collision of boxes and rays.
//!
//! sw_voxel knows no block names and no terrain. The game gives them in a
//! content module: `content.zig` gives the contract and the build wiring.
//! `examples/voxel` is the demo.
const builtin = @import("builtin");

/// The content of the game: block type, emission and generator.
pub const content = @import("content.zig");
/// One paletted block section of 16 × 16 × 16 cells.
pub const section = @import("section.zig");
/// One chunk: a column of sections, skylight and block light.
pub const chunk = @import("chunk.zig");
/// The light rules (opacity, emission) and the incremental light update.
pub const light = @import("light.zig");
/// The greedy mesher and the model mesher: chunk blocks to packed quads.
pub const mesher = @import("mesher.zig");
/// Baked block models: the quad type and the box and rotation helpers.
pub const model = @import("model.zig");
/// The models of the content as tables, and the GPU table of model quads.
pub const models = @import("models.zig");
/// The chunks of main, with versions and cross-chunk light.
pub const world = @import("world.zig");
/// The chunk cull: cone, sphere and frustum.
pub const frustum = @import("frustum.zig");
/// Collision: the boxes of each block, moving boxes with step-up, and the
/// voxel ray cast.
pub const collision = @import("collision.zig");
/// The monotonic clock of the perf logs.
pub const clock = @import("clock.zig");

/// The pure chunk stages: generate, light and mesh (C2, C3).
pub const stages = @import("pipeline/stages.zig");
/// The chunk scheduler: desired state, priority, versions, eviction (C8).
pub const scheduler = @import("pipeline/scheduler.zig");
/// The bytes of the chunk messages (P6).
pub const protocol = @import("pipeline/protocol.zig");
/// The quad bytes of a mesh result until the GPU upload (C5).
pub const mesh_bytes = @import("pipeline/mesh_bytes.zig");
/// The world of one chunk worker: edit log and chunk cache (C4, C14).
pub const worker_world = @import("pipeline/worker_world.zig");
/// The Inline executor: one worker on the main thread (C7).
pub const exec_inline = @import("pipeline/exec_inline.zig");
/// The ThreadPool executor: native worker threads (C4, C9). Not on wasm.
pub const exec_threads = if (builtin.cpu.arch == .wasm32) struct {} else @import("pipeline/exec_threads.zig");
/// The WorkerPool executor: the main side of the Web Worker pool (C9).
pub const exec_web = @import("pipeline/exec_web.zig");
/// The exports of chunks.wasm, the chunk worker of the web build (C9).
pub const chunk_worker = @import("pipeline/chunk_worker_main.zig");

test {
    _ = content;
    _ = section;
    _ = chunk;
    _ = light;
    _ = mesher;
    _ = model;
    _ = models;
    _ = world;
    _ = frustum;
    _ = collision;
    _ = stages;
    _ = scheduler;
    _ = protocol;
    _ = mesh_bytes;
    _ = worker_world;
    _ = exec_inline;
    _ = exec_threads;
    _ = exec_web;
}
