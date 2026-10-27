//! Web audio output. The page (backends/wasm/audio.ts) calls the export
//! `sw_audio_mix` from a timer on the main thread. It schedules each mixed
//! block on the Web Audio clock, a short time ahead. The waveform API goes
//! to Web Audio nodes directly (`audioPlay`, `audioPlayBuffer`).

const mixer_mod = @import("mixer.zig");

extern "audio" fn audioInit() void;
extern "audio" fn audioPlay(freq_start: f32, freq_end: f32, duration: f32, waveform: u8, volume: f32, pan: f32, delay: f32) void;
extern "audio" fn audioPlayBuffer(left: [*]const f32, right: [*]const f32, frames: u32, sample_rate: f32, volume: f32, delay: f32) void;
extern "audio" fn audioSampleRate() f32;
extern "audio" fn audioStartMixer() void;

/// The most frames of one `sw_audio_mix` call.
const max_block = 4096;

var mixer: mixer_mod.Mixer = mixer_mod.Mixer.init(48000);
var block: [max_block * 2]f32 = undefined;
var started = false;

pub fn start() bool {
    if (started) return true;
    started = true;
    audioInit();
    const rate = audioSampleRate();
    if (rate >= 1) mixer = mixer_mod.Mixer.init(@intFromFloat(rate));
    audioStartMixer();
    return true;
}

/// Mix `frames` frames (at most 4096) of interleaved stereo. Returns the
/// address of the block, or 0 if no voice plays and the block is silent.
/// The page copies the block before the next call.
export fn sw_audio_mix(frames: u32) usize {
    if (mixer.activeVoices() == 0 and mixer.limiter <= 1) return 0;
    const n = @min(frames, max_block);
    mixer.mix(block[0 .. n * 2]);
    return @intFromPtr(&block);
}

/// The page and the wasm run on one thread, so no lock is necessary.
pub fn lock() *mixer_mod.Mixer {
    return &mixer;
}

pub fn unlock() void {}

pub fn sampleRate() u32 {
    return mixer.rate;
}

pub fn playTone(freq_start: f32, freq_end: f32, duration: f32, waveform: u8, volume: f32, pan: f32, delay: f32) void {
    audioPlay(freq_start, freq_end, duration, waveform, volume, pan, delay);
}

pub fn playBuffer(left: []const f32, right: []const f32, rate: f32, volume: f32, delay: f32) void {
    audioPlayBuffer(left.ptr, right.ptr, @intCast(@min(left.len, right.len)), rate, volume, delay);
}
