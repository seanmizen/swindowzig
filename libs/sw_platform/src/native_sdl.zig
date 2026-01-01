// SDL2 Native Backend (stub - requires SDL2 to be linked in build.zig)
// To use: add SDL2 dependency to build.zig.zon and link in build.zig

const std = @import("std");
const core = @import("sw_core");
const backend_mod = @import("backend.zig");
const platform = @import("platform.zig");

// TODO: Add SDL2 bindings when ready to use
// const sdl = @cImport({
//     @cInclude("SDL2/SDL.h");
// });

pub const SDL2Backend = struct {
    allocator: std.mem.Allocator,
    // window: *sdl.SDL_Window,
    start_time: i64,
    window_info: platform.WindowInfo,

    pub fn create(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !backend_mod.Backend {
        _ = title; // TODO: Use when SDL2 is linked

        const self = try allocator.create(SDL2Backend);
        self.* = .{
            .allocator = allocator,
            .start_time = std.time.milliTimestamp(),
            .window_info = .{
                .width = width,
                .height = height,
                .dpi_scale = 1.0,
            },
        };

        return .{
            .ptr = self,
            .vtable = &.{
                .init = init,
                .deinit = deinit,
                .pollEvents = pollEvents,
                .getTime = getTime,
                .getWindowInfo = getWindowInfo,
            },
        };
    }

    fn init(ptr: *anyopaque) !void {
        _ = ptr;
        // TODO: SDL_Init(SDL_INIT_VIDEO)
        // TODO: SDL_CreateWindow
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        // TODO: SDL_DestroyWindow
        // TODO: SDL_Quit
        self.allocator.destroy(self);
    }

    fn pollEvents(ptr: *anyopaque, bus: *core.Bus) !void {
        _ = ptr;
        _ = bus;
        // TODO: Poll SDL events and convert to sw_core events
    }

    fn getTime(ptr: *anyopaque) u64 {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const now = std.time.milliTimestamp();
        const elapsed = now - self.start_time;
        return @as(u64, @intCast(elapsed)) * 1_000_000; // Convert ms to ns
    }

    fn getWindowInfo(ptr: *anyopaque) platform.WindowInfo {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        return self.window_info;
    }
};
