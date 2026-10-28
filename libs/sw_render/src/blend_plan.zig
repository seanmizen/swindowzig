//! One far-to-near order for translucent quads and particles, with no GPU
//! code (REQ-GPU-041).
//!
//! The translucent pass and the particle pass each sort their own quads
//! far to near. Two passes in a row still draw each particle over each
//! translucent quad, also a particle behind a quad. `mergeRuns` merges the
//! two sorted lists into one far-to-near list. The list is a sequence of
//! runs: each run is a range of quads of one kind, in the draw order of
//! that kind. `blend.zig` draws the runs in one render pass, and changes
//! the pipeline at each run.
const std = @import("std");

/// The kind of a run.
pub const Kind = enum(u8) { quad, particle };

/// `count` quads of one kind, from quad `first` in the draw order of that
/// kind.
pub const Run = struct {
    kind: Kind,
    first: u32,
    count: u32,
};

/// Merge the squared distances of the translucent quads and the particles,
/// each in its draw order (far to near), into runs from far to near.
/// At equal distances, the translucent quad draws first. The runs replace
/// the items of `runs`.
pub fn mergeRuns(allocator: std.mem.Allocator, quad_dist: []const f32, particle_dist: []const f32, runs: *std.ArrayList(Run)) !void {
    runs.clearRetainingCapacity();
    var qi: usize = 0;
    var pi: usize = 0;
    while (qi < quad_dist.len or pi < particle_dist.len) {
        const take_quad = pi == particle_dist.len or (qi < quad_dist.len and quad_dist[qi] >= particle_dist[pi]);
        const kind: Kind = if (take_quad) .quad else .particle;
        const index: u32 = @intCast(if (take_quad) qi else pi);
        if (take_quad) qi += 1 else pi += 1;
        if (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            if (last.kind == kind) {
                last.count += 1;
                continue;
            }
        }
        try runs.append(allocator, .{ .kind = kind, .first = index, .count = 1 });
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "blend: a particle behind a translucent quad draws before it (REQ-GPU-041)" {
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(testing.allocator);
    // A quad at distance 2 (squared 4), a particle at distance 3 (9).
    try mergeRuns(testing.allocator, &.{4}, &.{9}, &runs);
    try testing.expectEqualSlices(Run, &.{
        .{ .kind = .particle, .first = 0, .count = 1 },
        .{ .kind = .quad, .first = 0, .count = 1 },
    }, runs.items);
    // The particle in front: the quad first.
    try mergeRuns(testing.allocator, &.{9}, &.{4}, &runs);
    try testing.expectEqual(Kind.quad, runs.items[0].kind);
}

test "blend: the runs keep the order of each kind and join neighbours of one kind (REQ-GPU-041)" {
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(testing.allocator);
    // Quads at 100, 50, 49, 10. Particles at 60, 55, 20, 1.
    try mergeRuns(testing.allocator, &.{ 100, 50, 49, 10 }, &.{ 60, 55, 20, 1 }, &runs);
    try testing.expectEqualSlices(Run, &.{
        .{ .kind = .quad, .first = 0, .count = 1 },
        .{ .kind = .particle, .first = 0, .count = 2 },
        .{ .kind = .quad, .first = 1, .count = 2 },
        .{ .kind = .particle, .first = 2, .count = 1 },
        .{ .kind = .quad, .first = 3, .count = 1 },
        .{ .kind = .particle, .first = 3, .count = 1 },
    }, runs.items);
    // Each quad is in one run, and the runs of a kind cover it in order.
    var next = [2]u32{ 0, 0 };
    for (runs.items) |r| {
        try testing.expectEqual(next[@backingInt(r.kind)], r.first);
        next[@backingInt(r.kind)] += r.count;
    }
    try testing.expectEqual([2]u32{ 4, 4 }, next);
    // One kind only: one run. None: no run.
    try mergeRuns(testing.allocator, &.{ 3, 2, 1 }, &.{}, &runs);
    try testing.expectEqualSlices(Run, &.{.{ .kind = .quad, .first = 0, .count = 3 }}, runs.items);
    try mergeRuns(testing.allocator, &.{}, &.{}, &runs);
    try testing.expectEqual(@as(usize, 0), runs.items.len);
    // Equal distances: the quad first.
    try mergeRuns(testing.allocator, &.{5}, &.{5}, &runs);
    try testing.expectEqual(Kind.quad, runs.items[0].kind);
}
