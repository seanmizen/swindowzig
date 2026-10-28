//! The run of a demo: the command line, the TAS player and the frame
//! capture.
//!
//! Each demo takes the same flags (native only):
//!
//! - `--tas <file>`: play this TAS script. Without it, the demo plays the
//!   script that it embeds, or gives the control to the player.
//! - `--preset low|medium|high`: the graphics preset (REQ-GPU-026).
//! - `--capture <dir>`: no window. Write each frame of the script to
//!   `<dir>/frame_NNNNN.ppm`, then stop (REQ-DEMO-002).
//! - `--hashes <file>`: no window. Write the frame hash of each checkpoint
//!   to the file, then stop (REQ-DEMO-001).
//! - `--check`: no window. Play the script, run the checks of the demo, and
//!   stop with 0 (pass) or 1 (fail).
//!
//! A run with no window has the fixed size `offline_size` and one tick for
//! each frame (`tick_timing = .unlimited`). So the frame N is always the
//! frame after the tick N, on each machine (REQ-DEMO-002).
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const core = @import("sw_core");
const sw_render = @import("sw_render");

const is_wasm = builtin.cpu.arch.isWasm();

pub const Preset = enum { low, medium, high };

/// The frame size of a run with no window.
pub const offline_size: [2]u32 = .{ 800, 450 };

pub const Options = struct {
    tas_path: ?[]const u8 = null,
    preset: Preset = .high,
    capture_dir: ?[]const u8 = null,
    /// Write every `capture_every`th frame (the default gives 30 frames
    /// each second at 60 ticks each second).
    capture_every: u32 = 2,
    hashes_path: ?[]const u8 = null,
    check: bool = false,

    /// True when the run has no window.
    pub fn offline(self: Options) bool {
        return self.capture_dir != null or self.hashes_path != null or self.check;
    }
};

pub const ArgError = error{ MissingValue, BadPreset, BadNumber, UnknownFlag };

/// Read the flags of a demo. `args[0]` is the program.
pub fn parseArgs(args: []const [:0]const u8) ArgError!Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--check")) {
            o.check = true;
            continue;
        }
        const value: []const u8 = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--tas")) {
            if (value.len == 0) return error.MissingValue;
            o.tas_path = value;
        } else if (std.mem.eql(u8, a, "--preset")) {
            o.preset = std.meta.stringToEnum(Preset, value) orelse return error.BadPreset;
        } else if (std.mem.eql(u8, a, "--capture")) {
            if (value.len == 0) return error.MissingValue;
            o.capture_dir = value;
        } else if (std.mem.eql(u8, a, "--capture-every")) {
            o.capture_every = std.fmt.parseInt(u32, value, 10) catch return error.BadNumber;
            if (o.capture_every == 0) return error.BadNumber;
        } else if (std.mem.eql(u8, a, "--hashes")) {
            if (value.len == 0) return error.MissingValue;
            o.hashes_path = value;
        } else {
            return error.UnknownFlag;
        }
        i += 1;
    }
    return o;
}

/// The usage text for an error in the flags.
pub const usage = "flags: [--tas <file>] [--preset low|medium|high] [--capture <dir>] [--capture-every <n>] [--hashes <file>] [--check]";

/// Change the app configuration for the options: no window, a fixed size
/// and one tick for each frame when the run is offline.
pub fn configure(o: Options, c: *sw.Config) void {
    if (!o.offline()) return;
    c.headless = true;
    c.headless_gpu = true;
    c.tick_timing = .unlimited;
    c.size = .{ .w = offline_size[0], .h = offline_size[1] };
    c.surface_follows_window = false;
}

/// The graphics settings of a preset.
pub fn graphics(p: Preset) sw_render.GraphicsSettings {
    return sw_render.GraphicsSettings.preset(switch (p) {
        .low => .low,
        .medium => .medium,
        .high => .high,
    });
}

// =============================================================================
// The TAS player
// =============================================================================

/// Plays the events of a TAS script into the event bus, one tick at a
/// time. Call `feed` from the `preTick` callback.
///
/// The TAS tick 0 is the first tick after `start`. `mouse_move` moves a
/// pointer that starts at (0, 0): the event gets the new position too, so
/// a script can point at a widget.
pub const Player = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(core.Event) = .empty,
    index: usize = 0,
    /// The engine tick of the TAS tick 0. Null before the first `feed`.
    start_tick: ?u64 = null,
    /// The last TAS tick of the script.
    duration: u64 = 0,
    pointer: [2]f32 = .{ 0, 0 },

    pub fn init(allocator: std.mem.Allocator, source: []const u8, tick_hz: u32) !Player {
        var script = try core.TasScript.parse(allocator, source);
        defer script.deinit();
        const events = try script.toEvents(tick_hz);
        return .{ .allocator = allocator, .events = events, .duration = script.getDuration() };
    }

    pub fn deinit(self: *Player) void {
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Play the script again from its start, at the next tick.
    pub fn restart(self: *Player) void {
        self.index = 0;
        self.start_tick = null;
        self.pointer = .{ 0, 0 };
    }

    /// The TAS tick of the engine tick `tick`.
    pub fn tasTick(self: *const Player, tick: u64) u64 {
        const s = self.start_tick orelse return 0;
        return tick -| s;
    }

    /// True after the last tick of the script.
    pub fn done(self: *const Player, tick: u64) bool {
        return self.start_tick != null and self.tasTick(tick) > self.duration;
    }

    /// Push the events of this tick. Call it in `preTick`.
    pub fn feed(self: *Player, ctx: *sw.Context) !void {
        const tick = ctx.tickId();
        if (self.start_tick == null) self.start_tick = tick;
        const t = self.tasTick(tick);
        while (self.index < self.events.items.len) {
            const e = self.events.items[self.index];
            if (e.tick_id > t) break;
            self.index += 1;
            if (e.tick_id < t) continue;
            var payload = e.payload;
            switch (payload) {
                .pointer_move => |*m| {
                    self.pointer[0] += m.dx;
                    self.pointer[1] += m.dy;
                    m.x = self.pointer[0];
                    m.y = self.pointer[1];
                },
                else => {},
            }
            try ctx.bus().push(tick, e.t_ns, payload);
        }
    }
};

/// Read a TAS script file (native), or give the embedded script.
pub fn loadScript(ctx: *sw.Context, o: Options, embedded: []const u8) ![]const u8 {
    const path = o.tas_path orelse return embedded;
    if (comptime is_wasm) return embedded;
    return std.Io.Dir.cwd().readFileAlloc(ctx.io.?, path, ctx.allocator(), .limited(1 << 20));
}

// =============================================================================
// The frames: capture and hashes
// =============================================================================

/// The frame hash of a checkpoint tick.
pub const Hash = struct { tick: u64, hash: u64 };

/// Reads the frames of an offline run back: it writes the capture, and
/// keeps the hash of each checkpoint (REQ-DEMO-001, REQ-DEMO-002).
pub const Frames = struct {
    options: Options,
    /// A checkpoint every `checkpoint_every` TAS ticks, from tick 0.
    checkpoint_every: u64 = 60,
    hashes: std.ArrayList(Hash) = .empty,
    captured: u32 = 0,
    dir_made: bool = false,

    /// True when the frame of the TAS tick `tas_tick` must draw. A run
    /// with no window draws only the frames that it captures or hashes:
    /// the state changes only on the ticks, so the other frames change
    /// nothing (REQ-DEMO-001).
    pub fn wanted(self: *const Frames, tas_tick: u64) bool {
        if (!self.options.offline()) return true;
        if (self.options.capture_dir != null and tas_tick % self.options.capture_every == 0) return true;
        return tas_tick % self.checkpoint_every == 0;
    }

    /// Read the frame of the TAS tick `tas_tick` back, after
    /// `FrameGraph.execute` and before `gpu.present`. It does nothing in
    /// a run with a window, and on the web.
    pub fn frame(self: *Frames, ctx: *sw.Context, tas_tick: u64) !void {
        if (comptime is_wasm) return;
        if (!self.options.offline()) return;
        const want_capture = self.options.capture_dir != null and tas_tick % self.options.capture_every == 0;
        const want_hash = tas_tick % self.checkpoint_every == 0;
        if (!want_capture and !want_hash) return;
        const allocator = ctx.allocator();
        const gpu = ctx.gpu();
        const pixels = try gpu.captureFrame(allocator);
        defer allocator.free(pixels);
        if (want_hash) try self.hashes.append(allocator, .{ .tick = tas_tick, .hash = std.hash.Wyhash.hash(0, pixels) });
        if (want_capture) try self.writePpm(ctx, pixels, gpu.getSurfaceWidth(), gpu.getSurfaceHeight());
    }

    fn writePpm(self: *Frames, ctx: *sw.Context, bgra: []const u8, w: u32, h: u32) !void {
        const io = ctx.io.?;
        const dir = self.options.capture_dir.?;
        if (!self.dir_made) {
            try std.Io.Dir.cwd().createDirPath(io, dir);
            self.dir_made = true;
        }
        const allocator = ctx.allocator();
        const rgb = try allocator.alloc(u8, @as(usize, w) * h * 3);
        defer allocator.free(rgb);
        for (0..@as(usize, w) * h) |i| {
            rgb[i * 3 + 0] = bgra[i * 4 + 2];
            rgb[i * 3 + 1] = bgra[i * 4 + 1];
            rgb[i * 3 + 2] = bgra[i * 4 + 0];
        }
        var name_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "{s}/frame_{d:0>5}.ppm", .{ dir, self.captured });
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ w, h });
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, hdr);
        try file.writeStreamingAll(io, rgb);
        self.captured += 1;
    }

    /// Write the hashes file (when `--hashes`) and log the hashes.
    pub fn finish(self: *Frames, ctx: *sw.Context, name: []const u8) !void {
        if (comptime is_wasm) return;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(ctx.allocator());
        for (self.hashes.items) |h| {
            var line: [64]u8 = undefined;
            try text.appendSlice(ctx.allocator(), try std.fmt.bufPrint(&line, "{d} {x:0>16}\n", .{ h.tick, h.hash }));
        }
        std.log.info("{s}: {d} checkpoints, {d} frames captured", .{ name, self.hashes.items.len, self.captured });
        if (self.options.hashes_path) |path| {
            try std.Io.Dir.cwd().writeFile(ctx.io.?, .{ .sub_path = path, .data = text.items });
        }
    }
};

/// The end of an offline run: write the hashes and stop the process with
/// `code`.
pub fn exitOffline(ctx: *sw.Context, frames: *Frames, name: []const u8, code: u8) noreturn {
    // The web build has no offline run and no process to stop.
    if (comptime is_wasm) {
        @panic("an offline run on the web");
    } else {
        frames.finish(ctx, name) catch |err| {
            std.log.err("{s}: cannot write the hashes: {s}", .{ name, @errorName(err) });
            std.process.exit(1);
        };
        std.process.exit(code);
    }
}

/// A small seeded random number generator (SplitMix64). The demos use it
/// on the fixed timestep, so a replay gives the same numbers
/// (REQ-DEMO-001).
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// A float in [0, 1).
    pub fn float(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / @as(f32, 1 << 24);
    }

    pub fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.float();
    }
};

test "run: the flags of a demo" {
    const args = [_][:0]const u8{ "cow", "--tas", "a.tas", "--preset", "low", "--hashes", "h.txt" };
    const o = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.tas", o.tas_path.?);
    try std.testing.expectEqual(Preset.low, o.preset);
    try std.testing.expect(o.offline());
    try std.testing.expectError(error.BadPreset, parseArgs(&[_][:0]const u8{ "cow", "--preset", "ultra" }));
    try std.testing.expectError(error.UnknownFlag, parseArgs(&[_][:0]const u8{ "cow", "--fast" }));
}

test "run: the random numbers repeat for one seed" {
    var a = Rng.init(7);
    var b = Rng.init(7);
    for (0..100) |_| try std.testing.expectEqual(a.next(), b.next());
    for (0..100) |_| {
        const f = a.float();
        try std.testing.expect(f >= 0 and f < 1);
    }
}
