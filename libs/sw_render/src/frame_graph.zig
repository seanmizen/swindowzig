//! A frame graph: named render targets and passes in a set order
//! (REQ-GPU-005).
//!
//! The game adds its targets and passes one time. Each frame,
//! `FrameGraph.execute`:
//!
//! 1. Makes each target again when its size changes. A target with a
//!    `.surface` size follows the window. `generation` then increases, so a
//!    pass can make its bind groups again.
//! 2. Writes the frame uniforms (`wgsl.FrameUniforms`) for the shared WGSL
//!    prefix (REQ-GPU-007).
//! 3. Runs the passes by `order`. The graph begins the render pass with the
//!    attachments of the pass, and calls the pass callback.
//! 4. Sends the staged uploads and the uniform ring (REQ-GPU-006), then
//!    submits one command buffer.
//!
//! The game calls `gpu.present()` after `execute`. Between the two calls,
//! `gpu.captureFrame` can read the frame.
//!
//! ```zig
//! var graph = try render.FrameGraph.init(allocator, gpu, .{});
//! const depth = try graph.addTarget(.{ .name = "depth", .format = .depth24plus });
//! try graph.addPass(.{
//!     .name = "opaque",
//!     .attachments = .{ .colors = &.{.{ .target = .screen }}, .depth = .{ .target = depth } },
//!     .callback = .of(Game, &game, Game.drawOpaque),
//! });
//! // Each frame:
//! if (try graph.execute(.{ .view_proj = vp })) gpu.present();
//! ```

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const plan = @import("plan.zig");
const ring_mod = @import("ring.zig");
const upload_mod = @import("upload.zig");
const wgsl = @import("wgsl.zig");

const TargetId = plan.TargetId;
const Extent = plan.Extent;

pub const Options = struct {
    /// The format of the window surface. It must match the format of the
    /// pipelines that draw to `.screen`.
    screen_format: gpu_mod.TextureFormat = .bgra8unorm,
    /// The size of the uniform ring, in bytes. Each `push` uses 256 bytes
    /// at minimum.
    ring_capacity: u32 = 64 * 1024,
};

/// The type-erased function of a pass.
pub const Callback = struct {
    user: ?*anyopaque,
    run: *const fn (user: ?*anyopaque, pass: *Pass) anyerror!void,

    /// A callback that calls `f(user, pass)`.
    pub fn of(comptime T: type, user: *T, comptime f: fn (*T, *Pass) anyerror!void) Callback {
        return .{ .user = user, .run = struct {
            fn run(u: ?*anyopaque, pass: *Pass) anyerror!void {
                return f(@ptrCast(@alignCast(u.?)), pass);
            }
        }.run };
    }

    /// A callback that calls `f(pass)`.
    pub fn plain(comptime f: fn (*Pass) anyerror!void) Callback {
        return .{ .user = null, .run = struct {
            fn run(_: ?*anyopaque, pass: *Pass) anyerror!void {
                return f(pass);
            }
        }.run };
    }
};

pub const PassDesc = struct {
    /// The string must stay valid while the graph exists (use a literal).
    name: []const u8,
    /// Passes run from low `order` to high. Passes with the same order run
    /// in the sequence that the game added them.
    order: i32 = 0,
    attachments: plan.Attachments = .{},
    callback: Callback,
};

/// What a pass callback gets.
pub const Pass = struct {
    graph: *FrameGraph,
    gpu: *gpu_mod.GPU,
    encoder: gpu_mod.CommandEncoder,
    /// The render pass. Null for a pass with no attachments.
    render: ?gpu_mod.RenderPassEncoder,
    /// The size of the attachments, in pixels. The surface size for a pass
    /// with no attachments.
    width: u32,
    height: u32,

    /// Set the frame uniforms (`sw_frame` in the WGSL prefix) at group 0.
    pub fn bindFrame(self: *Pass) void {
        self.render.?.setBindGroup(wgsl.frame_group, self.graph.frame_bind_group);
    }

    /// Push one value into the uniform ring. Give its dynamic offset.
    pub fn push(self: *Pass, value: anytype) !u32 {
        return self.graph.ring.push(value);
    }

    /// The view of a target, to sample in this pass.
    pub fn view(self: *Pass, id: TargetId) *gpu_mod.TextureView {
        return self.graph.view(id);
    }
};

const Target = struct {
    desc: plan.TargetDesc,
    texture: ?gpu_mod.Texture = null,
    view: ?gpu_mod.TextureView = null,
    size: Extent = .{ .width = 0, .height = 0 },
};

const PassEntry = struct {
    desc: PassDesc,
    colors: [plan.max_colors]plan.ColorAttachment,
    enabled: bool = true,
};

/// The handle of one pass, from `FrameGraph.findPass`.
pub const PassId = enum(u8) {
    _,

    pub fn index(self: PassId) usize {
        return @backingInt(self);
    }
};

pub const FrameGraph = struct {
    gpu: *gpu_mod.GPU,
    options: Options,
    targets: [plan.max_targets]Target = undefined,
    target_count: usize = 0,
    passes: [plan.max_passes]PassEntry = undefined,
    pass_count: usize = 0,
    /// The surface size of the last `execute`.
    surface: Extent = .{ .width = 0, .height = 0 },
    /// Increases each time a target texture changes. A pass that keeps a
    /// bind group with a target view makes it again when this changes.
    generation: u32 = 0,
    frame_count: u32 = 0,
    /// The layout of group 0 (the frame uniforms). Put it first in the
    /// pipeline layout of each pipeline that uses the WGSL prefix.
    frame_layout: gpu_mod.BindGroupLayout,
    frame_bind_group: gpu_mod.BindGroup,
    frame_buffer: gpu_mod.Buffer,
    /// The per-draw uniforms (REQ-GPU-006).
    ring: ring_mod.UniformRing,
    /// The staged buffer writes of this frame (REQ-GPU-006).
    uploads: upload_mod.Uploads,
    /// The surface view while `execute` runs.
    screen_view: ?gpu_mod.TextureView = null,
    /// The game added a target or a pass after the last check of the passes.
    unchecked: bool = true,

    pub fn init(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, options: Options) !FrameGraph {
        var frame_buffer = try gpu.createBuffer(.{
            .label = "sw_render frame uniforms",
            .size = @sizeOf(wgsl.FrameUniforms),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        errdefer frame_buffer.destroy();
        var frame_layout = try gpu.createBindGroupLayout(.{
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{.{
                .binding = wgsl.frame_binding,
                .visibility = .{ .vertex = true, .fragment = true },
                .buffer = .{ .type = .uniform, .min_binding_size = @sizeOf(wgsl.FrameUniforms) },
            }},
        });
        const frame_bind_group = try gpu.createBindGroup(.{
            .layout = &frame_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{.{
                .binding = wgsl.frame_binding,
                .buffer = &frame_buffer,
                .size = @sizeOf(wgsl.FrameUniforms),
            }},
        });
        errdefer frame_bind_group.release();
        const ring = try ring_mod.UniformRing.init(allocator, gpu, options.ring_capacity);
        return .{
            .gpu = gpu,
            .options = options,
            .frame_layout = frame_layout,
            .frame_bind_group = frame_bind_group,
            .frame_buffer = frame_buffer,
            .ring = ring,
            .uploads = .init(allocator),
        };
    }

    pub fn deinit(self: *FrameGraph) void {
        for (self.targets[0..self.target_count]) |*t| releaseTarget(t);
        self.frame_bind_group.release();
        self.frame_buffer.destroy();
        self.ring.deinit();
        self.uploads.deinit();
        self.* = undefined;
    }

    /// Add a render target. The graph makes its texture at the next
    /// `execute`.
    pub fn addTarget(self: *FrameGraph, desc: plan.TargetDesc) plan.Error!TargetId {
        if (self.target_count == plan.max_targets) return error.TooManyTargets;
        if (self.findTarget(desc.name) != null) return error.DuplicateTargetName;
        self.targets[self.target_count] = .{ .desc = desc };
        self.target_count += 1;
        self.unchecked = true;
        return TargetId.fromIndex(self.target_count - 1);
    }

    /// Add a pass. The graph copies the attachment list.
    pub fn addPass(self: *FrameGraph, desc: PassDesc) plan.Error!void {
        if (self.pass_count == plan.max_passes) return error.TooManyPasses;
        if (desc.attachments.colors.len > plan.max_colors) return error.TooManyColors;
        var entry: PassEntry = .{ .desc = desc, .colors = undefined };
        @memcpy(entry.colors[0..desc.attachments.colors.len], desc.attachments.colors);
        self.passes[self.pass_count] = entry;
        self.pass_count += 1;
        self.unchecked = true;
    }

    /// The first pass with the name `name`.
    pub fn findPass(self: *const FrameGraph, name: []const u8) ?PassId {
        for (self.passes[0..self.pass_count], 0..) |p, i| {
            if (std.mem.eql(u8, p.desc.name, name)) return @fromBackingInt(@as(u8, @intCast(i)));
        }
        return null;
    }

    /// Run the pass in each frame (true), or skip it (false). A new pass
    /// runs. A skipped pass does not get the surface view.
    pub fn setPassEnabled(self: *FrameGraph, id: PassId, enabled: bool) void {
        self.passes[id.index()].enabled = enabled;
    }

    pub fn isPassEnabled(self: *const FrameGraph, id: PassId) bool {
        return self.passes[id.index()].enabled;
    }

    /// Give a pass new attachments. The graph copies the list, and checks
    /// it at the next `execute`.
    pub fn setPassAttachments(self: *FrameGraph, id: PassId, attachments: plan.Attachments) plan.Error!void {
        if (attachments.colors.len > plan.max_colors) return error.TooManyColors;
        const p = &self.passes[id.index()];
        p.desc.attachments = attachments;
        @memcpy(p.colors[0..attachments.colors.len], attachments.colors);
        self.unchecked = true;
    }

    pub fn findTarget(self: *const FrameGraph, name: []const u8) ?TargetId {
        for (self.targets[0..self.target_count], 0..) |t, i| {
            if (std.mem.eql(u8, t.desc.name, name)) return TargetId.fromIndex(i);
        }
        return null;
    }

    /// The view of a target. `.screen` has a view only while `execute`
    /// runs. A target has a view after the first `execute`.
    pub fn view(self: *FrameGraph, id: TargetId) *gpu_mod.TextureView {
        if (id == .screen) return &self.screen_view.?;
        return &self.targets[id.index()].view.?;
    }

    /// The texture of a target, after the first `execute`.
    pub fn texture(self: *const FrameGraph, id: TargetId) gpu_mod.Texture {
        return self.targets[id.index()].texture.?;
    }

    /// The size of a target in pixels, after the first `execute`.
    pub fn size(self: *const FrameGraph, id: TargetId) Extent {
        if (id == .screen) return self.surface;
        return self.targets[id.index()].size;
    }

    /// Record and submit one frame. `frame` gives the camera and the time.
    /// The graph sets `viewport` and `frame`. Give false, and do nothing,
    /// when the surface has no pixels (a minimised window). After true,
    /// call `gpu.present()`.
    pub fn execute(self: *FrameGraph, frame: wgsl.FrameUniforms) !bool {
        const gpu = self.gpu;
        const surface: Extent = .{ .width = gpu.getSurfaceWidth(), .height = gpu.getSurfaceHeight() };
        if (surface.width == 0 or surface.height == 0) return false;
        try self.prepareTargets(surface);

        var uniforms = frame;
        const w: f32 = @floatFromInt(surface.width);
        const h: f32 = @floatFromInt(surface.height);
        uniforms.viewport = .{ w, h, 1.0 / w, 1.0 / h };
        uniforms.frame = self.frame_count;
        try self.uploads.writeValue(self.frame_buffer, 0, uniforms);
        self.ring.reset();

        var uses_screen = false;
        for (self.passes[0..self.pass_count]) |*p| {
            if (p.enabled and plan.usesScreen(attachmentsOf(p))) uses_screen = true;
        }
        // A new surface view in each frame. The view is released after the
        // submit, and the graph does not keep it (REQ-GPU-012).
        if (uses_screen) self.screen_view = try gpu.getCurrentTextureView();
        defer if (self.screen_view) |v| {
            v.release();
            self.screen_view = null;
        };

        var orders: [plan.max_passes]i32 = undefined;
        for (self.passes[0..self.pass_count], 0..) |p, i| orders[i] = p.desc.order;
        var sequence: [plan.max_passes]u8 = undefined;
        plan.sortPasses(orders[0..self.pass_count], sequence[0..self.pass_count]);

        const encoder = try gpu.createCommandEncoder();
        for (sequence[0..self.pass_count]) |i| {
            if (!self.passes[i].enabled) continue;
            try self.runPass(encoder, &self.passes[i]);
        }

        self.uploads.flush(gpu);
        self.ring.flush(gpu);
        const commands = try encoder.finish();
        gpu.submit(&[_]gpu_mod.CommandBuffer{commands});
        self.frame_count +%= 1;
        return true;
    }

    fn attachmentsOf(p: *const PassEntry) plan.Attachments {
        return .{ .colors = p.colors[0..p.desc.attachments.colors.len], .depth = p.desc.attachments.depth };
    }

    fn runPass(self: *FrameGraph, encoder: gpu_mod.CommandEncoder, p: *const PassEntry) !void {
        const att = attachmentsOf(p);
        var pass: Pass = .{
            .graph = self,
            .gpu = self.gpu,
            .encoder = encoder,
            .render = null,
            .width = self.surface.width,
            .height = self.surface.height,
        };

        if (att.colors.len > 0 or att.depth != null) {
            var colors: [plan.max_colors]gpu_mod.RenderPassColorAttachment = undefined;
            for (att.colors, 0..) |c, i| {
                colors[i] = .{
                    .view = self.view(c.target),
                    .resolve_target = if (c.resolve) |r| self.view(r) else null,
                    .load_op = c.load_op,
                    .store_op = c.store_op,
                    .clear_value = c.clear_value,
                };
            }
            var depth: ?gpu_mod.RenderPassDepthStencilAttachment = null;
            if (att.depth) |d| {
                const stencil = plan.hasStencil(self.targets[d.target.index()].desc.format);
                depth = .{
                    .view = self.view(d.target),
                    .depth_load_op = d.load_op,
                    .depth_store_op = d.store_op,
                    .depth_clear_value = d.clear_value,
                    .depth_read_only = d.read_only,
                    .stencil_load_op = .clear,
                    .stencil_store_op = .store,
                    // A depth-only format takes no stencil ops.
                    .stencil_read_only = !stencil,
                };
            }
            const first = if (att.colors.len > 0) att.colors[0].target else att.depth.?.target;
            const extent = self.size(first);
            pass.width = extent.width;
            pass.height = extent.height;
            // No label: the native path reads a label as a C string, and a
            // pass name has no zero byte at its end.
            pass.render = try encoder.beginRenderPass(.{
                .color_attachments = colors[0..att.colors.len],
                .depth_stencil_attachment = depth,
            });
        }

        const result = p.desc.callback.run(p.desc.callback.user, &pass);
        if (pass.render) |r| r.end();
        return result;
    }

    /// Make each target whose size changed, then check every pass.
    fn prepareTargets(self: *FrameGraph, surface: Extent) !void {
        var changed = false;
        for (self.targets[0..self.target_count]) |*t| {
            const want = plan.resolveSize(t.desc.size, surface);
            if (t.texture != null and t.size.eql(want)) continue;
            releaseTarget(t);
            const tex = try self.gpu.createTexture(.{
                .label = t.desc.name,
                .size = .{ .width = want.width, .height = want.height, .depth_or_array_layers = 1 },
                .sample_count = t.desc.sample_count,
                .format = t.desc.format,
                .usage = t.desc.usage,
            });
            t.texture = tex;
            t.view = try tex.createView(.{});
            t.size = want;
            changed = true;
        }
        const surface_changed = !surface.eql(self.surface);
        self.surface = surface;
        if (changed) self.generation +%= 1;
        if (!changed and !surface_changed and !self.unchecked) return;
        self.unchecked = false;

        var infos: [plan.max_targets]plan.TargetInfo = undefined;
        for (self.targets[0..self.target_count], 0..) |t, i| {
            infos[i] = .{ .format = t.desc.format, .size = t.size, .sample_count = t.desc.sample_count };
        }
        const screen: plan.TargetInfo = .{ .format = self.options.screen_format, .size = surface, .sample_count = 1 };
        for (self.passes[0..self.pass_count]) |*p| {
            plan.checkPass(attachmentsOf(p), infos[0..self.target_count], screen) catch |err| {
                std.log.err("sw_render: pass '{s}' has bad attachments: {s}", .{ p.desc.name, @errorName(err) });
                return err;
            };
        }
    }

    fn releaseTarget(t: *Target) void {
        if (t.view) |v| v.release();
        if (t.texture) |tex| tex.destroy();
        t.view = null;
        t.texture = null;
    }
};
