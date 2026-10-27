//! Gamepad helpers that have no platform code (REQ-INPUT-005). The SDL
//! backend (`native_sdl.zig`) uses them. The web backend does the same work
//! in `backends/wasm/gamepad.ts`.

const std = @import("std");

/// A table that gives each connected gamepad a slot from 0 to `n - 1`. A
/// platform has its own gamepad IDs (the SDL instance ID). A slot is free
/// again when its gamepad disconnects, and the next gamepad gets the lowest
/// free slot.
pub fn Slots(comptime Id: type, comptime n: usize) type {
    return struct {
        const Self = @This();

        ids: [n]?Id = @splat(null),

        /// The slot of `id`, or null when `id` has no slot.
        pub fn find(self: *const Self, id: Id) ?u8 {
            for (self.ids, 0..) |s, i| {
                if (s != null and s.? == id) return @intCast(i);
            }
            return null;
        }

        /// Give `id` the lowest free slot. When `id` has a slot, that slot.
        /// Null when all slots are in use.
        pub fn connect(self: *Self, id: Id) ?u8 {
            if (self.find(id)) |slot| return slot;
            for (&self.ids, 0..) |*s, i| {
                if (s.* == null) {
                    s.* = id;
                    return @intCast(i);
                }
            }
            return null;
        }

        /// Free the slot of `id`. Returns that slot, or null when `id` had
        /// no slot.
        pub fn disconnect(self: *Self, id: Id) ?u8 {
            const slot = self.find(id) orelse return null;
            self.ids[slot] = null;
            return slot;
        }
    };
}

/// An SDL stick axis value (-32768 to 32767) as -1 to 1.
pub fn stickFromSdl(v: i16) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(v)) / 32767.0, -1, 1);
}

/// An SDL trigger value (0 to 32767) as 0 to 1.
pub fn triggerFromSdl(v: i16) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(v)) / 32767.0, 0, 1);
}

test "slots: connect, disconnect and reuse the lowest free slot" {
    var slots: Slots(i32, 2) = .{};
    try std.testing.expectEqual(@as(?u8, 0), slots.connect(40));
    try std.testing.expectEqual(@as(?u8, 1), slots.connect(41));
    // A second connect of the same gamepad keeps its slot.
    try std.testing.expectEqual(@as(?u8, 0), slots.connect(40));
    // All slots are in use.
    try std.testing.expectEqual(@as(?u8, null), slots.connect(42));
    try std.testing.expectEqual(@as(?u8, 0), slots.disconnect(40));
    try std.testing.expectEqual(@as(?u8, null), slots.disconnect(40));
    try std.testing.expectEqual(@as(?u8, null), slots.find(40));
    try std.testing.expectEqual(@as(?u8, 0), slots.connect(42));
    try std.testing.expectEqual(@as(?u8, 1), slots.find(41));
}

test "SDL axis values scale to the core range" {
    try std.testing.expectEqual(@as(f32, 1), stickFromSdl(32767));
    try std.testing.expectEqual(@as(f32, -1), stickFromSdl(-32768));
    try std.testing.expectEqual(@as(f32, 0), stickFromSdl(0));
    try std.testing.expectEqual(@as(f32, 1), triggerFromSdl(32767));
    try std.testing.expectEqual(@as(f32, 0), triggerFromSdl(-5));
}
