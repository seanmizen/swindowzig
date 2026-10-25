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
