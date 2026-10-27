//! A wasm program that uses each part of the sw_audio API. `zig build test`
//! builds it for wasm32-freestanding, to check that the web backend and
//! stb_vorbis compile and link with no C library. It does not run.

const std = @import("std");
const sw_audio = @import("sw_audio");

var audio: sw_audio.Audio = undefined;

export fn sw_audio_check(ptr: [*]const u8, len: usize) u32 {
    const bytes = ptr[0..len];
    const alloc = std.heap.wasm_allocator;
    audio = sw_audio.Audio.init();
    audio.setMasterVolume(0.8);
    audio.laser();
    audio.playBuffer(.{ .left = &.{0.1}, .right = &.{0.1} });
    audio.setGroupVolume(1, 0.5);
    audio.setListener(.{ .position = .{ 1, 2, 3 } });
    var sample = sw_audio.decode(alloc, bytes) catch return 1;
    defer sample.deinit(alloc);
    const voice = audio.playSample(&sample, .{ .position = .{ 0, 0, -4 }, .group = 0 }) orelse return 2;
    audio.setVoicePosition(voice, .{ 1, 0, 0 });
    audio.setVoiceVolume(voice, 0.5);
    audio.setVoicePitch(voice, 1.5);
    audio.stop(voice);
    const stream = sw_audio.Stream.open(alloc, bytes) catch return 3;
    defer stream.deinit();
    const music = audio.playStream(stream, .{ .group = 1, .looping = true }) orelse return 4;
    defer audio.stop(music);
    return @intFromBool(audio.isPlaying(music));
}
