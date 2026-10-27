//! The software mixer. It adds many voices into one stereo buffer. Each
//! voice plays a `Sample`, a `Stream` or a tone. Each voice is in a volume
//! group, and a voice at a position gets a pan and a distance loss from the
//! listener. The mixer has no platform code: the native and web backends
//! call `mix` for each block of output.

const std = @import("std");
const Sample = @import("sample.zig").Sample;
const Stream = @import("vorbis.zig").Stream;

/// The number of voices that play at the same time.
pub const max_voices = 64;
/// The number of volume groups. The application gives each group its
/// meaning, for example 0 = effects and 1 = music.
pub const group_count = 8;

pub const Vec3 = [3]f32;

/// How the gain of a voice at a position falls with distance.
pub const Attenuation = union(enum) {
    /// The distance has no effect.
    none,
    /// Gain 1 at `min_distance` or nearer, falling in a line to 0 at
    /// `max_distance`.
    linear: struct { min_distance: f32 = 1, max_distance: f32 = 32 },
    /// Gain `min_distance / (min_distance + rolloff * (distance -
    /// min_distance))`, and 0 past `max_distance`.
    inverse: struct { min_distance: f32 = 1, max_distance: f32 = 64, rolloff: f32 = 1 },

    /// The gain at `distance`, 0 to 1.
    pub fn gain(self: Attenuation, distance: f32) f32 {
        const d = @max(distance, 0);
        switch (self) {
            .none => return 1,
            .linear => |a| {
                if (d <= a.min_distance) return 1;
                if (d >= a.max_distance) return 0;
                return 1 - (d - a.min_distance) / (a.max_distance - a.min_distance);
            },
            .inverse => |a| {
                if (d > a.max_distance) return 0;
                if (d <= a.min_distance) return 1;
                const min = @max(a.min_distance, 1e-6);
                return min / (min + @max(a.rolloff, 0) * (d - min));
            },
        }
    }
};

/// The position and direction of the ears.
pub const Listener = struct {
    position: Vec3 = .{ 0, 0, 0 },
    /// The direction that the listener looks in. It need not be a unit
    /// vector.
    forward: Vec3 = .{ 0, 0, -1 },
    up: Vec3 = .{ 0, 1, 0 },
};

pub const PlayOptions = struct {
    /// 0 to 1.
    volume: f32 = 1,
    /// The playback speed. 2 is one octave up.
    pitch: f32 = 1,
    /// Stereo position: -1 left, 0 centre, 1 right. A voice with a
    /// `position` gets its pan from the listener.
    pan: f32 = 0,
    /// The volume group, 0 to `group_count - 1`.
    group: u8 = 0,
    looping: bool = false,
    /// Seconds from now to the start of the voice.
    delay: f32 = 0,
    /// The position of the sound. Null: the sound has no position.
    position: ?Vec3 = null,
    /// True: `position` is relative to the listener, in listener space (x
    /// right, y up, -z forward).
    relative: bool = false,
    attenuation: Attenuation = .{ .linear = .{} },
};

/// A handle to a playing voice. A handle stays safe to use after its voice
/// ends: the calls then do nothing.
pub const Voice = struct {
    index: u16,
    generation: u16,
};

pub const Waveform = enum(u8) { sine = 0, square = 1, sawtooth = 2, triangle = 3, noise = 4 };

/// A synthesized tone, for the waveform API on platforms with no Web Audio.
pub const Tone = struct {
    frequency: f32,
    frequency_end: f32,
    duration: f32,
    waveform: Waveform,
    phase: f32 = 0,
    noise_state: u32 = 0x9E3779B9,

    /// The value at time `t` seconds. `rate` is the output rate.
    fn next(self: *Tone, t: f32, rate: f32) f32 {
        const env = self.envelope(t);
        if (self.waveform == .noise) {
            // xorshift32 white noise, with a quadratic decay.
            var x = self.noise_state;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.noise_state = x;
            const white = @as(f32, @floatFromInt(x)) / 2147483648.0 - 1.0;
            const k = 1 - t / self.duration;
            return white * k * k;
        }
        var freq = self.frequency;
        if (self.frequency_end != self.frequency and self.frequency > 0) {
            const end = @max(self.frequency_end, 1);
            freq = self.frequency * std.math.pow(f32, end / self.frequency, t / self.duration);
        }
        const p = self.phase;
        self.phase = @mod(p + freq / rate, 1);
        const v: f32 = switch (self.waveform) {
            .sine => @sin(p * 2 * std.math.pi),
            .square => if (p < 0.5) 1 else -1,
            .sawtooth => 2 * p - 1,
            .triangle => 1 - 4 * @abs(p - 0.5),
            .noise => unreachable,
        };
        return v * env;
    }

    /// 5 ms attack and 10 ms release, as the Web Audio tone does.
    fn envelope(self: Tone, t: f32) f32 {
        if (t < 0.005) return t / 0.005;
        const left = self.duration - t;
        if (left < 0.01) return @max(left, 0) / 0.01;
        return 1;
    }
};

const Source = union(enum) {
    sample: *const Sample,
    stream: *Stream,
    tone: Tone,
};

const State = enum {
    free,
    playing,
    /// Ended, but the mixer owns the sample, and the backend must free it
    /// with `takeEnded` before the slot is free.
    ended_owned,
};

const Slot = struct {
    state: State = .free,
    generation: u16 = 0,
    source: Source = .{ .tone = undefined },
    options: PlayOptions = .{},
    /// True: the mixer must give the sample back with `takeEnded`.
    owned: bool = false,
    /// The read position in source frames.
    pos: f64 = 0,
    /// Output frames to wait before the first frame.
    wait: u64 = 0,
    /// The gains of the last block, so that a change ramps over one block
    /// and does not click.
    gain: [2]f32 = .{ 0, 0 },
    fresh: bool = true,
};

pub const Mixer = struct {
    /// Output frames each second.
    rate: u32,
    master_volume: f32 = 1,
    group_volume: [group_count]f32 = @splat(1),
    listener: Listener = .{},
    slots: [max_voices]Slot = @splat(.{}),
    /// The envelope of the output limiter.
    limiter: f32 = 1,

    pub fn init(rate: u32) Mixer {
        return .{ .rate = @max(rate, 1) };
    }

    pub fn playSample(self: *Mixer, sample: *const Sample, options: PlayOptions) ?Voice {
        if (sample.frames() == 0) return null;
        return self.start(.{ .sample = sample }, options, false);
    }

    /// Play a sample that the mixer owns. When the voice ends, `takeEnded`
    /// gives the sample back, for the backend to free.
    pub fn playOwnedSample(self: *Mixer, sample: *const Sample, options: PlayOptions) ?Voice {
        if (sample.frames() == 0) return null;
        return self.start(.{ .sample = sample }, options, true);
    }

    /// Play a stream from its first frame. A stream plays in one voice at a
    /// time: this call stops the voice that plays it now.
    pub fn playStream(self: *Mixer, stream: *Stream, options: PlayOptions) ?Voice {
        for (&self.slots) |*slot| {
            if (slot.state == .playing and slot.source == .stream and slot.source.stream == stream) self.end(slot);
        }
        stream.rewind();
        return self.start(.{ .stream = stream }, options, false);
    }

    pub fn playTone(self: *Mixer, tone: Tone, options: PlayOptions) ?Voice {
        if (tone.duration <= 0) return null;
        return self.start(.{ .tone = tone }, options, false);
    }

    fn start(self: *Mixer, source: Source, options: PlayOptions, owned: bool) ?Voice {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state != .free) continue;
            var o = options;
            o.group = @min(o.group, group_count - 1);
            slot.* = .{
                .state = .playing,
                .generation = slot.generation +% 1,
                .source = source,
                .options = o,
                .owned = owned,
                .wait = @intFromFloat(@max(o.delay, 0) * @as(f32, @floatFromInt(self.rate))),
            };
            return .{ .index = @intCast(i), .generation = slot.generation };
        }
        return null;
    }

    fn slotOf(self: *Mixer, voice: Voice) ?*Slot {
        if (voice.index >= max_voices) return null;
        const slot = &self.slots[voice.index];
        if (slot.state != .playing or slot.generation != voice.generation) return null;
        return slot;
    }

    pub fn isPlaying(self: *Mixer, voice: Voice) bool {
        return self.slotOf(voice) != null;
    }

    pub fn stop(self: *Mixer, voice: Voice) void {
        if (self.slotOf(voice)) |slot| self.end(slot);
    }

    pub fn stopGroup(self: *Mixer, group: u8) void {
        for (&self.slots) |*slot| {
            if (slot.state == .playing and slot.options.group == group) self.end(slot);
        }
    }

    pub fn stopAll(self: *Mixer) void {
        for (&self.slots) |*slot| {
            if (slot.state == .playing) self.end(slot);
        }
    }

    fn end(_: *Mixer, slot: *Slot) void {
        slot.state = if (slot.owned) .ended_owned else .free;
    }

    /// Give back one sample of an ended owned voice, or null. Call it until
    /// it gives null.
    pub fn takeEnded(self: *Mixer) ?*const Sample {
        for (&self.slots) |*slot| {
            if (slot.state != .ended_owned) continue;
            slot.state = .free;
            slot.owned = false;
            return slot.source.sample;
        }
        return null;
    }

    pub fn setVolume(self: *Mixer, voice: Voice, volume: f32) void {
        if (self.slotOf(voice)) |slot| slot.options.volume = volume;
    }

    pub fn setPitch(self: *Mixer, voice: Voice, pitch: f32) void {
        if (self.slotOf(voice)) |slot| slot.options.pitch = pitch;
    }

    pub fn setPan(self: *Mixer, voice: Voice, pan: f32) void {
        if (self.slotOf(voice)) |slot| slot.options.pan = pan;
    }

    pub fn setPosition(self: *Mixer, voice: Voice, position: ?Vec3) void {
        if (self.slotOf(voice)) |slot| slot.options.position = position;
    }

    pub fn setLooping(self: *Mixer, voice: Voice, looping: bool) void {
        if (self.slotOf(voice)) |slot| slot.options.looping = looping;
    }

    pub fn setGroupVolume(self: *Mixer, group: u8, volume: f32) void {
        if (group < group_count) self.group_volume[group] = std.math.clamp(volume, 0, 1);
    }

    /// The number of voices that play now.
    pub fn activeVoices(self: *const Mixer) usize {
        var n: usize = 0;
        for (self.slots) |slot| n += @intFromBool(slot.state == .playing);
        return n;
    }

    /// The left and right gains of a voice for the next block.
    pub fn voiceGains(self: *const Mixer, options: PlayOptions) [2]f32 {
        var gain = std.math.clamp(options.volume, 0, 1) * self.group_volume[options.group] * self.master_volume;
        var pan = options.pan;
        if (options.position) |p| {
            const s = spatialize(self.listener, p, options.relative, options.attenuation);
            gain *= s.gain;
            pan = s.pan;
        }
        const g = panGains(pan);
        return .{ g[0] * gain, g[1] * gain };
    }

    /// Mix the voices into `out`: interleaved stereo frames, left then
    /// right. `out` gets the sum, not added to its old values.
    pub fn mix(self: *Mixer, out: []f32) void {
        @memset(out, 0);
        const frames = out.len / 2;
        if (frames == 0) return;
        const out_rate: f64 = @floatFromInt(self.rate);
        for (&self.slots) |*slot| {
            if (slot.state != .playing) continue;
            const target = self.voiceGains(slot.options);
            const from = if (slot.fresh) target else slot.gain;
            slot.fresh = false;
            slot.gain = target;
            const inv: f32 = 1 / @as(f32, @floatFromInt(frames));
            const step: f64 = switch (slot.source) {
                .sample => |s| @as(f64, @floatFromInt(s.rate)) / out_rate,
                .stream => |s| @as(f64, @floatFromInt(s.rate())) / out_rate,
                .tone => 1,
            } * @max(slot.options.pitch, 0);
            var f: usize = 0;
            while (f < frames) : (f += 1) {
                if (slot.wait > 0) {
                    slot.wait -= 1;
                    continue;
                }
                const v = self.read(slot) orelse {
                    self.end(slot);
                    break;
                };
                const k = @as(f32, @floatFromInt(f)) * inv;
                out[f * 2] += v[0] * (from[0] + (target[0] - from[0]) * k);
                out[f * 2 + 1] += v[1] * (from[1] + (target[1] - from[1]) * k);
                slot.pos += step;
            }
        }
        self.limit(out);
    }

    /// The value of a voice at its position, with linear interpolation
    /// between two frames. Null at the end of a voice that does not loop.
    fn read(self: *Mixer, slot: *Slot) ?[2]f32 {
        switch (slot.source) {
            .sample => |s| {
                const n = s.frames();
                var i: usize = @intFromFloat(slot.pos);
                if (i >= n) {
                    if (!slot.options.looping) return null;
                    slot.pos = @mod(slot.pos, @as(f64, @floatFromInt(n)));
                    i = @min(@as(usize, @intFromFloat(slot.pos)), n - 1);
                }
                const t: f32 = @floatCast(slot.pos - @as(f64, @floatFromInt(i)));
                const a = s.frame(i);
                const b = if (i + 1 < n) s.frame(i + 1) else if (slot.options.looping) s.frame(0) else a;
                return lerp(a, b, t);
            },
            .stream => |s| {
                var i: u64 = @intFromFloat(slot.pos);
                const a = s.frame(i) orelse blk: {
                    if (!slot.options.looping or i == 0) return null;
                    s.rewind();
                    slot.pos -= @floatFromInt(i);
                    i = @intFromFloat(slot.pos);
                    break :blk s.frame(i) orelse return null;
                };
                const t: f32 = @floatCast(slot.pos - @as(f64, @floatFromInt(i)));
                const b = s.frame(i + 1) orelse a;
                return lerp(a, b, t);
            },
            .tone => |*tone| {
                const t: f32 = @floatCast(slot.pos / @as(f64, @floatFromInt(self.rate)));
                if (t >= tone.duration) return null;
                const v = tone.next(t, @floatFromInt(self.rate));
                return .{ v, v };
            },
        }
    }

    /// A limiter on the sum: when a peak is over 1, the whole output gets
    /// quieter, and comes back over 200 ms. The waveform and the stereo
    /// balance do not change.
    fn limit(self: *Mixer, out: []f32) void {
        var peak: f32 = 1;
        for (out) |v| peak = @max(peak, @abs(v));
        if (peak <= 1 and self.limiter <= 1) return;
        self.limiter = @max(self.limiter, peak);
        const release = @exp(-1 / (0.2 * @as(f32, @floatFromInt(self.rate))));
        var f: usize = 0;
        while (f + 1 < out.len) : (f += 2) {
            const g = 1 / self.limiter;
            out[f] *= g;
            out[f + 1] *= g;
            self.limiter = @max(self.limiter * release, peak);
        }
    }
};

fn lerp(a: [2]f32, b: [2]f32, t: f32) [2]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

/// The left and right gains for a pan from -1 (left) to 1 (right). The
/// centre gives full gain on each side.
pub fn panGains(pan: f32) [2]f32 {
    const p = std.math.clamp(pan, -1, 1);
    return .{ @min(1, 1 - p), @min(1, 1 + p) };
}

pub const Spatial = struct {
    /// The distance loss, 0 to 1.
    gain: f32,
    /// -1 left to 1 right.
    pan: f32,
};

/// The gain and the pan of a sound at `position` for `listener`. The pan
/// is the part of the direction to the sound that points to the right of
/// the listener.
pub fn spatialize(listener: Listener, position: Vec3, relative: bool, attenuation: Attenuation) Spatial {
    const d: Vec3 = if (relative) position else sub(position, listener.position);
    const distance = @sqrt(dot(d, d));
    const gain = attenuation.gain(distance);
    if (distance < 1e-4) return .{ .gain = gain, .pan = 0 };
    const side = if (relative) d[0] else blk: {
        const right = cross(listener.forward, listener.up);
        const len = @sqrt(dot(right, right));
        if (len < 1e-6) break :blk 0;
        break :blk dot(d, right) / len;
    };
    return .{ .gain = gain, .pan = std.math.clamp(side / distance, -1, 1) };
}

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn constSample(buf: []f32, value: f32, rate: u32) Sample {
    @memset(buf, value);
    return .{ .data = buf, .channels = 1, .rate = rate };
}

test "Attenuation: linear and inverse" {
    const lin: Attenuation = .{ .linear = .{ .min_distance = 2, .max_distance = 10 } };
    try testing.expectEqual(@as(f32, 1), lin.gain(0));
    try testing.expectEqual(@as(f32, 1), lin.gain(2));
    try testing.expectApproxEqAbs(@as(f32, 0.5), lin.gain(6), 1e-6);
    try testing.expectEqual(@as(f32, 0), lin.gain(10));
    try testing.expectEqual(@as(f32, 0), lin.gain(50));
    const inv: Attenuation = .{ .inverse = .{ .min_distance = 1, .max_distance = 100, .rolloff = 1 } };
    try testing.expectEqual(@as(f32, 1), inv.gain(0.5));
    try testing.expectApproxEqAbs(@as(f32, 0.25), inv.gain(4), 1e-6);
    try testing.expectEqual(@as(f32, 0), inv.gain(101));
    try testing.expectEqual(@as(f32, 1), (Attenuation{ .none = {} }).gain(1000));
}

test "spatialize: pan follows the listener direction" {
    const att: Attenuation = .none;
    // The default listener looks along -z. +x is to the right.
    var l: Listener = .{};
    try testing.expectApproxEqAbs(@as(f32, 1), spatialize(l, .{ 5, 0, 0 }, false, att).pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), spatialize(l, .{ -5, 0, 0 }, false, att).pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), spatialize(l, .{ 0, 0, -5 }, false, att).pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), spatialize(l, .{ 0, 0, 5 }, false, att).pan, 1e-6);
    // 45 degrees to the right, in front.
    try testing.expectApproxEqAbs(@as(f32, std.math.sqrt1_2), spatialize(l, .{ 1, 0, -1 }, false, att).pan, 1e-6);
    // Turn the listener to look along +x: the sound at +x is now in front,
    // and a sound at +z is on the right.
    l.forward = .{ 1, 0, 0 };
    try testing.expectApproxEqAbs(@as(f32, 0), spatialize(l, .{ 5, 0, 0 }, false, att).pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), spatialize(l, .{ 0, 0, 5 }, false, att).pan, 1e-6);
    // The listener position counts.
    l.position = .{ 0, 0, 10 };
    try testing.expectApproxEqAbs(@as(f32, -1), spatialize(l, .{ 0, 0, 5 }, false, att).pan, 1e-6);
    // A relative position ignores the listener.
    try testing.expectApproxEqAbs(@as(f32, 1), spatialize(l, .{ 3, 0, 0 }, true, att).pan, 1e-6);
    // At the listener: centred.
    try testing.expectEqual(@as(f32, 0), spatialize(l, l.position, false, att).pan);
}

test "spatialize: distance loss from the listener position" {
    const att: Attenuation = .{ .linear = .{ .min_distance = 0, .max_distance = 10 } };
    const l: Listener = .{ .position = .{ 100, 0, 0 } };
    try testing.expectApproxEqAbs(@as(f32, 0.5), spatialize(l, .{ 105, 0, 0 }, false, att).gain, 1e-6);
    try testing.expectEqual(@as(f32, 0), spatialize(l, .{ 0, 0, 0 }, false, att).gain);
}

test "panGains: centre is full on both sides" {
    try testing.expectEqual([2]f32{ 1, 1 }, panGains(0));
    try testing.expectEqual([2]f32{ 1, 0 }, panGains(-1));
    try testing.expectEqual([2]f32{ 0, 1 }, panGains(1));
    try testing.expectEqual([2]f32{ 0.5, 1 }, panGains(0.5));
    try testing.expectEqual([2]f32{ 0, 1 }, panGains(9));
}

test "Mixer: voices add, and groups have their own volume" {
    var m = Mixer.init(100);
    var a_buf: [50]f32 = undefined;
    var b_buf: [50]f32 = undefined;
    const a = constSample(&a_buf, 0.25, 100);
    const b = constSample(&b_buf, 0.125, 100);
    _ = m.playSample(&a, .{ .group = 0 }).?;
    _ = m.playSample(&b, .{ .group = 1 }).?;
    var out: [8]f32 = undefined;
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.375), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.375), out[1], 1e-6);
    // Group 1 at half volume. The change ramps over one block.
    m.setGroupVolume(1, 0.5);
    m.mix(&out);
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.25 + 0.0625), out[6], 1e-6);
    m.setGroupVolume(0, 0);
    m.mix(&out);
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.0625), out[7], 1e-6);
    m.master_volume = 0.5;
    m.mix(&out);
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.03125), out[7], 1e-6);
}

test "Mixer: many voices" {
    var m = Mixer.init(100);
    var buf: [10]f32 = undefined;
    const s = constSample(&buf, 0.01, 100);
    var n: usize = 0;
    while (m.playSample(&s, .{})) |_| n += 1;
    try testing.expectEqual(@as(usize, max_voices), n);
    try testing.expectEqual(@as(usize, max_voices), m.activeVoices());
    var out: [4]f32 = undefined;
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.01 * max_voices), out[0], 1e-5);
}

test "Mixer: a voice ends, and its handle goes stale" {
    var m = Mixer.init(100);
    var buf: [3]f32 = undefined;
    const s = constSample(&buf, 0.5, 100);
    const v = m.playSample(&s, .{}).?;
    try testing.expect(m.isPlaying(v));
    var out: [10]f32 = undefined;
    m.mix(&out);
    try testing.expectEqual(@as(f32, 0.5), out[4]);
    try testing.expectEqual(@as(f32, 0), out[6]);
    try testing.expect(!m.isPlaying(v));
    // The new voice takes the same slot, with a new generation.
    const w = m.playSample(&s, .{}).?;
    try testing.expectEqual(v.index, w.index);
    m.stop(v); // stale: does nothing
    try testing.expect(m.isPlaying(w));
    m.stop(w);
    try testing.expect(!m.isPlaying(w));
}

test "Mixer: looping, pitch and delay" {
    var m = Mixer.init(4);
    var data = [_]f32{ 0, 0.5, 1, 0.5 };
    const s = Sample{ .data = &data, .channels = 1, .rate = 4 };
    _ = m.playSample(&s, .{ .looping = true }).?;
    var out: [16]f32 = undefined;
    m.mix(&out);
    const left = [_]f32{ out[0], out[2], out[4], out[6], out[8], out[10], out[12], out[14] };
    try testing.expectEqualSlices(f32, &.{ 0, 0.5, 1, 0.5, 0, 0.5, 1, 0.5 }, &left);

    // Pitch 0.5 reads half a frame each output frame (interpolated).
    m.stopAll();
    _ = m.playSample(&s, .{ .pitch = 0.5 }).?;
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[4], 1e-6);

    // A delay of 0.5 s at 4 frames each second: two frames of silence.
    m.stopAll();
    _ = m.playSample(&s, .{ .delay = 0.5 }).?;
    m.mix(&out);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0.5, 1 }, &.{ out[0], out[2], out[4], out[6], out[8] });
}

test "Mixer: a voice at a position is panned and loses volume with distance" {
    var m = Mixer.init(100);
    var buf: [100]f32 = undefined;
    const s = constSample(&buf, 0.5, 100);
    const att: Attenuation = .{ .linear = .{ .min_distance = 0, .max_distance = 20 } };
    _ = m.playSample(&s, .{ .position = .{ 10, 0, 0 }, .attenuation = att }).?;
    var out: [4]f32 = undefined;
    m.mix(&out);
    // On the right, half the distance to the max: 0.5 * 0.5 on the right.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[1], 1e-6);
    // The listener turns around: the sound is now on the left.
    m.listener.forward = .{ 0, 0, 1 };
    m.mix(&out);
    m.mix(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[3], 1e-6);
}

test "Mixer: the limiter keeps the sum in range" {
    var m = Mixer.init(1000);
    var buf: [1000]f32 = undefined;
    const s = constSample(&buf, 0.9, 1000);
    for (0..4) |_| _ = m.playSample(&s, .{}).?;
    var out: [200]f32 = undefined;
    m.mix(&out);
    for (out) |v| try testing.expect(@abs(v) <= 1.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), out[0], 1e-5);
}

test "Mixer: owned samples come back when their voice ends" {
    var m = Mixer.init(100);
    var buf: [2]f32 = undefined;
    const s = constSample(&buf, 0.5, 100);
    const v = m.playOwnedSample(&s, .{}).?;
    try testing.expectEqual(@as(?*const Sample, null), m.takeEnded());
    var out: [8]f32 = undefined;
    m.mix(&out);
    try testing.expect(!m.isPlaying(v));
    try testing.expectEqual(@as(?*const Sample, &s), m.takeEnded());
    try testing.expectEqual(@as(?*const Sample, null), m.takeEnded());
}

test "Mixer: tones" {
    var m = Mixer.init(1000);
    _ = m.playTone(.{ .frequency = 100, .frequency_end = 100, .duration = 0.1, .waveform = .square }, .{}).?;
    var out: [400]f32 = undefined;
    m.mix(&out);
    // After the 5 ms attack, a square wave of full value.
    try testing.expectApproxEqAbs(@as(f32, 1), @abs(out[20]), 1e-5);
    // The tone ends after 0.1 s (100 frames).
    try testing.expectEqual(@as(f32, 0), out[2 * 150]);
    try testing.expectEqual(@as(usize, 0), m.activeVoices());
    _ = m.playTone(.{ .frequency = 0, .frequency_end = 0, .duration = 0.1, .waveform = .noise }, .{}).?;
    m.mix(&out);
    var any = false;
    for (out[0..100]) |v| any = any or v != 0;
    try testing.expect(any);
}

test "Mixer: a stream plays and loops" {
    const ogg = @embedFile("test_ogg");
    const stream = try Stream.open(testing.allocator, ogg);
    defer stream.deinit();
    var m = Mixer.init(stream.rate());
    const v = m.playStream(stream, .{ .looping = true }).?;
    var out: [2 * 4096]f32 = undefined;
    // 1 s of data: 12 blocks of 4096 frames is more than one loop.
    var peak: f32 = 0;
    for (0..12) |_| {
        m.mix(&out);
        for (out) |x| peak = @max(peak, @abs(x));
    }
    try testing.expect(m.isPlaying(v));
    try testing.expect(peak > 0.1);
    // Not looping: the voice ends.
    m.setLooping(v, false);
    for (0..12) |_| m.mix(&out);
    try testing.expect(!m.isPlaying(v));
}
