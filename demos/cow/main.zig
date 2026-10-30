// cow - a voxel cow turns on a stand, and the script changes one setting
// at a time (REQ-DEMO-005).
//
// The caption at the bottom names each setting. The overlay at the top
// left shows the frame time, the quad count of the meshes and the current
// settings. The scene is `demo.CowScene` (demos/common/cow_scene.zig).
//
//   zig build run -Ddemo=cow                        # window, the script loops
//   zig build run -Ddemo=cow -- --preset high
//   ./zig-out/bin/cow --check                       # compare the frame hashes
//   ./zig-out/bin/cow --capture out/cow-medium      # write each frame
//   zig build web -Ddemo=cow && yarn dev:demo cow   # browser
const std = @import("std");
const demo = @import("demo_common");
const sw_render = @import("sw_render");

const D = demo.Demo(App);
pub const std_options = demo.std_options;
pub const main = D.main;

comptime {
    D.exportWeb();
}

const App = struct {
    pub const name = "cow";
    pub const script = @embedFile("cow.tas");

    var scene: demo.CowScene = undefined;

    pub fn init(host: *demo.Host) !void {
        const g = host.graphics;
        scene = try demo.CowScene.init(host.allocator, &host.graph, &host.post, .{
            .fxaa_quality = g.fxaa_quality,
            .shadow_map_size = g.shadow_map_size,
            .shadow_cascades = @max(g.shadow_cascades, 1),
        });
    }

    pub fn reset(_: *demo.Host) !void {
        try scene.apply(.{});
        scene.setAngle(0);
    }

    pub fn set(_: *demo.Host, setting: []const u8, value: []const u8) !void {
        try scene.set(setting, value);
    }

    pub fn tick(host: *demo.Host) !void {
        scene.tick(host.dt);
    }

    pub fn frame(_: *demo.Host, w: u32, h: u32) !sw_render.FrameUniforms {
        return scene.frame(w, h);
    }

    pub fn statLines(_: *demo.Host, bufs: [][128]u8, out: [][]const u8) usize {
        const s = scene.settings();
        const st = scene.stats();
        out[0] = std.fmt.bufPrint(&bufs[0], "quads: {d}  ({s} meshing, AO {s})", .{ st.quads, @tagName(s.meshing), if (s.ao) "on" else "off" }) catch "";
        out[1] = std.fmt.bufPrint(&bufs[1], "AA {s} | {s} x{d:.1} | shadows {s}", .{ @tagName(s.aa), @tagName(s.tonemap), s.exposure, if (s.shadows) "on" else "off" }) catch "";
        return 2;
    }

    pub fn deinit(_: *demo.Host) void {
        scene.deinit();
    }
};
