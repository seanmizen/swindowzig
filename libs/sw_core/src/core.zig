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
pub const tas = @import("tas.zig");
pub const action = @import("action.zig");

// Re-export commonly used types
pub const Event = event.Event;
pub const EventPayload = event.EventPayload;
pub const ClipboardEvent = event.ClipboardEvent;
pub const ClipboardEventKind = event.ClipboardEventKind;
pub const ClipboardStatus = event.ClipboardStatus;
pub const KeyCode = event.KeyCode;
pub const MouseButton = event.MouseButton;
pub const GamepadButton = event.GamepadButton;
pub const GamepadAxis = event.GamepadAxis;
pub const max_gamepads = event.max_gamepads;
pub const Modifiers = event.Modifiers;
pub const Bus = bus.Bus;
pub const Timeline = timeline.Timeline;
pub const FixedStepTimeline = timeline.FixedStepTimeline;
pub const InputSnapshot = input.InputSnapshot;
pub const GamepadState = input.GamepadState;
pub const GamepadSettings = input.GamepadSettings;
pub const Recorder = record.Recorder;
pub const Replayer = replay.Replayer;
pub const TasScript = tas.TasScript;
pub const TasCommand = tas.TasCommand;
pub const ActionMap = action.ActionMap;
pub const ActionState = action.ActionState;
pub const Binding = action.Binding;
pub const BindingCapture = action.BindingCapture;
pub const InputSource = action.Source;
pub const MouseSettings = action.MouseSettings;
pub const AxisDirection = action.AxisDirection;

test {
    std.testing.refAllDecls(@This());
}
