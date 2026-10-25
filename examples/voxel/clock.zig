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

/// Wall clock in ns for the frame budget of the chunk pipeline. Native:
/// the monotonic clock. Web: performance.now() through the jsGetTime import
/// of the wasm platform.
pub fn frameNowNs() u64 {
    if (comptime is_wasm) return @intFromFloat(jsGetTime() * 1_000_000.0);
    return @intCast(@max(nowNs(), 0));
}

extern fn jsGetTime() f64;
