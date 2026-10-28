//! The shared frame of each demo in `demos/` (REQ-DEMO-001).
//!
//! A demo gives an `App` type, and `Demo(App)` gives the native `main`, the
//! web exports, the command line, the script player, the overlay, the
//! frame capture and the frame hashes:
//!
//! ```zig
//! const demo = @import("demo_common");
//! const D = demo.Demo(App);
//! pub const std_options = demo.std_options;
//! pub const main = D.main;
//! comptime {
//!     D.exportWeb();
//! }
//!
//! const App = struct {
//!     pub const name = "cow";                    // demos/<name>/
//!     pub const script = @embedFile("cow.tas");  // the default script
//!     pub fn init(host: *demo.Host) !void {}     // add passes to host.graph
//!     pub fn set(host: *demo.Host, name: []const u8, value: []const u8) !void {}
//!     pub fn tick(host: *demo.Host) !void {}     // one fixed step: host.dt
//!     pub fn frame(host: *demo.Host, w: u32, h: u32) !sw_render.FrameUniforms {}
//!     // Optional: more overlay lines. Print into `bufs`, give the count.
//!     pub fn statLines(host: *demo.Host, bufs: [][128]u8, out: [][]const u8) usize {}
//!     pub fn reset(host: *demo.Host) !void {}    // optional: before a loop
//!     pub fn drawOverlay(host: *demo.Host, o: *demo.Overlay) !void {} // optional
//!     pub fn deinit(host: *demo.Host) void {}
//! };
//! ```
//!
//! The host owns the frame graph (`host.graph`) and the post chain
//! (`host.post`). The overlay pass draws on `.screen` at order 2000.
//!
//! Modes (see `cli.zig`):
//!
//! - Interactive (native window, or the web page): the script plays in a
//!   loop. The overlay shows the measured frame time.
//! - `--capture <dir>`: no window, one frame for each tick. The frames go
//!   to `<dir>/frames.bgra` (BGRA, 4 bytes each pixel). The run stops at
//!   the end of the script.
//! - `--check`: no window. The frame of each `checkpoint` is hashed and
//!   compared with `demos/<name>/hashes/lavapipe-<preset>.txt`.
//!
//! In capture and check runs the frames must not depend on the wall
//! clock, so the overlay shows the fixed tick time in place of the
//! measured frame time (REQ-DEMO-004).

const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const sw_gpu = @import("sw_gpu");
const sw_render = @import("sw_render");

pub const cli = @import("cli.zig");
pub const script = @import("script.zig");
pub const hashes = @import("hashes.zig");
pub const reflect = @import("reflect.zig");
pub const voxel_mesh = @import("voxel_mesh.zig");
pub const cow_model = @import("cow_model.zig");
pub const cow_scene = @import("cow_scene.zig");
pub const overlay = @import("overlay.zig");

pub const CowScene = cow_scene.CowScene;
pub const CowSettings = cow_scene.Settings;
pub const Overlay = overlay.Overlay;
pub const Preset = cli.Preset;

const is_wasm = builtin.cpu.arch.isWasm();

pub const std_options: std.Options = .{
    .logFn = if (is_wasm) sw.webLogFn else std.log.defaultLog,
};

/// The tick rate of each demo.
pub const tick_hz: u32 = 60;

/// The surface size of a preset.
pub fn presetSize(p: Preset) struct { w: u32, h: u32 } {
    return switch (p) {
        .low => .{ .w = 640, .h = 360 },
        .medium => .{ .w = 960, .h = 540 },
        .high => .{ .w = 1280, .h = 720 },
    };
}

/// The graphics settings of a preset (REQ-GPU-026).
pub fn presetGraphics(p: Preset) sw_render.GraphicsSettings {
    return sw_render.GraphicsSettings.preset(switch (p) {
        .low => .low,
        .medium => .medium,
        .high => .high,
    });
}

/// What a demo gets from the host.
pub const Host = struct {
    allocator: std.mem.Allocator,
    ctx: *sw.Context,
    gpu: *sw_gpu.GPU,
    options: cli.Options,
    /// The graphics settings of the preset. The demo reads the shadow map
    /// size, the cascades and the FXAA quality.
    graphics: sw_render.GraphicsSettings,
    graph: sw_render.FrameGraph,
    post: sw_render.PostChain,
    overlay: Overlay,
    /// The seconds of one tick.
    dt: f32 = 1.0 / @as(f32, @floatFromInt(tick_hz)),
    /// The tick of the script, from 0. It starts again at 0 for each loop.
    script_tick: u64 = 0,
    caption: []const u8 = "",

    /// True in a capture or check run (REQ-DEMO-004).
    pub fn deterministic(self: *const Host) bool {
        return self.options.deterministic();
    }
};

pub fn Demo(comptime App: type) type {
    return struct {
        const Self = @This();

        pub const config: sw.Config = .{
            .title = App.name,
            .size = .{ .w = presetSize(.medium).w, .h = presetSize(.medium).h },
            .tick_hz = tick_hz,
        };

        var options: cli.Options = .{};
        var host: Host = undefined;
        var ready = false;
        var source: []const u8 = App.script;
        var parsed: script.Script = undefined;
        var player: script.Player = undefined;
        var pending_checkpoint: ?[]const u8 = null;
        var ending = false;
        var records: std.ArrayList(hashes.Record) = .empty;
        var capture_file: ?std.Io.File = null;
        var captured: u64 = 0;
        var frame_times: sw_render.FrameTimes = .{};
        var last_frame_ns: ?u64 = null;
        var line_bufs: [overlay.max_stat_lines][128]u8 = undefined;

        pub const main = if (is_wasm) mainWasm else mainNative;

        fn mainWasm() void {}

        /// Make the web exports. Call it in a `comptime` block of the demo.
        pub fn exportWeb() void {
            if (is_wasm) sw.exportWeb(config, Callbacks);
        }

        fn mainNative(init: std.process.Init) !void {
            const arena = init.arena.allocator();
            const args = try init.minimal.args.toSlice(arena);
            const plain = try arena.alloc([]const u8, args.len -| 1);
            for (args[1..], 0..) |a, i| plain[i] = a;
            options = cli.parse(plain) catch |err| {
                std.log.err("{s}: bad command line ({s})\n{s}", .{ App.name, @errorName(err), cli.usage });
                std.process.exit(2);
            };
            var c = config;
            c.io = init.io;
            const size = presetSize(options.preset);
            c.size = .{ .w = size.w, .h = size.h };
            if (options.deterministic()) {
                c.headless = true;
                c.headless_gpu = true;
                c.tick_timing = .unlimited;
            }
            if (options.tas_path) |p| {
                source = std.Io.Dir.cwd().readFileAlloc(init.io, p, arena, .limited(1 << 20)) catch |err| {
                    std.log.err("{s}: cannot read the script {s} ({s})", .{ App.name, p, @errorName(err) });
                    std.process.exit(2);
                };
            }
            try sw.run(c, Callbacks);
        }

        fn fail(comptime fmt: []const u8, args: anytype) void {
            std.log.err(fmt, args);
            if (!is_wasm) std.process.exit(2);
        }

        const Callbacks = struct {
            pub fn init(ctx: *sw.Context) !void {
                const gpu = ctx.gpu();
                if (!gpu.isReady()) {
                    fail("{s}: no GPU", .{App.name});
                    return;
                }
                const allocator = ctx.allocator();
                var diag: script.Diagnostic = .{};
                parsed = script.parse(allocator, source, &diag) catch |err| {
                    fail("{s}: script line {d}: {s}", .{ App.name, diag.line, @errorName(err) });
                    return;
                };
                player = .{ .script = &parsed };

                host = .{
                    .allocator = allocator,
                    .ctx = ctx,
                    .gpu = gpu,
                    .options = options,
                    .graphics = presetGraphics(options.preset),
                    .graph = try sw_render.FrameGraph.init(allocator, gpu, .{}),
                    .post = undefined,
                    .overlay = undefined,
                };
                host.post = try sw_render.PostChain.init(allocator, &host.graph, .{});
                host.overlay = try Overlay.init(allocator, gpu);
                try App.init(&host);
                try host.graph.addPass(.{
                    .name = "demo_overlay",
                    .order = 2000,
                    .attachments = .{ .colors = &.{.{ .target = .screen, .load_op = .load }} },
                    .callback = .plain(drawOverlay),
                });
                if (!is_wasm) {
                    if (options.capture_dir) |dir| try openCapture(ctx.io.?, dir, gpu);
                }
                ready = true;
                std.log.info("{s}: ready. preset {s}, script of {d} ticks", .{ App.name, @tagName(options.preset), parsed.lastTick() });
            }

            pub fn tick(ctx: *sw.Context) !void {
                _ = ctx;
                if (!ready or ending) return;
                const t = host.script_tick;
                while (player.next(t)) |e| {
                    switch (e.command) {
                        .caption => |text| host.caption = text,
                        .set => |s| App.set(&host, s.name, s.value) catch |err| {
                            fail("{s}: script line {d}: set {s} {s}: {s}", .{ App.name, e.line, s.name, s.value, @errorName(err) });
                        },
                        .checkpoint => |n| pending_checkpoint = n,
                        .end => ending = true,
                    }
                }
                if (player.finished() and t >= parsed.lastTick()) ending = true;
                try App.tick(&host);
                host.script_tick += 1;
                if (ending and !host.deterministic()) {
                    // Interactive: play the script again.
                    ending = false;
                    player.restart();
                    host.script_tick = 0;
                    if (@hasDecl(App, "reset")) try App.reset(&host);
                }
            }

            pub fn render(ctx: *sw.Context) !void {
                if (!ready) return;
                const gpu = ctx.gpu();
                const w = gpu.getSurfaceWidth();
                const h = gpu.getSurfaceHeight();
                const f = try App.frame(&host, w, h);
                setStats(w, h);
                if (try host.graph.execute(f)) {
                    if (!is_wasm) try afterFrame(ctx);
                    gpu.present();
                }
                pending_checkpoint = null;
                if (!is_wasm and ending and host.deterministic()) finish(ctx);
                measure(ctx);
            }

            pub fn shutdown(ctx: *sw.Context) !void {
                if (!ready) return;
                App.deinit(&host);
                host.overlay.deinit();
                host.post.deinit();
                host.graph.deinit();
                parsed.deinit(ctx.allocator());
                records.deinit(ctx.allocator());
                ready = false;
            }
        };

        fn drawOverlay(pass: *sw_render.Pass) !void {
            const o = &host.overlay;
            o.caption = host.caption;
            o.chart = if (host.deterministic()) null else &frame_times;
            try o.draw(pass.width, pass.height);
            if (@hasDecl(App, "drawOverlay")) try App.drawOverlay(&host, o);
            try o.renderer.flush(pass.render.?);
        }

        fn setStats(w: u32, h: u32) void {
            var lines: [overlay.max_stat_lines][]const u8 = undefined;
            var n: usize = 0;
            lines[n] = std.fmt.bufPrint(&line_bufs[n], "{s}  |  preset {s}  |  {d}x{d}", .{ App.name, @tagName(host.options.preset), w, h }) catch "";
            n += 1;
            const step_ms = 1000.0 / @as(f32, @floatFromInt(tick_hz));
            lines[n] = if (host.deterministic())
                std.fmt.bufPrint(&line_bufs[n], "frame time: fixed step {d:.1} ms (recording)", .{step_ms}) catch ""
            else
                std.fmt.bufPrint(&line_bufs[n], "frame time: {d:.1} ms (avg {d:.1} ms)", .{ frame_times.latest() orelse 0, frame_times.average() }) catch "";
            n += 1;
            if (@hasDecl(App, "statLines")) n += App.statLines(&host, line_bufs[n..], lines[n..]);
            host.overlay.setStats(lines[0..n]);
        }

        /// Keep the wall-clock frame time for the overlay. Capture and
        /// check runs do not use it.
        fn measure(ctx: *sw.Context) void {
            if (host.deterministic()) return;
            const now = ctx.timeNs();
            if (last_frame_ns) |last| frame_times.push(@as(f32, @floatFromInt(now -| last)) / std.time.ns_per_ms);
            last_frame_ns = now;
        }

        fn openCapture(io: std.Io, dir_path: []const u8, gpu: *sw_gpu.GPU) !void {
            var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
            defer dir.close(io);
            var buf: [64]u8 = undefined;
            const info = try std.fmt.bufPrint(&buf, "{d} {d} {d}\n", .{ gpu.getSurfaceWidth(), gpu.getSurfaceHeight(), tick_hz });
            const f = try dir.createFile(io, "info.txt", .{ .truncate = true });
            try f.writeStreamingAll(io, info);
            f.close(io);
            // frames.bgra can be a named pipe: the open waits for the reader.
            capture_file = try dir.createFile(io, "frames.bgra", .{ .truncate = true });
        }

        fn afterFrame(ctx: *sw.Context) !void {
            if (capture_file == null and pending_checkpoint == null) return;
            const allocator = ctx.allocator();
            const pixels = try ctx.gpu().captureFrame(allocator);
            defer allocator.free(pixels);
            if (capture_file) |f| {
                try f.writeStreamingAll(ctx.io.?, pixels);
                captured += 1;
            }
            if (pending_checkpoint) |name| {
                if (options.check) {
                    const hash = hashes.frameHash(pixels);
                    try records.append(allocator, .{ .name = name, .hash = hash });
                    std.log.info("{s}: checkpoint {s} {x:0>16}", .{ App.name, name, hash });
                }
            }
        }

        fn hashPath(buf: []u8) []const u8 {
            if (options.hashes_path) |p| return p;
            return std.fmt.bufPrint(buf, "demos/{s}/hashes/lavapipe-{s}.txt", .{ App.name, @tagName(options.preset) }) catch unreachable;
        }

        /// The end of a capture or check run.
        fn finish(ctx: *sw.Context) void {
            const io = ctx.io.?;
            if (capture_file) |f| {
                f.close(io);
                std.log.info("{s}: captured {d} frames", .{ App.name, captured });
            }
            if (!options.check) std.process.exit(0);
            std.process.exit(checkHashes(ctx.allocator(), io) catch |err| blk: {
                std.log.err("{s}: hash check failed: {s}", .{ App.name, @errorName(err) });
                break :blk 2;
            });
        }

        fn checkHashes(allocator: std.mem.Allocator, io: std.Io) !u8 {
            var path_buf: [256]u8 = undefined;
            const path = hashPath(&path_buf);
            var out_buf: [16 * 1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&out_buf);
            try w.print("# {s}: frame hashes at the checkpoints of the script, preset {s}, lavapipe (REQ-DEMO-003)\n", .{ App.name, @tagName(options.preset) });
            try hashes.format(records.items, &w);
            const text = w.buffered();
            if (options.update) {
                if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
                const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
                defer f.close(io);
                try f.writeStreamingAll(io, text);
                std.log.info("{s}: wrote {d} hashes to {s}", .{ App.name, records.items.len, path });
                return 0;
            }
            const want_text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| {
                std.log.err("{s}: cannot read {s} ({s}). Run with --check --update to make it.", .{ App.name, path, @errorName(err) });
                return 2;
            };
            defer allocator.free(want_text);
            const want = try hashes.parse(allocator, want_text);
            defer allocator.free(want);
            var mismatches: [64]hashes.Mismatch = undefined;
            const n = hashes.compare(want, records.items, &mismatches);
            if (n == 0) {
                std.log.info("{s}: {d} checkpoint hashes match {s}", .{ App.name, records.items.len, path });
                return 0;
            }
            for (mismatches[0..@min(n, mismatches.len)]) |m| {
                std.log.err("{s}: checkpoint {s}: want {s}, got {s}", .{ App.name, m.name, hexOr(m.want, 0), hexOr(m.got, 1) });
            }
            // Keep the new hashes, so a deliberate change is easy to accept.
            var got_buf: [256]u8 = undefined;
            const got_path = try std.fmt.bufPrint(&got_buf, "zig-out/demo-hashes/{s}-lavapipe-{s}.txt", .{ App.name, @tagName(options.preset) });
            try std.Io.Dir.cwd().createDirPath(io, "zig-out/demo-hashes");
            const f = try std.Io.Dir.cwd().createFile(io, got_path, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, text);
            std.log.err("{s}: {d} checkpoint hashes differ from {s}. The new hashes are in {s}.", .{ App.name, n, path, got_path });
            std.log.err("If the change is deliberate, accept it: cp {s} {s}  (or: scripts/demos-check.sh --update)", .{ got_path, path });
            return 1;
        }

        var hex_bufs: [2][16]u8 = undefined;
        fn hexOr(v: ?u64, slot: usize) []const u8 {
            const x = v orelse return "(none)";
            return std.fmt.bufPrint(&hex_bufs[slot], "{x:0>16}", .{x}) catch "?";
        }
    };
}

test {
    _ = cli;
    _ = script;
    _ = hashes;
    _ = reflect;
    _ = voxel_mesh;
    _ = cow_model;
}
