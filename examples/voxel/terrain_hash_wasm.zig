//! The wasm root of the terrain hash tool. See terrain_hash.zig.
//!
//! A separate root: a root with `main` makes std.start export a wasm entry
//! that needs std.Io.Threaded, and wasm32-freestanding has no threads.
//! examples/voxel/scripts/terrain_hash_wasm.mjs loads this build.
const std = @import("std");
const terrain_hash = @import("terrain_hash.zig");

/// The wasm build has no stderr, so it drops all log lines.
pub const std_options: std.Options = .{
    .log_level = .warn,
    .logFn = noLog,
};

fn noLog(
    comptime _: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime _: []const u8,
    _: anytype,
) void {}

/// The block hash for `seed`. JS gives and gets a BigInt. Returns 0 if
/// generation fails (out of memory). The runner treats 0 as an error.
export fn terrain_hash_block(seed: u64) u64 {
    return terrain_hash.blockHash(std.heap.wasm_allocator, seed) catch 0;
}
