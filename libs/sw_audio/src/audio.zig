// Audio output: the waveform API, and decoded samples, streams and 3D sound
// through one mixer. The web backend uses Web Audio (backends/wasm/audio.ts),
// and the native backend uses SDL2 audio.
const std = @import("std");
const builtin = @import("builtin");
const mixer_mod = @import("mixer.zig");
const sample_mod = @import("sample.zig");
const wav = @import("wav.zig");
const vorbis = @import("vorbis.zig");

const is_web = builtin.cpu.arch.isWasm();
const backend = if (is_web) @import("web.zig") else @import("native_sdl.zig");

pub const Waveform = mixer_mod.Waveform;
pub const Sample = sample_mod.Sample;
pub const Stream = vorbis.Stream;
pub const PlayOptions = mixer_mod.PlayOptions;
pub const Voice = mixer_mod.Voice;
pub const Listener = mixer_mod.Listener;
pub const Attenuation = mixer_mod.Attenuation;
pub const Vec3 = mixer_mod.Vec3;
pub const group_count = mixer_mod.group_count;
pub const max_voices = mixer_mod.max_voices;

pub const DecodeError = error{ UnknownFormat, InvalidWav, UnsupportedWav, InvalidVorbis, OutOfMemory };

/// Decode WAV or Ogg Vorbis bytes to a `Sample`. The first bytes of the
/// data give the format.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Sample {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "RIFF")) return wav.decodeWav(allocator, bytes);
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) return vorbis.decodeVorbis(allocator, bytes);
    return error.UnknownFormat;
}

pub const decodeWav = wav.decodeWav;
pub const decodeVorbis = vorbis.decodeVorbis;

pub const Sound = struct {
    /// Starting frequency in Hz
    frequency: f32 = 440.0,
    /// Ending frequency for sweeps (null = same as start)
    frequency_end: ?f32 = null,
    /// Duration in seconds
    duration: f32 = 0.1,
    /// Waveform type
    waveform: Waveform = .sine,
    /// Volume 0.0 - 1.0
    volume: f32 = 0.5,
    /// Stereo position: -1 left, 0 centre, 1 right.
    pan: f32 = 0,
    /// Seconds from now to the start of the sound.
    delay: f32 = 0,
};

/// Samples to play: one channel for the left ear and one for the right
/// ear, at `sample_rate`. The backend copies the samples during the call,
/// so the caller can use the memory again after the call.
pub const Buffer = struct {
    left: []const f32,
    right: []const f32,
    sample_rate: f32 = 48000,
    /// Volume 0.0 - 1.0. The master volume applies too.
    volume: f32 = 1,
    /// Seconds from now to the start of the first sample.
    delay: f32 = 0,
};

pub const AudioState = enum {
    uninitialized,
    ready,
    suspended, // Browser requires user interaction
    failed,
};

/// The audio output. There is one output for each program: each `Audio`
/// value controls the same mixer.
pub const Audio = struct {
    state: AudioState = .uninitialized,
    master_volume: f32 = 0.5,

    /// Start the output. On native, `state` is `.failed` if there is no
    /// audio device. The calls then do nothing.
    pub fn init() Audio {
        const ok = backend.start();
        var self: Audio = .{ .state = if (ok) .ready else .failed, .master_volume = 0.5 };
        self.setMasterVolume(0.5);
        return self;
    }

    pub fn isReady(self: *const Audio) bool {
        return self.state == .ready;
    }

    /// Set master volume (0.0 - 1.0). It applies to every sound.
    pub fn setMasterVolume(self: *Audio, volume: f32) void {
        self.master_volume = @max(0.0, @min(1.0, volume));
        const m = backend.lock();
        defer backend.unlock();
        m.master_volume = self.master_volume;
    }

    /// Get current master volume
    pub fn getMasterVolume(self: *const Audio) f32 {
        return self.master_volume;
    }

    /// Play a synthesized sound (applies master volume)
    pub fn play(self: *Audio, sound: Sound) void {
        const effective_volume = sound.volume * self.master_volume;
        if (effective_volume <= 0.001) return; // Skip if effectively silent
        const pan = std.math.clamp(sound.pan, -1, 1);
        const delay = @max(0, sound.delay);
        if (is_web) {
            backend.playTone(
                sound.frequency,
                sound.frequency_end orelse sound.frequency,
                sound.duration,
                @backingInt(sound.waveform),
                effective_volume,
                pan,
                delay,
            );
        } else {
            // The mixer applies the master volume.
            backend.playTone(.{
                .frequency = sound.frequency,
                .frequency_end = sound.frequency_end orelse sound.frequency,
                .duration = sound.duration,
                .waveform = sound.waveform,
            }, sound.volume, pan, delay);
        }
    }

    /// Play a block of samples (applies master volume). Use it for sounds
    /// that the caller makes sample by sample.
    pub fn playBuffer(self: *Audio, buffer: Buffer) void {
        const effective_volume = buffer.volume * self.master_volume;
        const frames = @min(buffer.left.len, buffer.right.len);
        if (effective_volume <= 0.001 or frames == 0) return;
        // On native, the mixer applies the master volume.
        const volume = if (is_web) effective_volume else buffer.volume;
        backend.playBuffer(buffer.left[0..frames], buffer.right[0..frames], buffer.sample_rate, volume, @max(0, buffer.delay));
    }

    /// Play a simple tone
    pub fn tone(self: *Audio, frequency: f32, duration: f32) void {
        self.play(.{ .frequency = frequency, .duration = duration });
    }

    /// Play a frequency sweep (good for lasers, power-ups)
    pub fn sweep(self: *Audio, freq_start: f32, freq_end: f32, duration: f32, waveform: Waveform) void {
        self.play(.{
            .frequency = freq_start,
            .frequency_end = freq_end,
            .duration = duration,
            .waveform = waveform,
        });
    }

    /// Play noise burst (good for explosions, hits)
    pub fn noise(self: *Audio, duration: f32, volume: f32) void {
        self.play(.{
            .frequency = 0,
            .duration = duration,
            .waveform = .noise,
            .volume = volume,
        });
    }

    // Preset sounds for common game effects
    pub fn laser(self: *Audio) void {
        self.sweep(880, 220, 0.1, .sawtooth);
    }

    pub fn explosion(self: *Audio) void {
        self.noise(0.3, 0.6);
    }

    pub fn hit(self: *Audio) void {
        self.noise(0.08, 0.4);
    }

    pub fn powerup(self: *Audio) void {
        self.sweep(220, 880, 0.2, .sine);
    }

    pub fn thrust(self: *Audio) void {
        self.play(.{
            .frequency = 70,
            .duration = 0.03,
            .waveform = .triangle,
            .volume = 0.15,
        });
    }

    // ------------------------------------------------ samples, streams, 3D

    /// Play a decoded sample. The sample must stay valid until its voice
    /// ends or `stop` returns. Returns null if every voice plays.
    pub fn playSample(self: *Audio, sample: *const Sample, options: PlayOptions) ?Voice {
        if (self.state != .ready) return null;
        const m = backend.lock();
        defer backend.unlock();
        return m.playSample(sample, options);
    }

    /// Play a stream from its first frame. The stream decodes while it
    /// plays. Stop the voice before `stream.deinit()`.
    pub fn playStream(self: *Audio, stream: *Stream, options: PlayOptions) ?Voice {
        if (self.state != .ready) return null;
        const m = backend.lock();
        defer backend.unlock();
        return m.playStream(stream, options);
    }

    /// True while the voice plays. False after it ends or stops.
    pub fn isPlaying(_: *Audio, voice: Voice) bool {
        const m = backend.lock();
        defer backend.unlock();
        return m.isPlaying(voice);
    }

    /// Stop a voice. After the call, the mixer does not read its sample or
    /// stream.
    pub fn stop(_: *Audio, voice: Voice) void {
        const m = backend.lock();
        defer backend.unlock();
        m.stop(voice);
    }

    pub fn stopGroup(_: *Audio, group: u8) void {
        const m = backend.lock();
        defer backend.unlock();
        m.stopGroup(group);
    }

    /// Stop every voice of the mixer. On the web, the waveform sounds play
    /// to their end.
    pub fn stopAll(_: *Audio) void {
        const m = backend.lock();
        defer backend.unlock();
        m.stopAll();
    }

    pub fn setVoiceVolume(_: *Audio, voice: Voice, volume: f32) void {
        const m = backend.lock();
        defer backend.unlock();
        m.setVolume(voice, volume);
    }

    pub fn setVoicePitch(_: *Audio, voice: Voice, pitch: f32) void {
        const m = backend.lock();
        defer backend.unlock();
        m.setPitch(voice, pitch);
    }

    pub fn setVoicePan(_: *Audio, voice: Voice, pan: f32) void {
        const m = backend.lock();
        defer backend.unlock();
        m.setPan(voice, pan);
    }

    /// Move a voice. Null: the voice has no position.
    pub fn setVoicePosition(_: *Audio, voice: Voice, position: ?Vec3) void {
        const m = backend.lock();
        defer backend.unlock();
        m.setPosition(voice, position);
    }

    pub fn setVoiceLooping(_: *Audio, voice: Voice, looping: bool) void {
        const m = backend.lock();
        defer backend.unlock();
        m.setLooping(voice, looping);
    }

    /// Set the volume (0 to 1) of a group of voices (0 to `group_count - 1`).
    pub fn setGroupVolume(_: *Audio, group: u8, volume: f32) void {
        const m = backend.lock();
        defer backend.unlock();
        m.setGroupVolume(group, volume);
    }

    pub fn getGroupVolume(_: *Audio, group: u8) f32 {
        if (group >= group_count) return 0;
        const m = backend.lock();
        defer backend.unlock();
        return m.group_volume[group];
    }

    /// Set the position and direction of the ears for the voices with a
    /// position.
    pub fn setListener(_: *Audio, listener: Listener) void {
        const m = backend.lock();
        defer backend.unlock();
        m.listener = listener;
    }

    /// The output rate of the mixer, in frames each second.
    pub fn sampleRate(_: *Audio) u32 {
        return backend.sampleRate();
    }
};

// REQ-AUDIO-001: the waveform API keeps its signatures.
test "the waveform API keeps its signatures" {
    const expect = std.testing.expect;
    try expect(@TypeOf(Audio.init) == fn () Audio);
    try expect(@TypeOf(Audio.isReady) == fn (*const Audio) bool);
    try expect(@TypeOf(Audio.setMasterVolume) == fn (*Audio, f32) void);
    try expect(@TypeOf(Audio.getMasterVolume) == fn (*const Audio) f32);
    try expect(@TypeOf(Audio.play) == fn (*Audio, Sound) void);
    try expect(@TypeOf(Audio.playBuffer) == fn (*Audio, Buffer) void);
    try expect(@TypeOf(Audio.tone) == fn (*Audio, f32, f32) void);
    try expect(@TypeOf(Audio.sweep) == fn (*Audio, f32, f32, f32, Waveform) void);
    try expect(@TypeOf(Audio.noise) == fn (*Audio, f32, f32) void);
    inline for (.{ "laser", "explosion", "hit", "powerup", "thrust" }) |name| {
        try expect(@TypeOf(@field(Audio, name)) == fn (*Audio) void);
    }
    try expect(@backingInt(Waveform.sine) == 0 and @backingInt(Waveform.noise) == 4);
    const s: Sound = .{};
    try expect(s.frequency == 440 and s.duration == 0.1 and s.volume == 0.5 and s.pan == 0 and s.delay == 0);
    const b: Buffer = .{ .left = &.{}, .right = &.{} };
    try expect(b.sample_rate == 48000 and b.volume == 1 and b.delay == 0);
    try expect(@hasField(Audio, "state") and @hasField(Audio, "master_volume"));
}

test "decode: the first bytes give the format" {
    try std.testing.expectError(error.UnknownFormat, decode(std.testing.allocator, "ID3 not a known format"));
    var s = try decode(std.testing.allocator, @embedFile("test_ogg"));
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 44100), s.rate);
}

// The test runs with SDL_AUDIODRIVER=dummy (build.zig): the SDL audio thread
// runs the mixer, and no sound goes to a speaker.
test "Audio: native output plays and ends voices" {
    if (is_web) return error.SkipZigTest;
    const sdl = @import("sdl");
    var audio = Audio.init();
    if (!audio.isReady()) return error.SkipZigTest;
    try std.testing.expect(audio.sampleRate() > 0);
    // A short sample ends on the audio thread.
    var data: [480]f32 = @splat(0.1);
    const sample: Sample = .{ .data = &data, .channels = 1, .rate = 48000 };
    const voice = audio.playSample(&sample, .{ .position = .{ 1, 0, 0 } }).?;
    audio.setListener(.{ .position = .{ 0, 0, 0 }, .forward = .{ 0, 0, 1 } });
    audio.setGroupVolume(0, 0.5);
    try std.testing.expectEqual(@as(f32, 0.5), audio.getGroupVolume(0));
    // On native, the waveform API goes through the same mixer.
    audio.laser();
    const left: [64]f32 = @splat(0.2);
    audio.playBuffer(.{ .left = &left, .right = &left });
    var waited: usize = 0;
    while (audio.isPlaying(voice) and waited < 200) : (waited += 1) sdl.SDL_Delay(10);
    try std.testing.expect(!audio.isPlaying(voice));
    audio.stopAll();
}
