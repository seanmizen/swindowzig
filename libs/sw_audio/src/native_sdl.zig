//! Native audio output with SDL2. SDL calls `callback` on its audio thread
//! for each block. The callback runs the mixer. The main thread changes the
//! mixer only between `lock` and `unlock` (SDL_LockAudioDevice).

const std = @import("std");
const sdl = @import("sdl");
const mixer_mod = @import("mixer.zig");
const Sample = @import("sample.zig").Sample;

/// AUDIO_F32LSB: 32-bit float, little-endian. Every target of this backend
/// is little-endian.
const audio_f32 = 0x8120;

var device: sdl.SDL_AudioDeviceID = 0;
var mixer: mixer_mod.Mixer = mixer_mod.Mixer.init(48000);
var started = false;

/// Open the default output device. Returns false if there is no device.
/// More calls do nothing.
pub fn start() bool {
    if (started) return device != 0;
    started = true;
    if (sdl.SDL_InitSubSystem(sdl.SDL_INIT_AUDIO) != 0) {
        std.log.warn("sw_audio: SDL audio init failed: {s}", .{sdl.SDL_GetError()});
        return false;
    }
    var want = std.mem.zeroes(sdl.SDL_AudioSpec);
    want.freq = 48000;
    want.format = audio_f32;
    want.channels = 2;
    want.samples = 1024;
    want.callback = callback;
    var have = std.mem.zeroes(sdl.SDL_AudioSpec);
    device = sdl.SDL_OpenAudioDevice(null, 0, &want, &have, sdl.SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    if (device == 0) {
        std.log.warn("sw_audio: no audio device: {s}", .{sdl.SDL_GetError()});
        return false;
    }
    mixer = mixer_mod.Mixer.init(@intCast(@max(have.freq, 1)));
    sdl.SDL_PauseAudioDevice(device, 0);
    return true;
}

fn callback(_: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.c) void {
    const n: usize = @intCast(@max(len, 0));
    const out: [*]f32 = @ptrCast(@alignCast(stream));
    mixer.mix(out[0 .. n / @sizeOf(f32)]);
}

/// Take the mixer from the audio thread. Free the samples of the ended
/// owned voices. Call `unlock` after the change.
pub fn lock() *mixer_mod.Mixer {
    if (device != 0) sdl.SDL_LockAudioDevice(device);
    while (mixer.takeEnded()) |s| freeOwned(s);
    return &mixer;
}

pub fn unlock() void {
    if (device != 0) sdl.SDL_UnlockAudioDevice(device);
}

pub fn sampleRate() u32 {
    return mixer.rate;
}

pub fn playTone(tone: mixer_mod.Tone, volume: f32, pan: f32, delay: f32) void {
    if (device == 0) return;
    const m = lock();
    defer unlock();
    _ = m.playTone(tone, .{ .volume = volume, .pan = pan, .delay = delay });
}

/// Copy the samples into memory that the mixer owns, and play them. The
/// mixer gives the copy back when the voice ends (`lock`).
pub fn playBuffer(left: []const f32, right: []const f32, rate: f32, volume: f32, delay: f32) void {
    if (device == 0) return;
    const alloc = std.heap.c_allocator;
    const frames = @min(left.len, right.len);
    const owned = alloc.create(Sample) catch return;
    const data = alloc.alloc(f32, frames * 2) catch {
        alloc.destroy(owned);
        return;
    };
    for (0..frames) |i| {
        data[i * 2] = left[i];
        data[i * 2 + 1] = right[i];
    }
    owned.* = .{ .data = data, .channels = 2, .rate = @intFromFloat(@max(rate, 1)) };
    const m = lock();
    defer unlock();
    if (m.playOwnedSample(owned, .{ .volume = volume, .delay = delay }) == null) freeOwned(owned);
}

fn freeOwned(s: *const Sample) void {
    const alloc = std.heap.c_allocator;
    alloc.free(s.data);
    alloc.destroy(@constCast(s));
}
