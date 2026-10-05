//! Monotonic clock for the voxel perf logs. main() sets `io` at startup.
//! The web build has no clock: nowNs() returns 0, so the logs show 0 µs.
const std = @import("std");
const is_wasm = @import("builtin").cpu.arch == .wasm32;

pub var io: ?std.Io = null;

/// Nanoseconds on the monotonic (awake) clock. 0 when there is no Io.
pub fn nowNs() i128 {
    if (comptime is_wasm) return 0;
    const i = io orelse return 0;
    return std.Io.Timestamp.now(i, .awake).toNanoseconds();
}
