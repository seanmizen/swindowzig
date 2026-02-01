const std = @import("std");
const core = @import("sw_core");
const Event = core.Event;
const EventPayload = core.EventPayload;
const platform = @import("platform.zig");
const WindowInfo = platform.WindowInfo;

/// Backend interface that all platforms must implement
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
        pollEvents: *const fn (ptr: *anyopaque, bus: *core.Bus) anyerror!void,
        getTime: *const fn (ptr: *anyopaque) u64,
        getWindowInfo: *const fn (ptr: *anyopaque) WindowInfo,
        getWindow: *const fn (ptr: *anyopaque) ?*anyopaque,
    };

    pub fn init(self: Backend) !void {
        return self.vtable.init(self.ptr);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn pollEvents(self: Backend, bus: *core.Bus) !void {
        return self.vtable.pollEvents(self.ptr, bus);
    }

    pub fn getTime(self: Backend) u64 {
        return self.vtable.getTime(self.ptr);
    }

    pub fn getWindowInfo(self: Backend) WindowInfo {
        return self.vtable.getWindowInfo(self.ptr);
    }

    pub fn getWindow(self: Backend) ?*anyopaque {
        return self.vtable.getWindow(self.ptr);
    }
};
