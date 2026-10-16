//! The worker side of the chunk pipeline, built for wasm32-freestanding
//! (C9). It proves that worker_world.zig and protocol.zig build with no
//! threads, no clock and no OS. `zig build test` compiles it, and
//! `zig build worker-wasm` writes zig-out/bin/chunk_worker.wasm.
//!
//! The exports move protocol bytes in and out of wasm memory:
//!
//!   chunk_worker_alloc(len) -> ptr     memory for a message from the host
//!   chunk_worker_free(ptr, len)        free a message or a reply
//!   chunk_worker_handle(ptr, len) -> u64
//!       Handle the message at ptr. The message stays with the host: free
//!       it after the call. The result is (reply ptr << 32) | reply len,
//!       or 0 when there is no reply (an Edit).
//!
//! The Web Worker pool (chunks.wasm) is a later step. It will start from
//! this file.
const std = @import("std");
const worker_world = @import("pipeline/worker_world.zig");

pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = fmt;
    _ = args;
}

const allocator = std.heap.wasm_allocator;
var world: ?worker_world.WorkerWorld = null;

fn alloc(len: u32) callconv(.c) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

fn free(ptr: [*]u8, len: u32) callconv(.c) void {
    allocator.free(ptr[0..len]);
}

fn handle(ptr: [*]const u8, len: u32) callconv(.c) u64 {
    if (world == null) world = .init(allocator);
    const reply = (world.?.handle(ptr[0..len]) catch return 0) orelse return 0;
    return (@as(u64, @intFromPtr(reply.ptr)) << 32) | reply.len;
}

comptime {
    @export(&alloc, .{ .name = "chunk_worker_alloc" });
    @export(&free, .{ .name = "chunk_worker_free" });
    @export(&handle, .{ .name = "chunk_worker_handle" });
}
