// sw_core - Pure logic module for swindowzig
// No platform-specific code, no GPU dependencies

const std = @import("std");

pub const event = @import("event.zig");
pub const bus = @import("bus.zig");
pub const timeline = @import("timeline.zig");
pub const input = @import("input.zig");
pub const serialize = @import("serialize.zig");
pub const record = @import("record.zig");
pub const replay = @import("replay.zig");

// Re-export commonly used types
pub const Event = event.Event;
pub const EventPayload = event.EventPayload;
pub const KeyCode = event.KeyCode;
pub const MouseButton = event.MouseButton;
pub const Modifiers = event.Modifiers;
pub const Bus = bus.Bus;
pub const Timeline = timeline.Timeline;
pub const FixedStepTimeline = timeline.FixedStepTimeline;
pub const InputSnapshot = input.InputSnapshot;
pub const Recorder = record.Recorder;
pub const Replayer = replay.Replayer;

test {
    std.testing.refAllDecls(@This());
}
