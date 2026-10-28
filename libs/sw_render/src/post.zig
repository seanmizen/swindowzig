//! The HDR target and the post-process chain of a frame graph
//! (REQ-GPU-008, REQ-GPU-009).
//!
//! The game draws the scene into `PostChain.hdr`, an `rgba16float` target
//! with linear colour. The chain then runs its links as frame graph
//! passes, in this sequence:
//!
//! 1. The `.hdr` effects of the game, on linear HDR colour.
//! 2. The tonemap: exposure, a curve (`Tonemap`), and the sRGB encode.
//!    It writes display colour.
//! 3. The `.ldr` effects of the game, on display colour.
//! 4. FXAA (`gpu_mod.fxaa`), when it is on.
//!
//! The last enabled link writes the screen. Each link reads the output of
//! the enabled link before it. The chain changes the route when a link
//! goes on or off. The chain passes use the orders `Options.order` to
//! `Options.order + order_span - 1`. Use a lower order for the scene
//! passes, and a higher order for a pass that draws on the finished screen
//! (a HUD, with `load_op = .load`).
//!
//! ```zig
//! var graph = try render.FrameGraph.init(allocator, gpu, .{});
//! var post = try render.PostChain.init(allocator, &graph, .{ .fxaa = .medium });
//! defer post.deinit();
//! const depth = try graph.addTarget(.{ .name = "depth", .format = .depth24plus });
//! try graph.addPass(.{
//!     .name = "scene",
//!     .attachments = .{ .colors = &.{.{ .target = post.hdr }}, .depth = .{ .target = depth } },
//!     .callback = .of(Game, &game, Game.drawScene),
//! });
//! // The scene pipelines use `post.hdr_format` as the colour format.
//! // Each frame:
//! if (try graph.execute(frame)) gpu.present();
//! ```
//!
//! An effect is a fragment shader from `render.post.shader(body)`. Group 0
//! has the frame uniforms, group 1 the input image (`sw_input`,
//! `sw_input_sampler`), and group 2 the own bind group of the effect.
//!
//! An effect with `EffectDesc.depth` also reads a depth target, as
//! `sw_depth` in group 1 (REQ-GPU-030). Its shader comes from
//! `render.post.depthShader(body)`. The chain binds the depth view again
//! when the target changes, for example after a resize. `addDepthFog`
//! adds the fog of the sky as such an effect:
//!
//! ```zig
//! const depth = try graph.addTarget(.{ .name = "depth", .format = .depth24plus, .usage = .{ .render_attachment = true, .texture_binding = true } });
//! _ = try post.addDepthFog(depth);
//! ```

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const frame_graph = @import("frame_graph.zig");
const plan = @import("plan.zig");
const post_plan = @import("post_plan.zig");

const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = plan.TargetId;

pub const Kind = post_plan.Kind;
pub const Curve = post_plan.Curve;
pub const Tonemap = post_plan.Tonemap;
pub const FxaaQuality = gpu_mod.FxaaQuality;

/// The number of frame graph orders that the chain uses.
pub const order_span: i32 = 4;

pub const Options = struct {
    /// The order of the first chain pass. See `order_span`.
    order: i32 = 1000,
    /// The format of `PostChain.hdr` and of the images between the HDR
    /// effects.
    hdr_format: gpu_mod.TextureFormat = .rgba16float,
    tonemap: Tonemap = .{},
    /// FXAA on the display colour, as the last link. Null: no FXAA.
    fxaa: ?FxaaQuality = null,
};

/// The own bind group of an effect, at group 2.
pub const Params = struct {
    layout: *gpu_mod.BindGroupLayout,
    bind_group: gpu_mod.BindGroup,
};

pub const EffectDesc = struct {
    /// The name of the frame graph pass. It must be unique in the graph.
    /// The string must stay valid while the graph exists (use a literal).
    name: []const u8,
    /// `.hdr` runs before the tonemap. `.ldr` runs after the tonemap and
    /// before FXAA. Effects of one kind run in the sequence that the game
    /// added them.
    kind: enum { hdr, ldr },
    /// The source from `post.shader(body)`.
    code: []const u8,
    fragment_entry: []const u8 = "fs_main",
    params: ?Params = null,
    enabled: bool = true,
    /// A depth target that the effect reads as `sw_depth` (REQ-GPU-030).
    /// It needs `texture_binding` usage. Null: no depth.
    depth: ?TargetId = null,
};

/// The handle of one effect. It does not change when the game adds more
/// effects.
pub const EffectId = enum(u8) {
    _,

    /// The pass of the effect in the frame graph. Do not enable or disable
    /// it there: use `PostChain.setEffectEnabled`.
    pub fn pass(self: EffectId) PassId {
        return @fromBackingInt(@backingInt(self));
    }
};

pub const Error = error{
    DuplicateEffectName,
    TooManyEffects,
    /// The depth target of an effect has no `texture_binding` usage.
    DepthNotSampled,
};

/// The most links in one chain: the effects, the tonemap and FXAA.
pub const max_links = 16;

/// One link of the chain. It has a stable address: the frame graph keeps
/// a pointer to it in the pass callback.
const Link = struct {
    kind: Kind,
    /// The order of the pass after `Options.order`: 0 for the HDR effects,
    /// 1 for the tonemap, 2 for the LDR effects and 3 for FXAA. The links
    /// run by rank, then in the add sequence.
    rank: i32,
    enabled: bool,
    pass: PassId,
    pipeline: ?gpu_mod.RenderPipeline,
    params: ?gpu_mod.BindGroup,
    input: TargetId = TargetId.fromIndex(0),
    input_layout: gpu_mod.BindGroupLayout,
    sampler: gpu_mod.Sampler,
    /// The input bind group, for `bound_input` at `bound_generation`.
    bound: ?gpu_mod.BindGroup = null,
    bound_generation: u32 = 0,
    bound_input: TargetId = TargetId.fromIndex(0),
    /// The depth target that the link reads, or null.
    depth: ?TargetId = null,

    fn run(self: *Link, pass: *Pass) anyerror!void {
        const rp = pass.render.?;
        const pipeline = self.pipeline orelse return;
        const graph = pass.graph;
        if (self.bound == null or self.bound_generation != graph.generation or self.bound_input != self.input) {
            if (self.bound) |b| b.release();
            self.bound = null;
            // The generation changes when a target view changes, so the
            // depth view is current too (REQ-GPU-030).
            var entries = [_]gpu_mod.BindGroupEntry{
                .{ .binding = 0, .texture_view = pass.view(self.input) },
                .{ .binding = 1, .sampler = &self.sampler },
                undefined,
            };
            var count: usize = 2;
            if (self.depth) |d| {
                entries[2] = .{ .binding = post_plan.depth_binding, .texture_view = pass.view(d) };
                count = 3;
            }
            self.bound = try pass.gpu.createBindGroup(.{
                .layout = &self.input_layout,
                .entries = entries[0..count],
            });
            self.bound_generation = graph.generation;
            self.bound_input = self.input;
        }
        rp.setPipeline(pipeline);
        pass.bindFrame();
        rp.setBindGroup(post_plan.input_group, self.bound.?);
        if (self.params) |p| rp.setBindGroup(post_plan.params_group, p);
        rp.draw(3, 1, 0, 0);
    }
};

pub const PostChain = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    options: Options,
    /// The scene target: `Options.hdr_format`, the size of the surface.
    /// The game draws the scene here with linear colour.
    hdr: TargetId,
    /// The colour format of `hdr`, for the scene pipelines.
    hdr_format: gpu_mod.TextureFormat,
    /// The links in run sequence.
    links: [max_links]*Link = undefined,
    link_count: usize = 0,
    /// The targets of `post_plan.Slot`, after the first route that uses
    /// them. `hdr_a` is `hdr`.
    slots: [4]?TargetId = @splat(null),
    sampler: gpu_mod.Sampler,
    input_layout: gpu_mod.BindGroupLayout,
    /// The input layout of an effect that reads a depth target.
    depth_input_layout: gpu_mod.BindGroupLayout,
    tonemap: Tonemap,
    tonemap_buffer: gpu_mod.Buffer,
    tonemap_group: ?gpu_mod.BindGroup = null,
    tonemap_link: *Link,
    fxaa_link: *Link,
    fxaa_quality: ?FxaaQuality = null,

    /// Add the HDR target and the chain passes to `graph`. The graph must
    /// stay at its address while the chain exists.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, options: Options) !PostChain {
        const gpu = graph.gpu;
        const hdr = try graph.addTarget(.{ .name = "sw_post_hdr", .format = options.hdr_format });
        const sampler = try gpu.createSampler(.{
            .label = "sw_post_sampler",
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });
        const input_layout = try gpu.createBindGroupLayout(.{
            .label = "sw_post_input",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .@"2d" } },
                .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .type = .filtering } },
            },
        });
        const depth_input_layout = try gpu.createBindGroupLayout(.{
            .label = "sw_post_depth_input",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .@"2d" } },
                .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .type = .filtering } },
                .{ .binding = post_plan.depth_binding, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .depth, .view_dimension = .@"2d" } },
            },
        });
        var tonemap_buffer = try gpu.createBuffer(.{
            .label = "sw_post_tonemap",
            .size = @sizeOf(post_plan.TonemapUniforms),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        errdefer tonemap_buffer.destroy();

        var self: PostChain = .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .hdr = hdr,
            .hdr_format = options.hdr_format,
            .sampler = sampler,
            .input_layout = input_layout,
            .depth_input_layout = depth_input_layout,
            .tonemap = options.tonemap,
            .tonemap_buffer = tonemap_buffer,
            .tonemap_link = undefined,
            .fxaa_link = undefined,
        };
        self.slots[@backingInt(post_plan.Slot.hdr_a)] = hdr;
        errdefer self.freeLinks();
        errdefer if (self.tonemap_group) |g| g.release();

        // The tonemap: group 2 holds its uniforms.
        var tonemap_layout = try gpu.createBindGroupLayout(.{
            .label = "sw_post_tonemap",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .buffer = .{ .type = .uniform, .min_binding_size = @sizeOf(post_plan.TonemapUniforms) },
            }},
        });
        self.tonemap_group = try gpu.createBindGroup(.{
            .layout = &tonemap_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{.{
                .binding = 0,
                .buffer = &self.tonemap_buffer,
                .size = @sizeOf(post_plan.TonemapUniforms),
            }},
        });
        self.setTonemap(options.tonemap);
        const tonemap_pipeline = try self.makePipeline(post_plan.tonemap_shader, "sw_post_vs", "fs_main", graph.options.screen_format, &self.input_layout, &tonemap_layout);
        self.tonemap_link = try self.addLink("sw_post_tonemap", .tonemap, 1, tonemap_pipeline, self.tonemap_group, true);

        // FXAA: `setFxaa` makes the pipeline when FXAA goes on.
        self.fxaa_link = try self.addLink("sw_post_fxaa", .ldr, 3, null, null, false);
        if (options.fxaa) |q| {
            try self.setFxaa(q);
        } else {
            try self.reroute();
        }
        return self;
    }

    /// Release the chain. Call it before `FrameGraph.deinit`. The graph
    /// keeps the chain targets and passes, but the passes do not run.
    pub fn deinit(self: *PostChain) void {
        self.freeLinks();
        if (self.tonemap_group) |g| g.release();
        self.tonemap_buffer.destroy();
        self.* = undefined;
    }

    fn freeLinks(self: *PostChain) void {
        for (self.links[0..self.link_count]) |l| {
            self.graph.setPassEnabled(l.pass, false);
            if (l.bound) |b| b.release();
            self.allocator.destroy(l);
        }
        self.link_count = 0;
    }

    /// Add an effect. The chain makes its pipeline now.
    pub fn addEffect(self: *PostChain, desc: EffectDesc) !EffectId {
        const kind: Kind = switch (desc.kind) {
            .hdr => .hdr,
            .ldr => .ldr,
        };
        if (desc.depth) |d| {
            if (!self.graph.targets[d.index()].desc.usage.texture_binding) return error.DepthNotSampled;
        }
        const format = if (kind == .hdr) self.hdr_format else self.graph.options.screen_format;
        const input_layout = if (desc.depth != null) &self.depth_input_layout else &self.input_layout;
        const pipeline = try self.makePipeline(desc.code, "sw_post_vs", desc.fragment_entry, format, input_layout, if (desc.params) |p| p.layout else null);
        const rank: i32 = if (kind == .hdr) 0 else 2;
        const link = try self.addLink(desc.name, kind, rank, pipeline, if (desc.params) |p| p.bind_group else null, desc.enabled);
        if (desc.depth) |d| {
            link.depth = d;
            link.input_layout = self.depth_input_layout;
        }
        try self.reroute();
        return @fromBackingInt(@backingInt(link.pass));
    }

    /// Add the fog of the sky as an HDR effect that reads `depth`
    /// (REQ-GPU-030). It gives the colour of `sw_fog` to each pixel with
    /// geometry, from the depth and `sw_frame`. Do not also call `sw_fog`
    /// in the scene shaders. The pass is `sw_post_fog`.
    pub fn addDepthFog(self: *PostChain, depth: TargetId) !EffectId {
        return self.addEffect(.{ .name = "sw_post_fog", .kind = .hdr, .code = post_plan.depth_fog_shader, .depth = depth });
    }

    /// Run an effect (true) or skip it (false).
    pub fn setEffectEnabled(self: *PostChain, id: EffectId, enabled: bool) !void {
        self.find(id.pass()).enabled = enabled;
        try self.reroute();
    }

    /// Give an effect a new own bind group (group 2), for example after
    /// a texture of the effect changed. The layout must not change.
    pub fn setEffectParams(self: *PostChain, id: EffectId, bind_group: gpu_mod.BindGroup) void {
        self.find(id.pass()).params = bind_group;
    }

    /// Change the tonemap settings. The next frame uses them.
    pub fn setTonemap(self: *PostChain, t: Tonemap) void {
        self.tonemap = t;
        const u = post_plan.TonemapUniforms.of(t, self.graph.options.screen_format);
        self.graph.gpu.writeBuffer(self.tonemap_buffer, 0, std.mem.asBytes(&u));
    }

    /// Turn FXAA on with a quality tier, or off with null. A new tier
    /// makes a new pipeline.
    pub fn setFxaa(self: *PostChain, quality: ?FxaaQuality) !void {
        if (quality) |q| {
            if (self.fxaa_quality != q or self.fxaa_link.pipeline == null) {
                var buf: [gpu_mod.fxaa.max_source_len]u8 = undefined;
                const code = try gpu_mod.fxaa.shaderSource(&buf, q, post_plan.input_group);
                self.fxaa_link.pipeline = try self.makePipeline(code, "vs_main", "fs_main", self.graph.options.screen_format, &self.input_layout, null);
            }
            self.fxaa_quality = q;
            self.fxaa_link.enabled = true;
        } else {
            self.fxaa_link.enabled = false;
        }
        try self.reroute();
    }

    fn find(self: *const PostChain, pass: PassId) *Link {
        for (self.links[0..self.link_count]) |l| if (l.pass == pass) return l;
        unreachable;
    }

    /// Add a link to the graph, at the end of the links of its kind.
    fn addLink(self: *PostChain, name: []const u8, kind: Kind, rank: i32, pipeline: ?gpu_mod.RenderPipeline, params: ?gpu_mod.BindGroup, enabled: bool) !*Link {
        if (self.link_count == max_links) return error.TooManyEffects;
        if (self.graph.findPass(name) != null) return error.DuplicateEffectName;
        const link = try self.allocator.create(Link);
        errdefer self.allocator.destroy(link);
        // The pass starts disabled. `reroute` gives it its attachments.
        try self.graph.addPass(.{
            .name = name,
            .order = self.options.order + rank,
            .attachments = .{ .colors = &.{.{ .target = .screen }} },
            .callback = .of(Link, link, Link.run),
        });
        const pass = self.graph.findPass(name).?;
        self.graph.setPassEnabled(pass, false);
        link.* = .{
            .kind = kind,
            .rank = rank,
            .enabled = enabled,
            .pass = pass,
            .pipeline = pipeline,
            .params = params,
            .input_layout = self.input_layout,
            .sampler = self.sampler,
        };

        // The run sequence: after the last link with the same rank or a
        // lower rank. The frame graph runs the passes in the same
        // sequence, because equal orders keep the add sequence.
        var at: usize = self.link_count;
        while (at > 0 and self.links[at - 1].rank > rank) at -= 1;
        var i = self.link_count;
        while (i > at) : (i -= 1) self.links[i] = self.links[i - 1];
        self.links[at] = link;
        self.link_count += 1;
        return link;
    }

    /// Give each link its input and output from the route, and add the
    /// targets that the route needs.
    fn reroute(self: *PostChain) !void {
        var links: [max_links]post_plan.Link = undefined;
        for (self.links[0..self.link_count], 0..) |l, i| {
            links[i] = .{ .kind = l.kind, .enabled = l.enabled and l.pipeline != null };
        }
        var routes: [max_links]?post_plan.Route = undefined;
        try post_plan.route(links[0..self.link_count], routes[0..self.link_count]);

        const slot_names = [_][]const u8{ "sw_post_hdr", "sw_post_hdr_b", "sw_post_ldr_a", "sw_post_ldr_b" };
        for (0..4) |s| {
            if (self.slots[s] != null) continue;
            if (!post_plan.uses(routes[0..self.link_count], @fromBackingInt(@intCast(s)))) continue;
            const format = if (s < 2) self.hdr_format else self.graph.options.screen_format;
            self.slots[s] = try self.graph.addTarget(.{ .name = slot_names[s], .format = format });
        }

        for (self.links[0..self.link_count], 0..) |l, i| {
            const r = routes[i] orelse {
                self.graph.setPassEnabled(l.pass, false);
                continue;
            };
            l.input = self.target(r.input);
            const colors = [_]plan.ColorAttachment{.{ .target = self.target(r.output) }};
            try self.graph.setPassAttachments(l.pass, .{ .colors = &colors });
            self.graph.setPassEnabled(l.pass, true);
        }
    }

    fn target(self: *const PostChain, slot: post_plan.Slot) TargetId {
        if (slot == .screen) return .screen;
        return self.slots[@backingInt(slot)].?;
    }

    fn makePipeline(
        self: *PostChain,
        code: []const u8,
        vertex_entry: []const u8,
        fragment_entry: []const u8,
        format: gpu_mod.TextureFormat,
        input_layout: *gpu_mod.BindGroupLayout,
        params_layout: ?*gpu_mod.BindGroupLayout,
    ) !gpu_mod.RenderPipeline {
        const gpu = self.graph.gpu;
        var layouts: [3]*gpu_mod.BindGroupLayout = .{ &self.graph.frame_layout, input_layout, undefined };
        var count: usize = 2;
        if (params_layout) |p| {
            layouts[2] = p;
            count = 3;
        }
        var layout = try gpu.createPipelineLayout(.{ .bind_group_layouts = layouts[0..count] });
        var module = try gpu.createShaderModule(.{ .code = code });
        return gpu.createRenderPipeline(.{
            .layout = &layout,
            .vertex = .{ .module = &module, .entry_point = vertex_entry },
            .fragment = .{
                .module = &module,
                .entry_point = fragment_entry,
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = format }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .multisample = .{ .count = 1 },
        });
    }
};
