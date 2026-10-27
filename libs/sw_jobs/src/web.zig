//! The Transport of the web build (REQ-JOBS-002): the Web Worker pool of
//! `backends/wasm/worker-pool.ts`, through the imports of the module
//! "jobs". Each message goes to a worker as a transferred ArrayBuffer, and
//! each result comes back the same way, so the threads copy no bytes. JS holds each result until main releases it.
//!
//! The pool does not use SharedArrayBuffer: a transfer has no copy, and
//! the page needs no cross-origin isolation.
//!
//! With no pool, `slots` is 0.
const std = @import("std");
const builtin = @import("builtin");
const transport = @import("transport.zig");

const Transport = transport.Transport;

const js = struct {
    extern "jobs" fn jsJobSlots() u32;
    extern "jobs" fn jsJobAlive(slot: u32) u32;
    extern "jobs" fn jsJobPost(slot: u32, ptr: [*]const u8, len: u32) u32;
    extern "jobs" fn jsJobBroadcast(ptr: [*]const u8, len: u32) u32;
    extern "jobs" fn jsJobNextLen() u32;
    extern "jobs" fn jsJobTakeHead(ptr: [*]u8, len: u32) u32;
    extern "jobs" fn jsJobRead(handle: u32, offset: u32, ptr: [*]u8, len: u32) void;
    extern "jobs" fn jsJobRelease(handle: u32) void;
};

fn webSlots(_: *anyopaque) usize {
    return js.jsJobSlots();
}
fn webAlive(_: *anyopaque, slot: usize) bool {
    return js.jsJobAlive(@intCast(slot)) != 0;
}
fn webPost(_: *anyopaque, slot: usize, msg: []const u8) bool {
    return js.jsJobPost(@intCast(slot), msg.ptr, @intCast(msg.len)) != 0;
}
fn webBroadcast(_: *anyopaque, msg: []const u8) bool {
    return js.jsJobBroadcast(msg.ptr, @intCast(msg.len)) != 0;
}
fn webNextLen(_: *anyopaque) usize {
    return js.jsJobNextLen();
}
fn webTakeHead(_: *anyopaque, head: []u8) u32 {
    return js.jsJobTakeHead(head.ptr, @intCast(head.len));
}
fn webRead(_: *anyopaque, handle: u32, offset: usize, out: []u8) void {
    js.jsJobRead(handle, @intCast(offset), out.ptr, @intCast(out.len));
}
fn webRelease(_: *anyopaque, handle: u32) void {
    js.jsJobRelease(handle);
}

var web_dummy: u8 = 0;
const web_vtable: Transport.VTable = .{
    .slots = webSlots,
    .alive = webAlive,
    .post = webPost,
    .broadcast = webBroadcast,
    .nextLen = webNextLen,
    .takeHead = webTakeHead,
    .held = .{ .read = webRead, .release = webRelease },
};

/// The Transport of the JS worker pool. Only a wasm32 build can use it.
pub fn webTransport() Transport {
    comptime std.debug.assert(builtin.cpu.arch == .wasm32);
    return .{ .ptr = &web_dummy, .vtable = &web_vtable };
}
