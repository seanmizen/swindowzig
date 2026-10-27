//! Frame timing of an animated sprite. This file has no GPU code.
//!
//! An animation is a list of frames. Each frame names one image of the
//! sprite and the time that the image shows. After the last frame, the
//! animation starts again at the first frame. The time unit is the unit of
//! the time that the game gives (for example ticks or milliseconds).

const std = @import("std");

/// One step of an animation.
pub const Frame = struct {
    /// The index of the image in the frame images of the sprite.
    image: u32,
    /// How long the image shows. It must be more than 0.
    duration: u32,
};

pub const Error = error{
    NoFrames,
    ZeroDuration,
    ImageOutOfRange,
};

/// Make sure that `frames` is a valid animation for a sprite with
/// `image_count` frame images.
pub fn validate(frames: []const Frame, image_count: usize) Error!void {
    if (frames.len == 0) return error.NoFrames;
    for (frames) |f| {
        if (f.duration == 0) return error.ZeroDuration;
        if (f.image >= image_count) return error.ImageOutOfRange;
    }
}

/// The time of one full loop: the sum of the frame durations.
pub fn loopLength(frames: []const Frame) u64 {
    var total: u64 = 0;
    for (frames) |f| total += f.duration;
    return total;
}

/// The image that shows at `time`. The animation loops. `frames` must be
/// valid (see `validate`).
pub fn imageAt(frames: []const Frame, time: u64) u32 {
    const length = loopLength(frames);
    if (length == 0) return frames[0].image;
    var t = time % length;
    for (frames) |f| {
        if (t < f.duration) return f.image;
        t -= f.duration;
    }
    unreachable;
}

/// The state of one animated sprite: its frames and the image that the
/// atlas shows now.
pub const Player = struct {
    frames: []const Frame,
    shown: u32,

    /// Start with the image of the first frame. `frames` must be valid
    /// (see `validate`).
    pub fn init(frames: []const Frame) Player {
        return .{ .frames = frames, .shown = frames[0].image };
    }

    /// Go to `time`. Returns the image that must show now if it is not the
    /// image that shows. Returns null if the image does not change.
    pub fn advance(self: *Player, time: u64) ?u32 {
        const image = imageAt(self.frames, time);
        if (image == self.shown) return null;
        self.shown = image;
        return image;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "animation: each frame shows for its duration, then the loop starts again" {
    const frames = [_]Frame{
        .{ .image = 0, .duration = 2 },
        .{ .image = 1, .duration = 3 },
        .{ .image = 2, .duration = 1 },
    };
    try testing.expectEqual(@as(u64, 6), loopLength(&frames));
    const want = [_]u32{ 0, 0, 1, 1, 1, 2, 0, 0, 1, 1, 1, 2, 0 };
    for (want, 0..) |image, t| try testing.expectEqual(image, imageAt(&frames, t));
    // A large time stays in the loop.
    try testing.expectEqual(@as(u32, 2), imageAt(&frames, 6 * 1_000_000_007 + 5));
}

test "animation: frames can show the same image again" {
    const frames = [_]Frame{
        .{ .image = 0, .duration = 1 },
        .{ .image = 1, .duration = 1 },
        .{ .image = 0, .duration = 1 },
        .{ .image = 2, .duration = 1 },
    };
    const want = [_]u32{ 0, 1, 0, 2, 0 };
    for (want, 0..) |image, t| try testing.expectEqual(image, imageAt(&frames, t));
}

test "animation: validate finds bad frames" {
    try testing.expectError(error.NoFrames, validate(&.{}, 1));
    try testing.expectError(error.ZeroDuration, validate(&.{.{ .image = 0, .duration = 0 }}, 1));
    try testing.expectError(error.ImageOutOfRange, validate(&.{.{ .image = 2, .duration = 1 }}, 2));
    try validate(&.{.{ .image = 1, .duration = 1 }}, 2);
}

test "player: advance gives an image only when the image changes" {
    const frames = [_]Frame{
        .{ .image = 0, .duration = 2 },
        .{ .image = 1, .duration = 3 },
    };
    var p = Player.init(&frames);
    try testing.expectEqual(@as(u32, 0), p.shown);
    try testing.expectEqual(@as(?u32, null), p.advance(0));
    try testing.expectEqual(@as(?u32, null), p.advance(1));
    try testing.expectEqual(@as(?u32, 1), p.advance(2));
    try testing.expectEqual(@as(?u32, null), p.advance(3));
    try testing.expectEqual(@as(?u32, null), p.advance(4));
    try testing.expectEqual(@as(?u32, 0), p.advance(5));
    // A jump over many loops goes to the image at that time.
    try testing.expectEqual(@as(?u32, 1), p.advance(5 * 100 + 3));
    try testing.expectEqual(@as(u32, 1), p.shown);
}

test "player: one frame never changes" {
    const frames = [_]Frame{.{ .image = 3, .duration = 7 }};
    var p = Player.init(&frames);
    var t: u64 = 0;
    while (t < 50) : (t += 1) try testing.expectEqual(@as(?u32, null), p.advance(t));
}
