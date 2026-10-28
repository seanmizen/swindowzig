//! `LightShafts`: rays of sunlight through the gaps in the clouds and the
//! scene, as an HDR effect of a `PostChain` (REQ-GPU-033).
//! `shafts_plan.zig` has the technique and the CPU reference.
//!
//! ```zig
//! const depth = try graph.addTarget(.{ .name = "depth", .format = .depth24plus, .usage = .{ .render_attachment = true, .texture_binding = true } });
//! var shafts = try render.LightShafts.init(&post, depth, .{ .strength = 0.5 });
//! defer shafts.deinit();
//! try shafts.setEnabled(false); // the off switch
//! ```
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const post_mod = @import("post.zig");
const plan = @import("shafts_plan.zig");

const TargetId = @import("plan.zig").TargetId;

pub const ShaftSettings = plan.ShaftSettings;

pub const LightShafts = struct {
    post: *post_mod.PostChain,
    effect: post_mod.EffectId,
    settings: ShaftSettings,
    buffer: gpu_mod.Buffer,
    group: gpu_mod.BindGroup,

    /// Add the effect to `post`. `depth` is the depth target of the scene,
    /// with `texture_binding` usage. The chain must stay at its address
    /// while the shafts exist. The pass is `sw_light_shafts`.
    pub fn init(post: *post_mod.PostChain, depth: TargetId, settings: ShaftSettings) !LightShafts {
        const gpu = post.graph.gpu;
        var buffer = try gpu.createBuffer(.{
            .label = "sw_light_shafts",
            .size = @sizeOf(plan.ShaftUniforms),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        errdefer buffer.destroy();
        var layout = try gpu.createBindGroupLayout(.{
            .label = "sw_light_shafts",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .buffer = .{ .type = .uniform, .min_binding_size = @sizeOf(plan.ShaftUniforms) },
            }},
        });
        const group = try gpu.createBindGroup(.{
            .layout = &layout,
            .entries = &[_]gpu_mod.BindGroupEntry{.{ .binding = 0, .buffer = &buffer, .size = @sizeOf(plan.ShaftUniforms) }},
        });
        errdefer group.release();
        const effect = try post.addEffect(.{
            .name = "sw_light_shafts",
            .kind = .hdr,
            .code = plan.shader,
            .depth = depth,
            .params = .{ .layout = &layout, .bind_group = group },
        });
        var self: LightShafts = .{ .post = post, .effect = effect, .settings = settings, .buffer = buffer, .group = group };
        self.setSettings(settings);
        return self;
    }

    /// Release the buffer. Call it before `PostChain.deinit`. The chain
    /// keeps the effect, but it does not run.
    pub fn deinit(self: *LightShafts) void {
        self.post.setEffectEnabled(self.effect, false) catch {};
        self.group.release();
        self.buffer.destroy();
        self.* = undefined;
    }

    /// Change the settings. The next frame uses them.
    pub fn setSettings(self: *LightShafts, settings: ShaftSettings) void {
        self.settings = settings;
        const u = plan.ShaftUniforms.of(settings);
        self.post.graph.gpu.writeBuffer(self.buffer, 0, std.mem.asBytes(&u));
    }

    /// Run the effect (true) or skip it (false).
    pub fn setEnabled(self: *LightShafts, enabled: bool) !void {
        try self.post.setEffectEnabled(self.effect, enabled);
    }
};
