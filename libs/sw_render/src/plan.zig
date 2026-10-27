//! The plan of a frame graph, with no GPU code: render target sizes, the
//! order of the passes, and the checks of the pass attachments.
//!
//! `frame_graph.zig` makes the textures and records the passes. This file
//! holds only the rules, so the tests run with no GPU (REQ-GPU-005).

const std = @import("std");
const gpu_mod = @import("sw_gpu");

const TextureFormat = gpu_mod.TextureFormat;

/// The most render targets in one graph.
pub const max_targets = 16;
/// The most passes in one graph.
pub const max_passes = 32;
/// The most colour attachments in one pass.
pub const max_colors = 4;

/// The handle of one render target. `screen` is the window surface: the
/// graph gets its view at the start of each frame.
pub const TargetId = enum(u8) {
    screen = 0xFF,
    _,

    pub fn index(self: TargetId) usize {
        return @backingInt(self);
    }

    pub fn fromIndex(i: usize) TargetId {
        return @fromBackingInt(@as(u8, @intCast(i)));
    }
};

/// The size of a render target.
pub const Size = union(enum) {
    /// The surface size times this scale, rounded down, and 1 pixel at
    /// minimum. The target changes size when the window changes size.
    surface: f32,
    /// A size in pixels that does not change with the window.
    fixed: Extent,
};

pub const Extent = struct {
    width: u32,
    height: u32,

    pub fn eql(a: Extent, b: Extent) bool {
        return a.width == b.width and a.height == b.height;
    }
};

/// One render target: a texture that the graph owns.
pub const TargetDesc = struct {
    /// A name to find the target with `FrameGraph.findTarget`. The string
    /// must stay valid while the graph exists (use a literal).
    name: []const u8,
    format: TextureFormat,
    size: Size = .{ .surface = 1.0 },
    sample_count: u32 = 1,
    /// Render attachment and texture binding: a later pass can sample it.
    usage: gpu_mod.TextureUsage = .{ .render_attachment = true, .texture_binding = true },
};

/// One colour attachment of a pass.
pub const ColorAttachment = struct {
    target: TargetId,
    /// A target with sample count 1 that gets the resolved samples of a
    /// multisampled `target`.
    resolve: ?TargetId = null,
    load_op: gpu_mod.LoadOp = .clear,
    store_op: gpu_mod.StoreOp = .store,
    clear_value: gpu_mod.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
};

/// The depth attachment of a pass. Many passes can use one depth target:
/// the first pass clears it, and the subsequent passes load it.
pub const DepthAttachment = struct {
    target: TargetId,
    load_op: gpu_mod.LoadOp = .clear,
    store_op: gpu_mod.StoreOp = .store,
    clear_value: f32 = 1.0,
    read_only: bool = false,
};

/// The attachments of one pass. A pass with no attachments gets the
/// command encoder only, for copies.
pub const Attachments = struct {
    colors: []const ColorAttachment = &.{},
    depth: ?DepthAttachment = null,
};

/// What the plan must know about one target to check a pass.
pub const TargetInfo = struct {
    format: TextureFormat,
    size: Extent,
    sample_count: u32,
};

pub const Error = error{
    UnknownTarget,
    DuplicateTargetName,
    TooManyTargets,
    TooManyPasses,
    TooManyColors,
    DepthFormatAsColor,
    ColorFormatAsDepth,
    ScreenAsDepth,
    SizeMismatch,
    SampleCountMismatch,
    BadResolve,
};

/// True for a format with a depth aspect.
pub fn isDepthFormat(format: TextureFormat) bool {
    return switch (format) {
        .depth16unorm, .depth24plus, .depth24plus_stencil8, .depth32float, .depth32float_stencil8 => true,
        else => false,
    };
}

/// True for a format with a stencil aspect.
pub fn hasStencil(format: TextureFormat) bool {
    return switch (format) {
        .depth24plus_stencil8, .depth32float_stencil8 => true,
        else => false,
    };
}

/// The size in pixels of a target for a surface of `surface` pixels.
pub fn resolveSize(size: Size, surface: Extent) Extent {
    return switch (size) {
        .fixed => |e| .{ .width = @max(e.width, 1), .height = @max(e.height, 1) },
        .surface => |scale| .{
            .width = scaled(surface.width, scale),
            .height = scaled(surface.height, scale),
        },
    };
}

fn scaled(edge: u32, scale: f32) u32 {
    const v = @as(f32, @floatFromInt(edge)) * scale;
    if (!(v >= 1.0)) return 1;
    if (v >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// Write the pass indices to `out` in the order that the passes run: by
/// `order`, from low to high. Passes with the same `order` run in the
/// sequence that the game added them (REQ-GPU-005).
pub fn sortPasses(orders: []const i32, out: []u8) void {
    std.debug.assert(out.len >= orders.len);
    for (0..orders.len) |i| out[i] = @intCast(i);
    // Insertion sort: stable, and the list is short.
    var i: usize = 1;
    while (i < orders.len) : (i += 1) {
        const item = out[i];
        var j = i;
        while (j > 0 and orders[out[j - 1]] > orders[item]) : (j -= 1) {
            out[j] = out[j - 1];
        }
        out[j] = item;
    }
}

/// Check the attachments of one pass. `targets` gives each target by its
/// index. `screen` gives the surface. All attachments of a pass must have
/// the same size and sample count. A resolve target has sample count 1.
pub fn checkPass(att: Attachments, targets: []const TargetInfo, screen: TargetInfo) Error!void {
    if (att.colors.len > max_colors) return error.TooManyColors;

    var first: ?TargetInfo = null;
    for (att.colors) |c| {
        const t = try lookup(c.target, targets, screen);
        if (isDepthFormat(t.format)) return error.DepthFormatAsColor;
        try same(&first, t);
        if (c.resolve) |r| {
            const rt = try lookup(r, targets, screen);
            if (t.sample_count == 1 or rt.sample_count != 1) return error.BadResolve;
            if (rt.format != t.format) return error.BadResolve;
            if (!rt.size.eql(t.size)) return error.SizeMismatch;
        }
    }
    if (att.depth) |d| {
        if (d.target == .screen) return error.ScreenAsDepth;
        const t = try lookup(d.target, targets, screen);
        if (!isDepthFormat(t.format)) return error.ColorFormatAsDepth;
        try same(&first, t);
    }
}

fn lookup(id: TargetId, targets: []const TargetInfo, screen: TargetInfo) Error!TargetInfo {
    if (id == .screen) return screen;
    if (id.index() >= targets.len) return error.UnknownTarget;
    return targets[id.index()];
}

fn same(first: *?TargetInfo, t: TargetInfo) Error!void {
    if (first.*) |f| {
        if (!f.size.eql(t.size)) return error.SizeMismatch;
        if (f.sample_count != t.sample_count) return error.SampleCountMismatch;
    } else first.* = t;
}

/// True when `att` uses the window surface.
pub fn usesScreen(att: Attachments) bool {
    for (att.colors) |c| {
        if (c.target == .screen) return true;
        if (c.resolve) |r| if (r == .screen) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "plan: passes run by order, and equal orders keep the add sequence (REQ-GPU-005)" {
    const orders = [_]i32{ 10, -5, 10, 0, -5, 3 };
    var out: [orders.len]u8 = undefined;
    sortPasses(&orders, &out);
    try testing.expectEqualSlices(u8, &.{ 1, 4, 3, 5, 0, 2 }, &out);

    // One pass and no passes.
    var one: [1]u8 = undefined;
    sortPasses(&.{7}, &one);
    try testing.expectEqual(@as(u8, 0), one[0]);
    sortPasses(&.{}, &.{});
}

test "plan: a surface target follows the surface size (REQ-GPU-005)" {
    const full: Size = .{ .surface = 1.0 };
    const half: Size = .{ .surface = 0.5 };
    const fixed: Size = .{ .fixed = .{ .width = 256, .height = 128 } };

    try testing.expectEqual(Extent{ .width = 800, .height = 600 }, resolveSize(full, .{ .width = 800, .height = 600 }));
    try testing.expectEqual(Extent{ .width = 1920, .height = 1080 }, resolveSize(full, .{ .width = 1920, .height = 1080 }));
    try testing.expectEqual(Extent{ .width = 400, .height = 300 }, resolveSize(half, .{ .width = 800, .height = 600 }));
    // Odd edges round down.
    try testing.expectEqual(Extent{ .width = 400, .height = 300 }, resolveSize(half, .{ .width = 801, .height = 601 }));
    // A target is 1 pixel at minimum.
    try testing.expectEqual(Extent{ .width = 1, .height = 1 }, resolveSize(half, .{ .width = 1, .height = 0 }));
    // A fixed target does not change with the surface.
    try testing.expectEqual(Extent{ .width = 256, .height = 128 }, resolveSize(fixed, .{ .width = 800, .height = 600 }));
    try testing.expectEqual(Extent{ .width = 256, .height = 128 }, resolveSize(fixed, .{ .width = 10, .height = 10 }));
}

test "plan: checkPass accepts good attachments" {
    const screen: TargetInfo = .{ .format = .bgra8unorm, .size = .{ .width = 800, .height = 600 }, .sample_count = 1 };
    const targets = [_]TargetInfo{
        .{ .format = .rgba16float, .size = screen.size, .sample_count = 1 },
        .{ .format = .depth24plus, .size = screen.size, .sample_count = 1 },
        .{ .format = .rgba16float, .size = screen.size, .sample_count = 4 },
        .{ .format = .depth32float, .size = screen.size, .sample_count = 4 },
    };
    const hdr = TargetId.fromIndex(0);
    const depth = TargetId.fromIndex(1);
    const msaa = TargetId.fromIndex(2);
    const msaa_depth = TargetId.fromIndex(3);

    try checkPass(.{ .colors = &.{.{ .target = .screen }} }, &targets, screen);
    try checkPass(.{ .colors = &.{.{ .target = hdr }}, .depth = .{ .target = depth } }, &targets, screen);
    try checkPass(.{ .colors = &.{.{ .target = msaa, .resolve = hdr }}, .depth = .{ .target = msaa_depth } }, &targets, screen);
    // A depth-only pass, as for a shadow map.
    try checkPass(.{ .depth = .{ .target = depth } }, &targets, screen);
    // A pass with no attachments.
    try checkPass(.{}, &targets, screen);

    try testing.expect(usesScreen(.{ .colors = &.{.{ .target = .screen }} }));
    try testing.expect(!usesScreen(.{ .colors = &.{.{ .target = hdr }} }));
}

test "plan: checkPass refuses bad attachments" {
    const screen: TargetInfo = .{ .format = .bgra8unorm, .size = .{ .width = 800, .height = 600 }, .sample_count = 1 };
    const targets = [_]TargetInfo{
        .{ .format = .rgba16float, .size = screen.size, .sample_count = 1 },
        .{ .format = .depth24plus, .size = screen.size, .sample_count = 1 },
        .{ .format = .rgba16float, .size = .{ .width = 400, .height = 300 }, .sample_count = 1 },
        .{ .format = .rgba16float, .size = screen.size, .sample_count = 4 },
    };
    const hdr = TargetId.fromIndex(0);
    const depth = TargetId.fromIndex(1);
    const half = TargetId.fromIndex(2);
    const msaa = TargetId.fromIndex(3);
    const missing = TargetId.fromIndex(9);

    try testing.expectError(error.UnknownTarget, checkPass(.{ .colors = &.{.{ .target = missing }} }, &targets, screen));
    try testing.expectError(error.DepthFormatAsColor, checkPass(.{ .colors = &.{.{ .target = depth }} }, &targets, screen));
    try testing.expectError(error.ColorFormatAsDepth, checkPass(.{ .depth = .{ .target = hdr } }, &targets, screen));
    try testing.expectError(error.ScreenAsDepth, checkPass(.{ .depth = .{ .target = .screen } }, &targets, screen));
    try testing.expectError(error.SizeMismatch, checkPass(.{ .colors = &.{.{ .target = half }}, .depth = .{ .target = depth } }, &targets, screen));
    try testing.expectError(error.SampleCountMismatch, checkPass(.{ .colors = &.{ .{ .target = hdr }, .{ .target = msaa } } }, &targets, screen));
    // A resolve needs a multisampled source and a single-sampled target.
    try testing.expectError(error.BadResolve, checkPass(.{ .colors = &.{.{ .target = hdr, .resolve = hdr }} }, &targets, screen));
    try testing.expectError(error.BadResolve, checkPass(.{ .colors = &.{.{ .target = msaa, .resolve = msaa }} }, &targets, screen));
    // Five colour attachments.
    const five: [5]ColorAttachment = @splat(.{ .target = hdr });
    try testing.expectError(error.TooManyColors, checkPass(.{ .colors = &five }, &targets, screen));
}

test "plan: depth and stencil formats" {
    try testing.expect(isDepthFormat(.depth24plus));
    try testing.expect(isDepthFormat(.depth32float_stencil8));
    try testing.expect(!isDepthFormat(.rgba8unorm));
    try testing.expect(hasStencil(.depth24plus_stencil8));
    try testing.expect(!hasStencil(.depth24plus));
}
