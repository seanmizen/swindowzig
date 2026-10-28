//! `SortedBlend`: the translucent quads of a `Translucent` and the
//! particles of a `Particles` in one far-to-near order, in one pass
//! (REQ-GPU-041). A particle behind a translucent quad then draws before
//! the quad, so the quad blends over it. `blend_plan.zig` has the merge.
//!
//! The two objects keep their API. `addPass` turns off their own passes,
//! if any, and adds the pass "sw_blend". Each frame, `update` calls
//! `Translucent.update` and `Particles.update`, and merges the two sorted
//! lists into runs. The pass draws each run with the pipeline of its kind.
//!
//! ```zig
//! var blend = render.SortedBlend.init(allocator, &glass, &sparks);
//! try blend.addPass(.{ .color = post.hdr, .depth = depth });
//! // Each frame, before graph.execute:
//! try blend.update(&system, render.ParticleCamera.fromView(frame.view, eye));
//! ```
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const frame_graph = @import("frame_graph.zig");
const plan = @import("blend_plan.zig");
const translucent_mod = @import("translucent.zig");
const particles_mod = @import("particles.zig");
const particle_plan = @import("particle_plan.zig");

const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = @import("plan.zig").TargetId;

pub const Run = plan.Run;

pub const PassOptions = struct {
    color: TargetId,
    depth: TargetId,
    /// The frame graph order: the order of the translucent pass (55).
    order: i32 = 55,
};

pub const SortedBlend = struct {
    allocator: std.mem.Allocator,
    translucent: *translucent_mod.Translucent,
    particles: *particles_mod.Particles,
    runs: std.ArrayList(Run) = .empty,
    quad_dist: std.ArrayList(f32) = .empty,
    particle_dist: std.ArrayList(f32) = .empty,
    /// The draw calls of the last frame: one for each run. A test reads it.
    draw_calls: u32 = 0,
    pass: ?PassId = null,

    /// The two objects must use the same frame graph, the same targets
    /// and stay at their addresses while the blend exists.
    pub fn init(allocator: std.mem.Allocator, translucent: *translucent_mod.Translucent, particles: *particles_mod.Particles) SortedBlend {
        std.debug.assert(translucent.graph == particles.graph);
        return .{ .allocator = allocator, .translucent = translucent, .particles = particles };
    }

    /// Call it before the `deinit` of the two objects.
    pub fn deinit(self: *SortedBlend) void {
        if (self.pass) |p| self.translucent.graph.setPassEnabled(p, false);
        self.runs.deinit(self.allocator);
        self.quad_dist.deinit(self.allocator);
        self.particle_dist.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add the pass "sw_blend", and turn off the passes "sw_translucent"
    /// and "sw_particles" of the two objects, if they have them.
    pub fn addPass(self: *SortedBlend, options: PassOptions) !void {
        const graph = self.translucent.graph;
        if (self.pass != null) return error.DuplicatePassName;
        if (graph.findPass("sw_blend") != null) return error.DuplicatePassName;
        try graph.addPass(.{
            .name = "sw_blend",
            .order = options.order,
            .attachments = .{
                .colors = &.{.{ .target = options.color, .load_op = .load }},
                .depth = .{ .target = options.depth, .load_op = .load },
            },
            .callback = .of(SortedBlend, self, draw),
        });
        self.pass = graph.findPass("sw_blend").?;
        if (self.translucent.pass) |p| graph.setPassEnabled(p, false);
        if (self.particles.pass) |p| graph.setPassEnabled(p, false);
    }

    /// Sort the translucent quads (when the camera moved the resort
    /// distance), build the particle quads far to near, and merge the two
    /// lists with the distances from `camera` (REQ-GPU-041). Call it each
    /// frame before `FrameGraph.execute`.
    pub fn update(self: *SortedBlend, system: *const particle_plan.System, camera: particle_plan.Camera) !void {
        const t = self.translucent;
        try t.update(camera.pos);
        try self.particles.update(system, camera);
        // The draw order of the quads is the order of the last sort. The
        // distances are from the camera of this frame.
        try self.quad_dist.resize(self.allocator, t.centers.items.len);
        if (t.centers.items.len > 0) {
            for (t.sorter.order.items, self.quad_dist.items) |k, *d| d.* = distSq(t.centers.items[k.quad], camera.pos);
        }
        const n = self.particles.vertex_count / 6;
        try self.particle_dist.resize(self.allocator, n);
        for (self.particles.order.items[0..n], self.particle_dist.items) |k, *d| d.* = k.dist;
        try plan.mergeRuns(self.allocator, self.quad_dist.items, self.particle_dist.items, &self.runs);
    }

    /// Draw the runs of the last `update`. The pass formats must match the
    /// two objects.
    pub fn draw(self: *SortedBlend, pass: *Pass) anyerror!void {
        self.draw_calls = 0;
        if (self.runs.items.len == 0) return;
        const rp = pass.render orelse return error.NoRenderPass;
        const t = self.translucent;
        const p = self.particles;
        const quads: u64 = t.centers.items.len;
        var current: ?plan.Kind = null;
        for (self.runs.items) |r| {
            if (current != r.kind) {
                current = r.kind;
                switch (r.kind) {
                    .quad => {
                        rp.setPipeline(t.pipeline);
                        pass.bindFrame();
                        rp.setVertexBuffer(0, t.vertex_buffer, 0, quads * 4 * @sizeOf(translucent_mod.Vertex));
                        rp.setIndexBuffer(t.index_buffer, .uint32, 0, quads * 6 * @sizeOf(u32));
                    },
                    .particle => {
                        rp.setPipeline(p.pipeline);
                        pass.bindFrame();
                        rp.setBindGroup(1, p.bind_group);
                        rp.setVertexBuffer(0, p.vertex_buffer, 0, @as(u64, p.vertex_count) * @sizeOf(particle_plan.Vertex));
                    },
                }
            }
            switch (r.kind) {
                .quad => rp.drawIndexed(r.count * 6, 1, r.first * 6, 0, 0),
                .particle => rp.draw(r.count * 6, 1, r.first * 6, 0),
            }
            self.draw_calls += 1;
        }
    }
};

fn distSq(a: [3]f32, b: [3]f32) f32 {
    var s: f32 = 0;
    for (0..3) |i| s += (a[i] - b[i]) * (a[i] - b[i]);
    return s;
}
