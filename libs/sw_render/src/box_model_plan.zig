//! Box models with no GPU code: the model description, the mesh, the pose
//! of the parts, the GPU record layouts, the WGSL and the CPU reference of
//! the shader (REQ-GPU-014, REQ-GPU-015).
//!
//! A model is a tree of parts. Each part has boxes, a pivot and a parent.
//! The boxes and the pivots are in model space, at the rest pose. Each
//! frame the game gives one rotation for each part. A part turns about its
//! pivot, and then follows its parent:
//!
//!     part_matrix = parent_matrix * T(pivot) * R(rotation) * T(-pivot)
//!
//! The root parts use the transform of the instance as the parent matrix.
//! `box_models.zig` draws all instances of one model with one draw call.

const std = @import("std");
const sw_math = @import("sw_math");
const wgsl = @import("wgsl.zig");

const Mat4 = sw_math.Mat4;
const Quat = sw_math.Quat;

/// The most parts in one model. `pose` keeps one matrix for each part on
/// the stack.
pub const max_parts = 64;

/// One box of a part: two corners in model space, at the rest pose.
pub const Box = struct {
    min: [3]f32,
    max: [3]f32,
    /// Linear RGB albedo.
    color: [3]f32 = .{ 1, 1, 1 },
};

pub const Part = struct {
    /// The index of the parent part. It must be lower than the index of
    /// this part. Null: a root part.
    parent: ?u8 = null,
    /// The point in model space that the part turns about.
    pivot: [3]f32 = .{ 0, 0, 0 },
    boxes: []const Box = &.{},
};

pub const ModelDesc = struct {
    /// The parts in tree order: a parent comes before its children.
    parts: []const Part,
};

pub const Error = error{
    NoParts,
    TooManyParts,
    /// A parent index that is not lower than the index of the part.
    BadParent,
    /// A box with `max` less than `min` on an axis.
    BadBox,
    /// More rotations than parts.
    TooManyRotations,
};

/// Check that the model can be drawn.
pub fn validate(desc: ModelDesc) Error!void {
    if (desc.parts.len == 0) return error.NoParts;
    if (desc.parts.len > max_parts) return error.TooManyParts;
    for (desc.parts, 0..) |p, i| {
        if (p.parent) |parent| {
            if (parent >= i) return error.BadParent;
        }
        for (p.boxes) |b| {
            for (0..3) |a| {
                if (b.max[a] < b.min[a]) return error.BadBox;
            }
        }
    }
}

// =============================================================================
// The mesh
// =============================================================================

/// One vertex of the model mesh. `part` selects the part matrix.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    color: [3]f32,
    part: u32,
};

/// Two triangles on each of the six faces.
pub const vertices_per_box = 36;

/// The number of vertices that `buildMesh` writes.
pub fn vertexCount(desc: ModelDesc) usize {
    var n: usize = 0;
    for (desc.parts) |p| n += p.boxes.len * vertices_per_box;
    return n;
}

/// Write the triangles of each box into `out` (`vertexCount` vertices). The
/// triangles turn counter-clockwise when seen from outside the box.
pub fn buildMesh(desc: ModelDesc, out: []Vertex) void {
    var n: usize = 0;
    for (desc.parts, 0..) |p, part| {
        for (p.boxes) |b| {
            for (0..3) |axis| {
                for ([_]bool{ false, true }) |positive| {
                    var normal: [3]f32 = .{ 0, 0, 0 };
                    normal[axis] = if (positive) 1 else -1;
                    // (axis, a, b) is a right-handed set of axes.
                    const a = (axis + 1) % 3;
                    const c = (axis + 2) % 3;
                    var quad: [4][3]f32 = undefined;
                    // The corners go round the face. On the positive face
                    // they turn counter-clockwise when seen from outside.
                    const order = [4][2]bool{ .{ false, false }, .{ true, false }, .{ true, true }, .{ false, true } };
                    for (0..4) |k| {
                        const corner = if (positive) order[k] else order[3 - k];
                        var v: [3]f32 = undefined;
                        v[axis] = if (positive) b.max[axis] else b.min[axis];
                        v[a] = if (corner[0]) b.max[a] else b.min[a];
                        v[c] = if (corner[1]) b.max[c] else b.min[c];
                        quad[k] = v;
                    }
                    for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |k| {
                        out[n] = .{ .position = quad[k], .normal = normal, .color = b.color, .part = @intCast(part) };
                        n += 1;
                    }
                }
            }
        }
    }
}

// =============================================================================
// The pose
// =============================================================================

/// The matrix of one part relative to its parent: a turn by `rotation`
/// about `pivot`.
pub fn partLocal(pivot: [3]f32, rotation: Quat) Mat4 {
    const to = Mat4.translation(pivot[0], pivot[1], pivot[2]);
    const from = Mat4.translation(-pivot[0], -pivot[1], -pivot[2]);
    return to.mul(rotation.toMat4()).mul(from);
}

/// The matrix of each part, from model space at the rest pose to the space
/// of `root`. `rotations[i]` turns part `i`. A part with no rotation in
/// the slice does not turn. `out` has one entry for each part.
pub fn pose(parts: []const Part, root: Mat4, rotations: []const Quat, out: []Mat4) Error!void {
    if (rotations.len > parts.len) return error.TooManyRotations;
    for (parts, 0..) |p, i| {
        const q = if (i < rotations.len) rotations[i] else Quat.identity();
        const parent = if (p.parent) |pi| out[pi] else root;
        out[i] = parent.mul(partLocal(p.pivot, q));
    }
}

// =============================================================================
// GPU layouts
// =============================================================================

/// One part of one instance in the storage buffer: `SwBoxPart` in `shader`.
pub const PartRecord = extern struct {
    /// Model space to world space (or view space), column-major.
    model: [16]f32,
    /// rgb: multiplies the albedo. w: not used.
    tint: [4]f32 = .{ 1, 1, 1, 1 },
};

/// How the vertex shader gets the matrix to clip space.
pub const CameraMode = enum(u32) {
    /// `DrawUniforms.view_proj`.
    custom = 0,
    /// `sw_frame.view_proj`: the instances are in world space.
    frame = 1,
    /// `sw_frame.proj`: the instances are in view space. The light turns
    /// with `sw_frame.view`.
    frame_view_space = 2,
};

/// The per-draw uniforms: `SwBoxDraw` in `shader`.
pub const DrawUniforms = extern struct {
    view_proj: [16]f32 = wgsl.identity,
    /// xyz: the unit vector to the light. w: not used.
    light_dir: [4]f32,
    /// rgb: the light colour. w: not used.
    light_color: [4]f32,
    /// rgb: the ambient light. w: not used.
    ambient: [4]f32,
    /// x: the depth of the near plane. y: the depth of the far plane.
    depth_range: [4]f32 = .{ 0, 1, 0, 0 },
    /// x: the first record. y: the parts in one instance. z: `CameraMode`.
    /// w: 1 for the fog, 0 for no fog.
    info: [4]u32,
};

/// A directional light and an ambient light, in linear RGB.
pub const Light = struct {
    /// The vector to the light, in world space. It need not be a unit vector.
    dir: [3]f32 = .{ 0.3, 0.8, 0.5 },
    color: [3]f32 = .{ 0.8, 0.8, 0.8 },
    ambient: [3]f32 = .{ 0.35, 0.37, 0.42 },

    pub fn unitDir(self: Light) [3]f32 {
        const d = self.dir;
        const len = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        if (len == 0) return .{ 0, 1, 0 };
        return .{ d[0] / len, d[1] / len, d[2] / len };
    }
};

/// The WGSL of the box model pipeline, after the shared prefix. Group 1:
/// binding 0 is the per-draw uniforms (a ring binding), binding 1 the part
/// records.
pub const shader = wgsl.shader(
    \\struct SwBoxDraw {
    \\    view_proj: mat4x4<f32>,
    \\    light_dir: vec4<f32>,
    \\    light_color: vec4<f32>,
    \\    ambient: vec4<f32>,
    \\    depth_range: vec4<f32>,
    \\    info: vec4<u32>,
    \\}
    \\struct SwBoxPart {
    \\    model: mat4x4<f32>,
    \\    tint: vec4<f32>,
    \\}
    \\@group(1) @binding(0) var<uniform> sw_box: SwBoxDraw;
    \\@group(1) @binding(1) var<storage, read> sw_box_parts: array<SwBoxPart>;
    \\
    \\struct SwBoxOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) world: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) color: vec3<f32>,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @builtin(instance_index) instance: u32,
    \\    @location(0) pos: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) color: vec3<f32>,
    \\    @location(3) part: u32,
    \\) -> SwBoxOut {
    \\    let p = sw_box_parts[sw_box.info.x + instance * sw_box.info.y + part];
    \\    let world = p.model * vec4<f32>(pos, 1.0);
    \\    var vp = sw_box.view_proj;
    \\    if (sw_box.info.z == 1u) {
    \\        vp = sw_frame.view_proj;
    \\    } else if (sw_box.info.z == 2u) {
    \\        vp = sw_frame.proj;
    \\    }
    \\    var clip = vp * world;
    \\    // The own depth range: NDC depth d becomes near + d * (far - near).
    \\    let r = sw_box.depth_range;
    \\    clip.z = r.x * clip.w + (r.y - r.x) * clip.z;
    \\    var out: SwBoxOut;
    \\    out.pos = clip;
    \\    out.world = world.xyz;
    \\    out.normal = (p.model * vec4<f32>(normal, 0.0)).xyz;
    \\    out.color = color * p.tint.rgb;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: SwBoxOut) -> @location(0) vec4<f32> {
    \\    var l = sw_box.light_dir.xyz;
    \\    if (sw_box.info.z == 2u) {
    \\        l = (sw_frame.view * vec4<f32>(l, 0.0)).xyz;
    \\    }
    \\    let d = max(dot(normalize(in.normal), l), 0.0);
    \\    var c = in.color * (sw_box.ambient.rgb + sw_box.light_color.rgb * d);
    \\    if (sw_box.info.w != 0u) {
    \\        c = sw_fog(c, in.world);
    \\    }
    \\    return vec4<f32>(c, 1.0);
    \\}
    \\
);

// =============================================================================
// CPU reference of the shader
// =============================================================================

/// The colour of a fragment before the fog: the albedo times the tint,
/// lit by `light`. `normal` and `light_dir` are unit vectors in one space.
pub fn shade(albedo: [3]f32, tint: [3]f32, normal: [3]f32, light_dir: [3]f32, light: Light) [3]f32 {
    const d = @max(normal[0] * light_dir[0] + normal[1] * light_dir[1] + normal[2] * light_dir[2], 0.0);
    var c: [3]f32 = undefined;
    for (0..3) |i| c[i] = albedo[i] * tint[i] * (light.ambient[i] + light.color[i] * d);
    return c;
}

/// The depth of a fragment with NDC depth `ndc_z` in the depth range
/// `range` (near, far).
pub fn remapDepth(ndc_z: f32, range: [2]f32) f32 {
    return range[0] + ndc_z * (range[1] - range[0]);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn transformPoint(m: Mat4, p: [3]f32) [3]f32 {
    const v = m.mulVec4(.{ .x = p[0], .y = p[1], .z = p[2], .w = 1 });
    return .{ v.x, v.y, v.z };
}

fn expectPoint(want: [3]f32, got: [3]f32) !void {
    for (0..3) |i| try testing.expectApproxEqAbs(want[i], got[i], 1e-5);
}

/// An arm on a body, and a hand on the arm, as in the `models` example.
const arm_parts = [_]Part{
    .{ .pivot = .{ 0, 1, 0 } },
    .{ .parent = 0, .pivot = .{ 0.5, 2, 0 } },
    .{ .parent = 1, .pivot = .{ 0.5, 1, 0 } },
};

test "box models: a part turns about its pivot and follows its parent (REQ-GPU-014)" {
    var out: [3]Mat4 = undefined;
    const quarter = std.math.pi / 2.0;
    const z: sw_math.Vec3 = .{ .x = 0, .y = 0, .z = 1 };
    const root = Mat4.translation(10, 0, 0);

    // The rest pose: each point moves by the root transform only.
    try pose(&arm_parts, root, &.{}, &out);
    try expectPoint(.{ 10.5, 0.5, 0 }, transformPoint(out[2], .{ 0.5, 0.5, 0 }));

    // The arm turns a quarter about +Z. It hung down from the shoulder
    // (0.5, 2), so now it points to +X. The elbow (0.5, 1) goes to (1.5, 2).
    try pose(&arm_parts, root, &.{ Quat.identity(), Quat.fromAxisAngle(z, quarter) }, &out);
    try expectPoint(.{ 11.5, 2, 0 }, transformPoint(out[1], .{ 0.5, 1, 0 }));
    // The shoulder stays where it is.
    try expectPoint(.{ 10.5, 2, 0 }, transformPoint(out[1], .{ 0.5, 2, 0 }));
    // The hand did not turn, but it follows the arm.
    try expectPoint(.{ 12, 2, 0 }, transformPoint(out[2], .{ 0.5, 0.5, 0 }));

    // The hand turns a quarter more about the elbow: it points up.
    try pose(&arm_parts, root, &.{ Quat.identity(), Quat.fromAxisAngle(z, quarter), Quat.fromAxisAngle(z, quarter) }, &out);
    try expectPoint(.{ 11.5, 2.5, 0 }, transformPoint(out[2], .{ 0.5, 0.5, 0 }));

    // The body turns half a turn about +Y at its pivot: all children follow.
    const y: sw_math.Vec3 = .{ .x = 0, .y = 1, .z = 0 };
    try pose(&arm_parts, root, &.{Quat.fromAxisAngle(y, std.math.pi)}, &out);
    try expectPoint(.{ 9.5, 0.5, 0 }, transformPoint(out[2], .{ 0.5, 0.5, 0 }));

    const four: [4]Quat = @splat(Quat.identity());
    try testing.expectError(error.TooManyRotations, pose(&arm_parts, root, &four, &out));
}

test "box models: validate rejects a bad tree (REQ-GPU-014)" {
    const box: Box = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    try validate(.{ .parts = &.{ .{ .boxes = &.{box} }, .{ .parent = 0 } } });
    try testing.expectError(error.NoParts, validate(.{ .parts = &.{} }));
    try testing.expectError(error.BadParent, validate(.{ .parts = &.{ .{}, .{ .parent = 1 } } }));
    try testing.expectError(error.BadParent, validate(.{ .parts = &.{ .{ .parent = 3 }, .{} } }));
    try testing.expectError(error.BadBox, validate(.{ .parts = &.{.{ .boxes = &.{.{ .min = .{ 0, 2, 0 }, .max = .{ 1, 1, 1 } }} }} }));
    const many: [max_parts + 1]Part = @splat(.{});
    try testing.expectError(error.TooManyParts, validate(.{ .parts = &many }));
}

test "box models: the mesh has 36 vertices for each box, wound counter-clockwise from outside (REQ-GPU-014)" {
    const boxes_a = [_]Box{.{ .min = .{ -1, 0, -2 }, .max = .{ 1, 3, 2 }, .color = .{ 1, 0, 0 } }};
    const boxes_b = [_]Box{
        .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } },
        .{ .min = .{ 2, 2, 2 }, .max = .{ 3, 4, 5 }, .color = .{ 0, 0, 1 } },
    };
    const desc: ModelDesc = .{ .parts = &.{ .{ .boxes = &boxes_a }, .{ .parent = 0, .boxes = &boxes_b } } };
    try testing.expectEqual(@as(usize, 3 * 36), vertexCount(desc));
    var out: [3 * 36]Vertex = undefined;
    buildMesh(desc, &out);

    var t: usize = 0;
    while (t < out.len) : (t += 3) {
        const v = out[t..][0..3];
        // Each triangle is in one part and one box.
        try testing.expectEqual(v[0].part, v[1].part);
        try testing.expectEqual(v[0].part, v[2].part);
        try testing.expectEqual(@as(u32, if (t < 36) 0 else 1), v[0].part);
        // The cross product of the edges points along the outward normal.
        var e1: [3]f32 = undefined;
        var e2: [3]f32 = undefined;
        for (0..3) |i| {
            e1[i] = v[1].position[i] - v[0].position[i];
            e2[i] = v[2].position[i] - v[0].position[i];
        }
        const cross: [3]f32 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        const n = v[0].normal;
        try testing.expect(cross[0] * n[0] + cross[1] * n[1] + cross[2] * n[2] > 0);
        // Each vertex is on the face of the normal.
        const box = if (t < 36) boxes_a[0] else boxes_b[(t - 36) / 36];
        for (v) |vert| {
            for (0..3) |i| {
                if (n[i] > 0) try testing.expectEqual(box.max[i], vert.position[i]);
                if (n[i] < 0) try testing.expectEqual(box.min[i], vert.position[i]);
            }
            try testing.expectEqual(box.color, vert.color);
        }
    }
}

test "box models: the own depth range maps NDC depth into near to far (REQ-GPU-015)" {
    const range: [2]f32 = .{ 0, 0.01 };
    try testing.expectEqual(@as(f32, 0), remapDepth(0, range));
    try testing.expectApproxEqAbs(@as(f32, 0.01), remapDepth(1, range), 1e-7);
    // The farthest point of the range is in front of the scene depth of a
    // point a short distance past the near plane.
    const near = 0.1;
    const far = 1000.0;
    const scene_depth = far / (far - near) * (1.0 - near / 0.15);
    try testing.expect(remapDepth(1, range) < scene_depth);
    // The full range does not change the depth.
    try testing.expectEqual(@as(f32, 0.25), remapDepth(0.25, .{ 0, 1 }));
}

test "box models: the shader structs have the layouts of the Zig records (REQ-GPU-014)" {
    try testing.expectEqual(@as(usize, 80), @sizeOf(PartRecord));
    try testing.expectEqual(@as(usize, 64), @offsetOf(PartRecord, "tint"));
    try testing.expectEqual(@as(usize, 144), @sizeOf(DrawUniforms));
    const offsets = [_]struct { []const u8, usize }{
        .{ "light_dir", 64 }, .{ "light_color", 80 }, .{ "ambient", 96 }, .{ "depth_range", 112 }, .{ "info", 128 },
    };
    inline for (offsets) |o| try testing.expectEqual(o[1], @offsetOf(DrawUniforms, o[0]));
    try testing.expectEqual(@as(usize, 40), @sizeOf(Vertex));
    try testing.expect(std.mem.startsWith(u8, shader, wgsl.prefix));
    try testing.expect(std.mem.indexOf(u8, shader, "info: vec4<u32>,\n}") != null);
    try testing.expect(std.mem.indexOf(u8, shader, "sw_fog(c, in.world)") != null);
}

test "box models: the CPU shade lights the faces that turn to the light (REQ-GPU-014)" {
    const light: Light = .{ .dir = .{ 0, 2, 0 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.25, 0.25, 0.25 } };
    const l = light.unitDir();
    try expectPoint(.{ 0, 1, 0 }, l);
    try expectPoint(.{ 1.25, 0.625, 0 }, shade(.{ 1, 0.5, 0 }, .{ 1, 1, 1 }, .{ 0, 1, 0 }, l, light));
    try expectPoint(.{ 0.125, 0.25, 0 }, shade(.{ 1, 0.5, 0 }, .{ 0.5, 2, 1 }, .{ 0, -1, 0 }, l, light));
}
