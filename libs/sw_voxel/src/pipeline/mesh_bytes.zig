//! The bytes of a mesh result, from the worker to the GPU upload (C5).
//!
//! Main does not copy the quads of a mesh. A mesh Result goes to the
//! scheduler as one of these:
//!
//!   local  the whole Result message in main memory: the reply of the
//!          Inline executor or of a ThreadPool thread. The quads are the
//!          bytes from protocol.PAYLOAD_OFFSET. The upload writes them to the
//!          GPU, then frees the message.
//!   held   the Result message that JS holds: the transferred ArrayBuffer of
//!          a Web Worker. Main has only a handle. The upload tells JS to
//!          write the bytes to the GPU (gpu.writeBufferHeld), then releases
//!          the handle. The bytes never go into the main wasm memory.
//!
//! The main wasm keeps only the counts: the quad count, the y range and the
//! mesh hash (world.zig: MeshInfo). After the upload, main has no CPU copy
//! of the mesh.
const std = @import("std");
const protocol = @import("protocol.zig");

/// Bytes that the host (JS) holds for main, by handle: the held results
/// of a sw_jobs Transport. exec_web.zig gives it.
pub const Store = @import("sw_jobs").Held;

/// The offset of the quads in a Result message.
pub const QUADS_OFFSET = protocol.PAYLOAD_OFFSET;

pub const MeshBytes = union(enum) {
    local: struct {
        /// The whole Result message.
        msg: []u8,
        allocator: std.mem.Allocator,
    },
    held: struct {
        /// The handle of the whole Result message in the host. Never 0.
        handle: u32,
        /// The length of the whole message.
        len: usize,
        store: Store,
    },

    /// The length of the quad bytes.
    pub fn quadBytesLen(self: MeshBytes) usize {
        return switch (self) {
            .local => |l| l.msg.len - protocol.PAYLOAD_OFFSET,
            .held => |h| h.len - protocol.PAYLOAD_OFFSET,
        };
    }

    /// Copy the quads into `out` (its length is `quadBytesLen() / 16`). Only
    /// the tests use it.
    pub fn copyQuads(self: MeshBytes, out: []protocol.PackedQuad) void {
        const dst = std.mem.sliceAsBytes(out);
        std.debug.assert(dst.len == self.quadBytesLen());
        switch (self) {
            .local => |l| @memcpy(dst, l.msg[protocol.PAYLOAD_OFFSET..]),
            .held => |h| h.store.vtable.read(h.store.ptr, h.handle, protocol.PAYLOAD_OFFSET, dst),
        }
    }

    /// Free the bytes. Call it one time, after the upload or when the mesh
    /// is not used.
    pub fn release(self: MeshBytes) void {
        switch (self) {
            .local => |l| l.allocator.free(l.msg),
            .held => |h| h.store.vtable.release(h.store.ptr, h.handle),
        }
    }
};
