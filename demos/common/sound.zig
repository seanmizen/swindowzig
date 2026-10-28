//! Sounds that the demos make in code: no sound files. Each function fills
//! a mono `sw_audio.Sample` at 48 kHz. A seed gives the noise, so the
//! sounds are the same in each run.
const std = @import("std");
const sw_audio = @import("sw_audio");

pub const rate: u32 = 48000;

/// The demo sounds. The groups of the mixer: effects (0), ambience (1)
/// and weapons (2).
pub const group_effects: u8 = 0;
pub const group_ambience: u8 = 1;
pub const group_weapons: u8 = 2;

fn alloc(allocator: std.mem.Allocator, seconds: f32) ![]f32 {
    const n: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(rate)));
    const data = try allocator.alloc(f32, n);
    @memset(data, 0);
    return data;
}

fn sample(data: []f32) sw_audio.Sample {
    return .{ .data = data, .channels = 1, .rate = rate };
}

/// A white noise source (xorshift).
const Noise = struct {
    s: u32,
    fn next(self: *Noise) f32 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 17;
        self.s ^= self.s << 5;
        return @as(f32, @floatFromInt(self.s >> 8)) / @as(f32, 1 << 23) - 1;
    }
};

/// A short click: a sine blip at `freq` Hz.
pub fn click(allocator: std.mem.Allocator, freq: f32) !sw_audio.Sample {
    const data = try alloc(allocator, 0.06);
    for (data, 0..) |*d, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        d.* = 0.5 * @sin(std.math.tau * freq * t) * @exp(-t * 70);
    }
    return sample(data);
}

/// A low call of the cow: a falling saw tone through a soft filter.
pub fn moo(allocator: std.mem.Allocator) !sw_audio.Sample {
    const data = try alloc(allocator, 1.1);
    var phase: f32 = 0;
    var lp: f32 = 0;
    for (data, 0..) |*d, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        const f = 150 - 40 * t + 6 * @sin(t * 30);
        phase = @mod(phase + f / @as(f32, @floatFromInt(rate)), 1.0);
        const saw = phase * 2 - 1;
        lp += 0.08 * (saw - lp);
        const env = @min(t / 0.12, 1.0) * @max(0, 1 - (t - 0.8) / 0.3);
        d.* = 0.6 * lp * env;
    }
    return sample(data);
}

/// Wind: filtered noise that rises and falls. It loops with no click.
pub fn wind(allocator: std.mem.Allocator, seconds: f32) !sw_audio.Sample {
    const data = try alloc(allocator, seconds);
    var n: Noise = .{ .s = 0x1234567 };
    var lp: f32 = 0;
    var lp2: f32 = 0;
    for (data, 0..) |*d, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(data.len));
        lp += 0.02 * (n.next() - lp);
        lp2 += 0.05 * (lp - lp2);
        const swell = 0.6 + 0.4 * @sin(t * std.math.tau * 2);
        d.* = 1.5 * lp2 * swell;
    }
    // Fade the two ends into each other, so the loop has no step.
    const fade = @min(data.len / 8, rate / 4);
    for (0..fade) |i| {
        const k = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade));
        const j = data.len - fade + i;
        data[i] = data[i] * k + data[j] * (1 - k);
    }
    const out = try allocator.dupe(f32, data[0 .. data.len - fade]);
    allocator.free(data);
    return sample(out);
}

/// A gun shot: a noise burst, a low thump and a short tail.
pub fn shot(allocator: std.mem.Allocator, seed: u32, body: f32) !sw_audio.Sample {
    const data = try alloc(allocator, 0.5);
    var n: Noise = .{ .s = seed | 1 };
    var lp: f32 = 0;
    for (data, 0..) |*d, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        lp += body * (n.next() - lp);
        const crack = n.next() * @exp(-t * 90);
        const thump = @sin(std.math.tau * (70 - 40 * t) * t) * @exp(-t * 25);
        d.* = std.math.clamp(0.7 * crack + 0.6 * lp * @exp(-t * 12) + 0.8 * thump, -1, 1);
    }
    return sample(data);
}

/// A hit on a body or on snow: a soft thud.
pub fn thud(allocator: std.mem.Allocator, seed: u32) !sw_audio.Sample {
    const data = try alloc(allocator, 0.2);
    var n: Noise = .{ .s = seed | 1 };
    var lp: f32 = 0;
    for (data, 0..) |*d, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        lp += 0.05 * (n.next() - lp);
        d.* = 2.5 * lp * @exp(-t * 30) + 0.4 * @sin(std.math.tau * 110 * t) * @exp(-t * 40);
    }
    return sample(data);
}

pub fn free(allocator: std.mem.Allocator, s: *const sw_audio.Sample) void {
    allocator.free(s.data);
}
