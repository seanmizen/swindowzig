const std = @import("std");

/// Window information
pub const WindowInfo = extern struct {
    width: u32,
    height: u32,
    dpi_scale: f32,
};

/// Platform capabilities
pub const PlatformCaps = struct {
    has_window: bool = true,
    has_gpu: bool = true,
    is_web: bool = false,
};
