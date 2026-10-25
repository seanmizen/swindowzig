//! chunks.wasm: the chunk worker of the Web Worker pool (C9).
//!
//! The root of the build is `examples/voxel/chunks_wasm.zig`, because a
//! module can import only files under the directory of its root. That file
//! only imports this file. `zig build web -Dexample=voxel` writes
//! zig-out/bin/chunks.wasm. `backends/wasm/chunk-worker.ts` runs it in a
//! Web Worker.
//!
//! The wasm imports are only `env.jsGetTime` (the clock) and `env.jsLog`
//! (the log). chunks.wasm has no GPU code and no threads. Each Web Worker
//! has its own instance, so the globals of this file belong to one worker.
//!
//! The exports move protocol bytes (protocol.zig) in and out of the wasm
//! memory:
//!
//!   chunk_worker_alloc(len) -> ptr     memory for a message from the host
//!   chunk_worker_free(ptr, len)        free a message or a reply
//!   chunk_worker_handle(ptr, len) -> u64
//!       Handle the message at ptr. The message stays with the host: free
//!       it after the call. The result is (reply ptr << 32) | reply len,
//!       or 0 when there is no reply (an Edit).
//!   chunk_worker_protocol_version() -> u32    protocol.VERSION
//!   chunk_worker_build_hash() -> u64          protocol.BUILD_HASH
//!   chunk_worker_build_id() -> u64            the source hash of the build
//!   chunk_worker_cache_bytes() -> u64         the bytes in the chunk cache
//!
//! The worker JS reads the three handshake values before it accepts jobs.
//! app.wasm exports the same three values (main.zig). When one value is
//! different, the pool does not start, and the Inline executor runs the
//! chunk jobs (C9). So a cached old chunks.wasm cannot make wrong terrain.
const std = @import("std");
const worker_world = @import("worker_world.zig");
const protocol = @import("protocol.zig");
const build_options = @import("chunk_build");

extern "env" fn jsGetTime() f64;
extern "env" fn jsLog(ptr: [*]const u8, len: usize) void;

/// The log function of chunks.wasm. It writes one line through jsLog.
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[chunks] " ++ level.asText() ++ ": " ++ fmt, args) catch buf[0..];
    jsLog(line.ptr, line.len);
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
    const t0 = jsGetTime();
    const reply = (world.?.handle(ptr[0..len]) catch {
        std.log.err("no memory for the reply", .{});
        return 0;
    }) orelse return 0;
    stampJobTime(reply, jsGetTime() - t0);
    return (@as(u64, @intFromPtr(reply.ptr)) << 32) | reply.len;
}

/// Write the job time into a Result (C12), as the ThreadPool does.
fn stampJobTime(reply: []u8, ms: f64) void {
    if (reply.len < protocol.PAYLOAD_OFFSET or reply[6] != @backingInt(protocol.Kind.result)) return;
    const us: u32 = @intFromFloat(std.math.clamp(ms * 1000.0, 0, @as(f64, std.math.maxInt(u32))));
    std.mem.writeInt(u32, reply[protocol.HEADER_LEN + 28 ..][0..4], us, .little);
}

fn protocolVersion() callconv(.c) u32 {
    return protocol.VERSION;
}

fn buildHash() callconv(.c) u64 {
    return protocol.BUILD_HASH;
}

fn buildId() callconv(.c) u64 {
    return build_options.id;
}

fn cacheBytes() callconv(.c) u64 {
    const w = world orelse return 0;
    return w.bytes;
}

comptime {
    @export(&alloc, .{ .name = "chunk_worker_alloc" });
    @export(&free, .{ .name = "chunk_worker_free" });
    @export(&handle, .{ .name = "chunk_worker_handle" });
    @export(&protocolVersion, .{ .name = "chunk_worker_protocol_version" });
    @export(&buildHash, .{ .name = "chunk_worker_build_hash" });
    @export(&buildId, .{ .name = "chunk_worker_build_id" });
    @export(&cacheBytes, .{ .name = "chunk_worker_cache_bytes" });
}
