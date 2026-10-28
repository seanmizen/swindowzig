//! The upload budget of the chunk meshes (REQ-VOXEL-017).
//!
//! The scheduler loads the chunks in the load radius and unloads the
//! chunks out of the unload radius (C8). It runs the jobs of the near
//! chunks and of the chunks in view first. The executor installs results
//! within a time budget (C7). An install can give many new meshes in one
//! frame, and each mesh is a GPU upload. `pickUploads` puts the waiting
//! uploads in the same priority order, and keeps only `max` of them for
//! this frame. The others wait for the next frame.
const std = @import("std");

/// A chunk mesh that waits for its GPU upload.
pub const Candidate = struct {
    /// The chunk is in the view frustum.
    in_view: bool,
    /// dx² + dz² from the camera chunk.
    dist_sq: i32,
    /// An index of the caller, for example into a list of chunks.
    index: usize,
};

/// True when `a` uploads before `b`: a chunk in view first, then the
/// nearer chunk, then the lower index.
pub fn before(_: void, a: Candidate, b: Candidate) bool {
    if (a.in_view != b.in_view) return a.in_view;
    if (a.dist_sq != b.dist_sq) return a.dist_sq < b.dist_sq;
    return a.index < b.index;
}

/// Sort `candidates` by `before`, and give the first `max` of them: the
/// uploads of this frame. Null: no budget.
pub fn pickUploads(candidates: []Candidate, max: ?usize) []Candidate {
    std.sort.pdq(Candidate, candidates, {}, before);
    const n = if (max) |m| @min(m, candidates.len) else candidates.len;
    return candidates[0..n];
}

test "streaming: the upload budget keeps the chunks in view, nearest first (REQ-VOXEL-017)" {
    var c = [_]Candidate{
        .{ .in_view = false, .dist_sq = 0, .index = 0 },
        .{ .in_view = true, .dist_sq = 9, .index = 1 },
        .{ .in_view = true, .dist_sq = 1, .index = 2 },
        .{ .in_view = false, .dist_sq = 4, .index = 3 },
        .{ .in_view = true, .dist_sq = 1, .index = 4 },
    };
    const picked = pickUploads(&c, 3);
    try std.testing.expectEqual(@as(usize, 3), picked.len);
    try std.testing.expectEqual(@as(usize, 2), picked[0].index);
    try std.testing.expectEqual(@as(usize, 4), picked[1].index);
    try std.testing.expectEqual(@as(usize, 1), picked[2].index);
    // The rest wait: the nearest chunk out of view is next.
    try std.testing.expectEqual(@as(usize, 0), c[3].index);
    try std.testing.expectEqual(@as(usize, 5), pickUploads(&c, null).len);
    try std.testing.expectEqual(@as(usize, 0), pickUploads(&c, 0).len);
}
