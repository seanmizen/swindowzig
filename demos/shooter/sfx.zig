// The sounds of the shooter demo: 3D gun sound on `sw_audio` (REQ-DEMO-024).
//
// The models are the procedural bullet sounds of the action game
// (audio/): the impact on each surface material (audio/impact.zig) and the
// N-wave of a supersonic crack (audio/near_miss.zig). `init` renders each
// sound one time into a mono `sw_audio.Sample`. A shot then plays them as
// voices at a position in the world. The mixer of `sw_audio` gives each
// voice its pan and its distance loss from the listener, and a delay of
// distance / c puts the report of a far gun after its flash.
//
// The demo makes no sound in a capture or a check run. The frames do not
// depend on the sound.
const std = @import("std");
const sw_audio = @import("demo_common").audio;
const vec = @import("vec.zig");
const weapon = @import("weapon.zig");
const guns = @import("guns.zig");
const dsp = @import("audio/dsp.zig");
const impact = @import("audio/impact.zig");
const near_miss = @import("audio/near_miss.zig");
const game = @import("game.zig");
const V3 = vec.V3;
const v3 = vec.v3;

const Material = impact.Material;
const rate: u32 = @intFromFloat(dsp.rate);

/// The muzzle report: a long gun, a short gun (pistol and SMG), a shotgun.
const Report = enum { long, short, shotgun };

pub const Sfx = struct {
    allocator: std.mem.Allocator,
    audio: sw_audio.Audio,
    reports: [3]sw_audio.Sample,
    impacts: [std.enums.values(Material).len]sw_audio.Sample,
    crack: sw_audio.Sample,
    click: sw_audio.Sample,
    listener_pos: V3 = v3(0, 0, 0),

    pub fn init(allocator: std.mem.Allocator) !Sfx {
        var self: Sfx = .{
            .allocator = allocator,
            .audio = sw_audio.Audio.init(),
            .reports = undefined,
            .impacts = undefined,
            .crack = undefined,
            .click = undefined,
        };
        var rng = dsp.Rng.init(24);
        for (std.enums.values(Report), 0..) |r, i| self.reports[i] = try makeReport(allocator, r, &rng);
        for (std.enums.values(Material), 0..) |m, i| {
            const buf = try allocator.alloc(f32, dsp.at(0.7));
            const n = impact.strike(buf, m, 1, &rng);
            self.impacts[i] = .{ .data = try allocator.realloc(buf, n), .channels = 1, .rate = rate };
        }
        self.crack = try makeCrack(allocator, &rng);
        self.click = try makeClick(allocator, &rng);
        return self;
    }

    pub fn deinit(self: *Sfx) void {
        self.audio.stopAll();
        for (&self.reports) |*s| s.deinit(self.allocator);
        for (&self.impacts) |*s| s.deinit(self.allocator);
        self.crack.deinit(self.allocator);
        self.click.deinit(self.allocator);
    }

    /// The ears follow the camera.
    pub fn setListener(self: *Sfx, eye: V3, forward: V3) void {
        self.listener_pos = eye;
        self.audio.setListener(.{ .position = arr(eye), .forward = arr(forward), .up = .{ 0, 1, 0 } });
    }

    fn at(self: *Sfx, s: *const sw_audio.Sample, p: V3, volume: f32, delay: f32, range: f32) void {
        const dist = vec.len(p - self.listener_pos);
        _ = self.audio.playSample(s, .{
            .volume = std.math.clamp(volume, 0, 1),
            .position = arr(p),
            .delay = delay + dist / guns.sound_speed,
            .attenuation = .{ .inverse = .{ .min_distance = 2, .max_distance = range, .rolloff = 0.8 } },
        });
    }

    /// The sounds of the shots of one tick: the muzzle report at the gun,
    /// the crack of a bullet that passes near the ears, and the impact at
    /// the end of the path.
    pub fn shots(self: *Sfx, events: *const game.Events) void {
        for (events.shots[0..events.shot_n]) |s| {
            const st = weapon.gunStats(s.model);
            if (s.first) {
                const rep: Report = switch (weapon.models[s.model].class) {
                    .shotgun, .sawn_off => .shotgun,
                    .pistol, .revolver, .smg => .short,
                    else => .long,
                };
                self.at(&self.reports[@backingInt(rep)], s.o, if (s.bot == null) 0.55 else 0.9, 0, 300);
            }
            if (s.bot != null and st.supersonic()) {
                // The crack: from the point of the path nearest the ears.
                const d = vec.norm(s.e - s.o);
                const t = std.math.clamp(vec.dot(self.listener_pos - s.o, d), 0, vec.len(s.e - s.o));
                const p = s.o + d * vec.s(t);
                const miss = vec.len(p - self.listener_pos);
                if (miss < 6) self.at(&self.crack, p, 0.6 / (1 + miss), t / st.velocity - miss / guns.sound_speed, 40);
            }
            if (s.surface) |m| {
                const flight = vec.len(s.e - s.o) / @max(st.velocity, 1);
                const vol: f32 = if (s.hit_player) 0.9 else 0.7;
                self.at(&self.impacts[@backingInt(m)], s.e, vol, flight, 60);
            }
        }
        switch (events.hands) {
            .mag_out, .mag_in, .racked, .empty => self.at(&self.click, self.listener_pos + v3(0, -0.2, 0), 0.5, 0, 10),
            else => {},
        }
    }
};

fn arr(x: V3) [3]f32 {
    return .{ x[0], x[1], x[2] };
}

/// A muzzle report: a crack of noise and a falling low thump (sounds.zig
/// `muzzle` of the action game, as one sample).
fn makeReport(allocator: std.mem.Allocator, r: Report, rng: *dsp.Rng) !sw_audio.Sample {
    const p: struct { noise: f32, thump: f32, f0: f32, f1: f32, amp: f32 } = switch (r) {
        .long => .{ .noise = 0.11, .thump = 0.16, .f0 = 160, .f1 = 45, .amp = 1 },
        .short => .{ .noise = 0.075, .thump = 0.1, .f0 = 230, .f1 = 70, .amp = 0.8 },
        .shotgun => .{ .noise = 0.22, .thump = 0.26, .f0 = 110, .f1 = 32, .amp = 1 },
    };
    const n = dsp.at(@max(p.noise, p.thump) + 0.25);
    const buf = try allocator.alloc(f32, n);
    @memset(buf, 0);
    dsp.addNoise(buf, rng, 0, .{ .kind = .bandpass, .freq = 2200, .q = 0.6 }, 0.0005, p.noise, 1.0);
    dsp.addNoise(buf, rng, 0, .{ .kind = .lowpass, .freq = 700 }, 0.001, p.noise * 2.2, 0.7);
    var phase: f32 = 0;
    for (0..dsp.at(p.thump)) |i| {
        const t = @as(f32, @floatFromInt(i)) / dsp.rate;
        const k = t / p.thump;
        const f = p.f0 + (p.f1 - p.f0) * k;
        phase += std.math.tau * f / dsp.rate;
        buf[i] += 0.8 * @sin(phase) * (1 - k) * (1 - k);
    }
    dsp.normalise(buf, p.amp);
    return .{ .data = buf, .channels = 1, .rate = rate };
}

/// The crack of a supersonic bullet: an N-wave and a short bright tail.
fn makeCrack(allocator: std.mem.Allocator, rng: *dsp.Rng) !sw_audio.Sample {
    const buf = try allocator.alloc(f32, dsp.at(0.08));
    @memset(buf, 0);
    near_miss.addNWave(buf, 0.001, 0.0004, 1);
    dsp.addNoise(buf, rng, dsp.at(0.0015), .{ .kind = .highpass, .freq = 3000 }, 0.0002, 0.03, 0.25);
    dsp.normalise(buf, 0.9);
    return .{ .data = buf, .channels = 1, .rate = rate };
}

/// A small metal click: the magazine and the bolt.
fn makeClick(allocator: std.mem.Allocator, rng: *dsp.Rng) !sw_audio.Sample {
    const buf = try allocator.alloc(f32, dsp.at(0.05));
    @memset(buf, 0);
    dsp.addNoise(buf, rng, 0, .{ .kind = .bandpass, .freq = 4200, .q = 2 }, 0.0002, 0.02, 1);
    dsp.addMode(buf, 0, 2900, 0.03, 0.3, 0);
    dsp.normalise(buf, 0.6);
    return .{ .data = buf, .channels = 1, .rate = rate };
}
