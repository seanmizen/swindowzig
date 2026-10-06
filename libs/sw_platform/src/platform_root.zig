// Platform module root
pub const platform = @import("platform.zig");
pub const backend = @import("backend.zig");
pub const wasm_canvas = @import("wasm_canvas.zig");
pub const native_sdl = @import("native_sdl.zig");
pub const null_backend = @import("null_backend.zig");
pub const storage = @import("storage.zig");

pub const WindowInfo = platform.WindowInfo;
pub const Backend = backend.Backend;

pub const storageGet = storage.storageGet;
pub const storageSet = storage.storageSet;
pub const storageDelete = storage.storageDelete;
