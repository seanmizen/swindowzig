// Audio interface - Web Audio API abstraction
const std = @import("std");

pub const Waveform = enum(u8) {
    sine = 0,
    square = 1,
    sawtooth = 2,
    triangle = 3,
    noise = 4,
};

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

pub const Audio = struct {
    state: AudioState = .uninitialized,
    master_volume: f32 = 0.5,

    pub fn init() Audio {
        audioInit();
        return .{ .state = .ready, .master_volume = 0.5 };
    }

    pub fn isReady(self: *const Audio) bool {
        return self.state == .ready;
    }

    /// Set master volume (0.0 - 1.0)
    pub fn setMasterVolume(self: *Audio, volume: f32) void {
        self.master_volume = @max(0.0, @min(1.0, volume));
    }

    /// Get current master volume
    pub fn getMasterVolume(self: *const Audio) f32 {
        return self.master_volume;
    }

    /// Play a synthesized sound (applies master volume)
    pub fn play(self: *Audio, sound: Sound) void {
        const effective_volume = sound.volume * self.master_volume;
        if (effective_volume <= 0.001) return; // Skip if effectively silent
        audioPlay(
            sound.frequency,
            sound.frequency_end orelse sound.frequency,
            sound.duration,
            @backingInt(sound.waveform),
            effective_volume,
            std.math.clamp(sound.pan, -1, 1),
            @max(0, sound.delay),
        );
    }

    /// Play a block of samples (applies master volume). Use it for sounds
    /// that the caller makes sample by sample.
    pub fn playBuffer(self: *Audio, buffer: Buffer) void {
        const effective_volume = buffer.volume * self.master_volume;
        const frames = @min(buffer.left.len, buffer.right.len);
        if (effective_volume <= 0.001 or frames == 0) return;
        audioPlayBuffer(
            buffer.left.ptr,
            buffer.right.ptr,
            @intCast(frames),
            buffer.sample_rate,
            effective_volume,
            @max(0, buffer.delay),
        );
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
};

// WASM imports from audio namespace
extern "audio" fn audioInit() void;
extern "audio" fn audioPlay(freq_start: f32, freq_end: f32, duration: f32, waveform: u8, volume: f32, pan: f32, delay: f32) void;
extern "audio" fn audioPlayBuffer(left: [*]const f32, right: [*]const f32, frames: u32, sample_rate: f32, volume: f32, delay: f32) void;
