const std = @import("std");

/// Window/canvas dimensions and DPI scaling.
/// Obtained via ctx.window().
pub const WindowInfo = extern struct {
    /// Window width in pixels.
    width: u32,
    /// Window height in pixels.
    height: u32,
    /// DPI scale factor (1.0 = normal, 2.0 = retina/HiDPI).
    dpi_scale: f32,
};

/// Platform capabilities (not exposed in v0.1).
pub const PlatformCaps = struct {
    has_window: bool = true,
    has_gpu: bool = true,
    is_web: bool = false,
};

/// How the window covers the screen. The numbers go to the web backend.
pub const WindowMode = enum(u8) {
    /// A normal window. On the web: the page in the browser window.
    windowed = 0,
    /// The window covers the whole screen of its monitor. Native: a
    /// borderless window at the desktop resolution (no change of the display
    /// mode). Web: the page in browser full screen. The browser asks for a
    /// user gesture, and Escape ends it.
    fullscreen = 1,
};

/// How the platform shows and moves the mouse cursor. The numbers go to the
/// web backend.
pub const CursorMode = enum(u8) {
    /// The system cursor shows and moves freely.
    normal = 0,
    /// The cursor moves freely, but does not show over the window. Use it
    /// when the game draws its own cursor.
    hidden = 1,
    /// The cursor does not show and stays in the window. The pointer events
    /// give the relative movement (dx, dy). On the web, this is the pointer
    /// lock: the browser asks for a user gesture, and Escape ends it.
    locked = 2,
};

/// The DPI scale of a window: its pixels per window unit. `drawable` is the
/// size in pixels, `logical` is the size in the units of the window system
/// (points on macOS, CSS pixels on the web). A zero size gives 1.
pub fn dpiScale(drawable: u32, logical: u32) f32 {
    if (logical == 0 or drawable == 0) return 1.0;
    return @as(f32, @floatFromInt(drawable)) / @as(f32, @floatFromInt(logical));
}

/// True when `next` has a different pixel size or DPI scale than `prev`.
/// A move to a monitor with a different DPI scale changes the pixel size and
/// the scale. The window size in points stays the same (REQ-PLATFORM-003).
pub fn windowInfoChanged(prev: WindowInfo, next: WindowInfo) bool {
    return prev.width != next.width or prev.height != next.height or prev.dpi_scale != next.dpi_scale;
}

test "dpiScale divides pixels by window units" {
    try std.testing.expectEqual(@as(f32, 2.0), dpiScale(2560, 1280));
    try std.testing.expectEqual(@as(f32, 1.5), dpiScale(1920, 1280));
    try std.testing.expectEqual(@as(f32, 1.0), dpiScale(1280, 1280));
}

test "dpiScale gives 1 for a zero size" {
    // A minimised window can report 0x0.
    try std.testing.expectEqual(@as(f32, 1.0), dpiScale(0, 0));
    try std.testing.expectEqual(@as(f32, 1.0), dpiScale(100, 0));
}

test "a move to a monitor with another DPI scale is a change (REQ-PLATFORM-003)" {
    const retina: WindowInfo = .{ .width = 2560, .height = 1440, .dpi_scale = 2.0 };
    const external: WindowInfo = .{ .width = 1280, .height = 720, .dpi_scale = 1.0 };
    try std.testing.expect(windowInfoChanged(retina, external));
    try std.testing.expect(!windowInfoChanged(retina, retina));
    // The same pixel size with a new scale is a change too.
    try std.testing.expect(windowInfoChanged(retina, .{ .width = 2560, .height = 1440, .dpi_scale = 1.0 }));
}

test "the mode numbers do not change" {
    // The web backend sends and reads these numbers.
    try std.testing.expectEqual(@as(u8, 0), @backingInt(WindowMode.windowed));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(WindowMode.fullscreen));
    try std.testing.expectEqual(@as(u8, 0), @backingInt(CursorMode.normal));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(CursorMode.hidden));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(CursorMode.locked));
}
