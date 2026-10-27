//! `Transport`: one API for a pool of workers that run messages (REQ-JOBS-002).
//! A native ThreadPool (`native_transport.zig`) and the Web Worker pool of
//! the browser (`web.zig`) give the same Transport, so the code on the main
//! side is the same on both platforms.
//!
//! Each message is bytes. The transport copies the bytes that main sends:
//! the caller keeps them. A worker answers a message with a result, or with
//! nothing. Main takes the results in arrival order. The transport holds
//! each result that main takes, until main releases it. So a large result
//! (for example a mesh for the GPU) can stay where it is: main copies only
//! its first bytes (`takeHead`) and reads the rest when it needs it.
const std = @import("std");

/// Bytes that the transport holds for main, by handle.
pub const Held = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copy `out.len` bytes of the held result `handle`, from `offset`,
        /// into `out`.
        read: *const fn (ptr: *anyopaque, handle: u32, offset: usize, out: []u8) void,
        /// Free the held result `handle`. The handle is then not valid.
        release: *const fn (ptr: *anyopaque, handle: u32) void,
    };

    pub fn read(self: Held, handle: u32, offset: usize, out: []u8) void {
        self.vtable.read(self.ptr, handle, offset, out);
    }
    pub fn release(self: Held, handle: u32) void {
        self.vtable.release(self.ptr, handle);
    }
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The number of worker slots. It does not change.
        slots: *const fn (ptr: *anyopaque) usize,
        /// True when the worker in `slot` runs and can take messages.
        alive: *const fn (ptr: *anyopaque, slot: usize) bool,
        /// Send a message to the worker in `slot`. False when the message
        /// did not go.
        post: *const fn (ptr: *anyopaque, slot: usize, msg: []const u8) bool,
        /// Send a message to each worker. A pool that starts a worker again
        /// can keep it for the new worker.
        broadcast: *const fn (ptr: *anyopaque, msg: []const u8) bool,
        /// The length of the next result in the queue, or 0.
        nextLen: *const fn (ptr: *anyopaque) usize,
        /// Remove the next result from the queue, and hold it. Copy its
        /// first `head.len` bytes into `head`. Returns the handle of the
        /// held result, never 0. Returns 0 when no result waits.
        takeHead: *const fn (ptr: *anyopaque, head: []u8) u32,
        /// Read and release a held result.
        held: Held.VTable,
    };

    pub fn slots(self: Transport) usize {
        return self.vtable.slots(self.ptr);
    }
    pub fn alive(self: Transport, slot: usize) bool {
        return self.vtable.alive(self.ptr, slot);
    }
    pub fn post(self: Transport, slot: usize, msg: []const u8) bool {
        return self.vtable.post(self.ptr, slot, msg);
    }
    pub fn broadcast(self: Transport, msg: []const u8) bool {
        return self.vtable.broadcast(self.ptr, msg);
    }
    pub fn nextLen(self: Transport) usize {
        return self.vtable.nextLen(self.ptr);
    }
    pub fn takeHead(self: Transport, head: []u8) u32 {
        return self.vtable.takeHead(self.ptr, head);
    }
    /// The store of the held results.
    pub fn store(self: Transport) Held {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.held };
    }
    pub fn read(self: Transport, handle: u32, offset: usize, out: []u8) void {
        self.vtable.held.read(self.ptr, handle, offset, out);
    }
    pub fn release(self: Transport, handle: u32) void {
        self.vtable.held.release(self.ptr, handle);
    }
};
