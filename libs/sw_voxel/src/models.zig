//! The models of the content blocks as tables (REQ-VOXEL-001). sw_voxel
//! makes the tables at comptime from `content.model`: the quads of all
//! models in one list, the quads of each block ID, and the same list in the
//! GPU format.
//!
//! The game uploads `gpu_table` one time as a storage buffer. A model quad
//! record of a chunk mesh holds an index into it (`mesher.zig`).
const std = @import("std");
const content = @import("content.zig");
const model = @import("model.zig");

const Block = content.Block;
const block_values = @typeInfo(Block).@"enum".field_values;

/// The quads of one block ID in `quads`: `count` quads from `first`.
pub const Range = struct {
    first: u16 = 0,
    count: u16 = 0,
};

const Tables = struct {
    has_model: [256]bool,
    ranges: [256]Range,
    quad_count: usize,
};

const tables: Tables = blk: {
    @setEvalBranchQuota(100_000);
    var t: Tables = .{ .has_model = @splat(false), .ranges = @splat(.{}), .quad_count = 0 };
    for (block_values) |v| {
        const block: Block = @fromBackingInt(v);
        if (content.model(block)) |m| {
            if (block == .air) @compileError("sw_voxel_content.model(.air) must be null");
            if (t.quad_count + m.quads.len > std.math.maxInt(u16))
                @compileError("sw_voxel_content: the models have more than 65535 quads");
            t.has_model[v] = true;
            t.ranges[v] = .{ .first = t.quad_count, .count = m.quads.len };
            t.quad_count += m.quads.len;
        }
    }
    break :blk t;
};

/// True when the content gives a model for one or more blocks.
pub const any: bool = blk: {
    for (tables.has_model) |h| if (h) break :blk true;
    break :blk false;
};

/// The quads of all models, in block ID order.
pub const quads: [tables.quad_count]model.BakedQuad = blk: {
    @setEvalBranchQuota(100_000);
    var out: [tables.quad_count]model.BakedQuad = undefined;
    var n: usize = 0;
    for (block_values) |v| {
        const block: Block = @fromBackingInt(v);
        if (content.model(block)) |m| {
            for (m.quads) |q| {
                out[n] = q;
                n += 1;
            }
        }
    }
    break :blk out;
};

/// `quads` in the GPU format (`model.GpuQuad`). It has one zero quad when
/// the content has no models, because a storage buffer must not be empty.
pub const gpu_table: [@max(tables.quad_count, 1)]model.GpuQuad = blk: {
    @setEvalBranchQuota(100_000);
    var out: [@max(tables.quad_count, 1)]model.GpuQuad = @splat(.{ .words = @splat(0) });
    for (quads, 0..) |q, i| out[i] = model.encodeGpu(q);
    break :blk out;
};

/// The bytes of `gpu_table`, for one upload to a storage buffer.
pub fn gpuTableBytes() []const u8 {
    return std.mem.sliceAsBytes(&gpu_table);
}

/// True when `block` has a model.
pub fn hasModel(block: Block) bool {
    if (!any) return false;
    return tables.has_model[@backingInt(block)];
}

/// True when `block` is a full cube: not air and no model. A full cube
/// hides the face of its neighbour, and the greedy mesher meshes it.
pub fn isCube(block: Block) bool {
    return block != .air and !hasModel(block);
}

/// The quads of `block` in `quads`.
pub inline fn range(block: Block) Range {
    return tables.ranges[@backingInt(block)];
}
