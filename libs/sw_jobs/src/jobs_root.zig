//! sw_jobs: run work on worker threads (native) and on Web Workers (web)
//! (REQ-JOBS-001, REQ-JOBS-002).
//!
//! - `ThreadPool(Handler)`: native threads, each with its own handler and
//!   queue. Order, cancel and shutdown are in `thread_pool.zig`.
//! - `Transport`: one API for a pool of workers. `NativeTransport` gives it
//!   for a ThreadPool, and `webTransport` for the JS Web Worker pool.
//!
//! A worker gets bytes and gives bytes. The library knows no message
//! format: the game defines it.
const std = @import("std");
const builtin = @import("builtin");

pub const thread_pool = @import("thread_pool.zig");
pub const transport = @import("transport.zig");

pub const Answer = thread_pool.Answer;
pub const ThreadPool = thread_pool.ThreadPool;
pub const Transport = transport.Transport;
pub const Held = transport.Held;
pub const NativeTransport = @import("native_transport.zig").NativeTransport;
/// The Transport of the JS Web Worker pool. Only on wasm32.
pub const webTransport = @import("web.zig").webTransport;

test {
    if (builtin.cpu.arch != .wasm32) {
        _ = thread_pool;
        _ = @import("native_transport.zig");
    }
}
