// Platform module root
pub const platform = @import("platform.zig");
pub const backend = @import("backend.zig");
pub const wasm_canvas = @import("wasm_canvas.zig");
pub const native_sdl = @import("native_sdl.zig");

pub const WindowInfo = platform.WindowInfo;
pub const Backend = backend.Backend;
