//! The translucent pass with no GPU code (REQ-GPU-022, REQ-GPU-023): the
//! quad sort from far to near, the rule that decides when to sort again,
//! the pipeline states, the WGSL and the CPU reference of the blend.
//!
//! A translucent quad draws after the opaque pass, with the depth test on
//! and the depth write off. An opaque surface in front of the quad then
//! hides it, and two translucent quads do not hide each other. The quads
//! must draw from far to near, so that each blend puts the nearer colour
//! over the further colours. The sort keeps the vertices where they are,
//! and changes only the index list. It runs again only when the camera
//! moves `resort_distance` or more from the position of the last sort.
//!
//! The technique follows the translucency sort of horizon (MIT). No code
//! of horizon is in this file.
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const wgsl = @import("wgsl.zig");

/// One corner of a translucent quad. Straight alpha: the colour is not
/// multiplied by the alpha.
pub const Vertex = extern struct {
    pos: [3]f32,
    color: [4]f32,
};

/// The 4 corners of one quad, counter-clockwise or clockwise. The pass
/// draws both sides.
pub const Quad = [4]Vertex;

/// The blend state: src · alpha + dst · (1 - alpha) for the colour.
pub const blend: gpu_mod.BlendState = .{
    .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
    .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
};

/// The depth state of the pass: the test on, the write off (REQ-GPU-022).
pub fn depthStencil(format: gpu_mod.TextureFormat) gpu_mod.DepthStencilState {
    return .{ .format = format, .depth_write_enabled = false, .depth_compare = .less };
}

/// The CPU reference of one blend: `src` with alpha `a` over `dst`.
pub fn over(dst: [3]f32, src: [3]f32, a: f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |i| out[i] = src[i] * a + dst[i] * (1 - a);
    return out;
}

/// The centre of a quad: the mean of two opposite corners.
pub fn center(q: Quad) [3]f32 {
    var c: [3]f32 = undefined;
    for (0..3) |i| c[i] = (q[0].pos[i] + q[2].pos[i]) * 0.5;
    return c;
}

fn distanceSq(a: [3]f32, b: [3]f32) f32 {
    const d: [3]f32 = .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
    return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}

/// Sort quads from far to near.
pub const Sorter = struct {
    order: std.ArrayList(Key) = .empty,

    const Key = struct { quad: u32, dist: f32 };

    pub fn deinit(self: *Sorter, allocator: std.mem.Allocator) void {
        self.order.deinit(allocator);
    }

    /// Write the indices of the two triangles of each quad, the furthest
    /// quad first, into `out` (6 for each quad). Quads at the same
    /// distance keep the order of `centers`.
    pub fn sort(self: *Sorter, allocator: std.mem.Allocator, centers: []const [3]f32, camera: [3]f32, out: []u32) !void {
        std.debug.assert(out.len == centers.len * 6);
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(allocator, centers.len);
        for (centers, 0..) |c, i| self.order.appendAssumeCapacity(.{ .quad = @intCast(i), .dist = distanceSq(c, camera) });
        std.sort.block(Key, self.order.items, {}, struct {
            fn further(_: void, a: Key, b: Key) bool {
                return a.dist > b.dist;
            }
        }.further);
        for (self.order.items, 0..) |k, i| {
            const v = k.quad * 4;
            out[i * 6 ..][0..6].* = .{ v, v + 1, v + 2, v, v + 2, v + 3 };
        }
    }
};

/// When to sort again: after the first sort, only when the camera moves
/// `resort_distance` or more from the position of the last sort, or when
/// the quads change.
pub const SortState = struct {
    resort_distance: f32,
    last: ?[3]f32 = null,

    /// True when the quads need a sort for a camera at `camera`. Then the
    /// state keeps `camera` as the position of the last sort.
    pub fn needsSort(self: *SortState, camera: [3]f32) bool {
        if (self.last) |l| {
            if (distanceSq(l, camera) < self.resort_distance * self.resort_distance) return false;
        }
        self.last = camera;
        return true;
    }

    /// Sort at the next `needsSort`, for example after the quads change.
    pub fn invalidate(self: *SortState) void {
        self.last = null;
    }
};

/// The WGSL of the pass. Group 0 is the frame. The vertex has the world
/// position and the colour.
pub const shader = wgsl.shader(
    \\struct SwTranslucentOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\}
    \\
    \\@vertex fn vs_main(@location(0) pos: vec3<f32>, @location(1) color: vec4<f32>) -> SwTranslucentOut {
    \\    var out: SwTranslucentOut;
    \\    out.pos = sw_frame.view_proj * vec4<f32>(pos, 1.0);
    \\    out.color = color;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: SwTranslucentOut) -> @location(0) vec4<f32> {
    \\    return in.color;
    \\}
    \\
);

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn quadAt(c: [3]f32) Quad {
    const v = struct {
        fn f(p: [3]f32) Vertex {
            return .{ .pos = p, .color = .{ 1, 1, 1, 0.5 } };
        }
    }.f;
    return .{
        v(.{ c[0] - 0.5, c[1] - 0.5, c[2] }),
        v(.{ c[0] + 0.5, c[1] - 0.5, c[2] }),
        v(.{ c[0] + 0.5, c[1] + 0.5, c[2] }),
        v(.{ c[0] - 0.5, c[1] + 0.5, c[2] }),
    };
}

test "translucent: the sort puts the furthest quad first, and ties keep their order (REQ-GPU-023)" {
    var s: Sorter = .{};
    defer s.deinit(testing.allocator);
    const centers = [_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 4, 0, 0 } };
    var out: [18]u32 = undefined;
    try s.sort(testing.allocator, &centers, .{ 0, 0, 0 }, &out);
    try testing.expectEqualSlices(u32, &.{ 8, 9, 10, 8, 10, 11, 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 }, &out);
    var none: [0]u32 = .{};
    try s.sort(testing.allocator, &.{}, .{ 0, 0, 0 }, &none);
}

test "translucent: a camera on the other side reverses the order (REQ-GPU-023)" {
    var s: Sorter = .{};
    defer s.deinit(testing.allocator);
    const centers = [_][3]f32{ center(quadAt(.{ 0.5, 0.5, 0 })), center(quadAt(.{ 0.5, 0.5, 1 })) };
    var out: [12]u32 = undefined;
    try s.sort(testing.allocator, &centers, .{ 0.5, 0.5, -2 }, &out);
    try testing.expectEqual(@as(u32, 4), out[0]);
    try s.sort(testing.allocator, &centers, .{ 0.5, 0.5, 3 }, &out);
    try testing.expectEqual(@as(u32, 0), out[0]);
}

test "translucent: the sort runs again only after the camera moves the resort distance (REQ-GPU-023)" {
    var st: SortState = .{ .resort_distance = 1 };
    try testing.expect(st.needsSort(.{ 0, 0, 0 }));
    try testing.expect(!st.needsSort(.{ 0, 0, 0 }));
    try testing.expect(!st.needsSort(.{ 0.6, 0.6, 0 }));
    try testing.expect(st.needsSort(.{ 0.8, 0.8, 0 }));
    // The distance is from the last sort, not from the last call.
    try testing.expect(!st.needsSort(.{ 1.5, 0.8, 0 }));
    st.invalidate();
    try testing.expect(st.needsSort(.{ 1.5, 0.8, 0 }));
}

test "translucent: the depth test is on and the depth write is off (REQ-GPU-022)" {
    const d = depthStencil(.depth24plus);
    try testing.expect(!d.depth_write_enabled);
    try testing.expectEqual(gpu_mod.CompareFunction.less, d.depth_compare);
    try testing.expect(blend.color.src_factor == .src_alpha);
    try testing.expect(blend.color.dst_factor == .one_minus_src_alpha);
}

test "translucent: far to near gives the near colour the most weight" {
    // Red at alpha 0.5 behind blue at alpha 0.5, over black.
    const sorted = over(over(.{ 0, 0, 0 }, .{ 1, 0, 0 }, 0.5), .{ 0, 0, 1 }, 0.5);
    try testing.expectEqual([3]f32{ 0.25, 0, 0.5 }, sorted);
    const wrong = over(over(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 0.5), .{ 1, 0, 0 }, 0.5);
    try testing.expect(wrong[0] > wrong[2]);
}

test "translucent: the shader starts with the WGSL prefix" {
    try testing.expect(std.mem.startsWith(u8, shader, wgsl.prefix));
    try testing.expectEqual(@as(usize, 28), @sizeOf(Vertex));
}
