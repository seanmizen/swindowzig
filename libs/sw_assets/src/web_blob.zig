//! The wasm imports of `backends/wasm/files.ts` (module "files"), and the
//! read of one JS blob into wasm memory. `files.zig` and `cache.zig` use
//! them. A player file and a cache file are both a blob on the JS side.
//!
//! JS copies the blob into a buffer that Zig allocated, in chunks, so the
//! JS side never holds a second full copy of a large file.
const std = @import("std");

// Return codes. They match backends/wasm/files.ts.
pub const pending = -1;
pub const missing = -2;
pub const failed = -3;
pub const too_large = -4;
pub const insecure = -5;
pub const unavailable = -6;
pub const no_space = -7;

pub extern "files" fn jsFileNext() u32;
pub extern "files" fn jsFilePicker(accept_ptr: [*]const u8, accept_len: usize) i32;
/// The state of an entry: the blob size (0 for a finished write or delete)
/// or a negative code.
pub extern "files" fn jsBlobPoll(id: u32, max_size: usize) i32;
/// Copy at most `cap` bytes of the blob name to `dst`. Returns the length.
pub extern "files" fn jsBlobName(id: u32, dst: [*]u8, cap: usize) usize;
/// Start to copy the blob to `dst`. `dst` must hold the blob size.
pub extern "files" fn jsBlobRead(id: u32, dst: [*]u8) void;
/// 0 when the copy is complete, `pending`, or a negative code.
pub extern "files" fn jsBlobReadPoll(id: u32) i32;
/// Forget the entry. A copy that runs stops before its next write.
pub extern "files" fn jsBlobDrop(id: u32) void;
pub extern "files" fn jsCacheOpen(name_ptr: [*]const u8, name_len: usize) u32;
pub extern "files" fn jsCacheWrite(name_ptr: [*]const u8, name_len: usize, ptr: [*]const u8, len: usize) u32;
pub extern "files" fn jsCacheDelete(name_ptr: [*]const u8, name_len: usize) u32;

/// The read of one blob into a buffer.
pub const BlobRead = struct {
    id: u32,
    buffer: ?[]u8 = null,

    pub const Step = union(enum) {
        pending,
        /// The caller owns the bytes. The entry is dropped.
        done: []u8,
        /// A negative code. The entry is dropped.
        failed: i32,
    };

    /// Move the read forward. It never waits.
    pub fn step(self: *BlobRead, allocator: std.mem.Allocator, max_size: usize) Step {
        if (self.buffer) |buffer| {
            const rc = jsBlobReadPoll(self.id);
            if (rc == pending) return .pending;
            self.drop();
            if (rc == 0) {
                self.buffer = null;
                return .{ .done = buffer };
            }
            allocator.free(buffer);
            self.buffer = null;
            return .{ .failed = rc };
        }
        const rc = jsBlobPoll(self.id, max_size);
        if (rc == pending) return .pending;
        if (rc < 0) {
            self.drop();
            return .{ .failed = rc };
        }
        const buffer = allocator.alloc(u8, @intCast(rc)) catch {
            self.drop();
            return .{ .failed = no_memory };
        };
        self.buffer = buffer;
        jsBlobRead(self.id, buffer.ptr);
        return .pending;
    }

    /// Stop the read and free the buffer.
    pub fn cancel(self: *BlobRead, allocator: std.mem.Allocator) void {
        self.drop();
        if (self.buffer) |buffer| allocator.free(buffer);
        self.buffer = null;
    }

    fn drop(self: *BlobRead) void {
        if (self.id != 0) jsBlobDrop(self.id);
        self.id = 0;
    }
};

/// A code for `BlobRead.Step.failed` that only Zig makes.
pub const no_memory = -100;
