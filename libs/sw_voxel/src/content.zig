//! The content contract of sw_voxel. The game gives its block types, the
//! light of each block and its terrain generator in a module, and sw_voxel
//! imports that module as `sw_voxel_content`. sw_voxel knows no block name
//! and no generator. The content module can import `sw_voxel` for the chunk
//! sizes and `DenseBlocks`.
//!
//! Wiring in a build.zig:
//!
//!   const voxel = dep.module("sw_voxel");
//!   const content = b.createModule(.{ .root_source_file = b.path("content.zig") });
//!   voxel.addImport("sw_voxel_content", content);
//!   content.addImport("sw_voxel", voxel);
//!
//! The content module must declare:
//!
//!   pub const Block = enum(u8) { air = 0, ... };
//!       The block types. `air` (value 0) is the empty cell: it gives no
//!       light, stops no light, and has no faces. A block with no model is
//!       a full cube.
//!   pub fn emission(block: Block) u8
//!       The block light that `block` gives, 0 to `chunk.MAX_BLOCK_LIGHT`.
//!       `air` must give 0. sw_voxel calls it at comptime for each block
//!       type, so the result must be comptime-known.
//!   pub const GenConfig = struct { seed: u64, ... };
//!       The settings of the generator. The pipeline sends it to each
//!       chunk worker in the Hello message.
//!   pub const GEN_CONFIG_LEN: usize
//!   pub fn encodeGenConfig(config: GenConfig, out: *[GEN_CONFIG_LEN]u8) void
//!   pub fn decodeGenConfig(bytes: *const [GEN_CONFIG_LEN]u8) error{BadField}!GenConfig
//!       The bytes of a GenConfig without the seed. The Hello holds the seed.
//!   pub fn generate(dense: *chunk.DenseBlocks, cx: i32, cz: i32, config: GenConfig) void
//!       Write all the blocks of chunk (cx, cz). The result must be a pure
//!       function of the arguments (P2): the chunk workers and
//!       main must make the same blocks. The y index of `dense` starts at
//!       0 for the world y `min_y`.
//!
//! The content module can declare the models of its blocks
//! (REQ-VOXEL-001). With no declaration, every block is a full cube:
//!
//!   pub fn model(block: Block) ?*const sw_voxel.model.BakedModel
//!       The baked model of `block`, or null for a full cube. sw_voxel
//!       calls it at comptime for each block type, so the result must be
//!       comptime-known. The model mesher meshes a block with a model, and
//!       the greedy mesher meshes the full cubes. For ambient occlusion, a
//!       block with a model is the same as a full cube. For light, it has
//!       the `opacity` of its block ID.
//!
//! The content module can declare the opacity of its blocks
//! (REQ-VOXEL-003). With no declaration, `air` has opacity 0 and every
//! other block has opacity 15:
//!
//!   pub fn opacity(block: Block) u8
//!       The light that a cell of `block` stops, 0 to 15. Light that goes
//!       into the cell loses max(1, opacity) levels, so opacity 15 stops
//!       all light, and opacity 0 lets light through like air. Sky light
//!       goes straight down with no loss only through cells with opacity
//!       0. `air` must have opacity 0. sw_voxel calls it at comptime for
//!       each block type, so the result must be comptime-known. Give a
//!       slab or a plant a low opacity, so that the face of a full cube
//!       next to it gets light.
//!
//! The content module can declare the collision boxes of its blocks
//! (REQ-VOXEL-006). With no declaration, `air` has no box and every other
//! block is a full cube:
//!
//!   pub fn collision(block: Block) ?[]const sw_voxel.collision.CellBox
//!       The collision boxes of `block` in block units, or null for the
//!       default. Each box must be in the cell: [0, 1] on each axis. An
//!       empty slice gives a block with no collision, for example a plant.
//!       `air` must give null or an empty slice. sw_voxel calls it at
//!       comptime for each block type, so the result must be
//!       comptime-known. The collision boxes are separate from the model.
//!       The moving boxes and the ray cast of `collision.zig` use them.
//!
//! The content module can declare tint colours (REQ-VOXEL-009). With no
//! declaration, no quad has a tint:
//!
//!   pub fn tint(block: Block, tint_index: u8, x: i32, y: i32, z: i32) [3]u8
//!       The tint colour (red, green, blue, 0 to 255) of a quad with tint
//!       index `tint_index` of `block` in the world cell (x, y, z). The
//!       shader multiplies the colour of the quad by tint / 255. The
//!       result must be a pure function of the arguments (P2): the chunk
//!       workers and main must make the same mesh. A model quad gets its
//!       tint index from its `BakedQuad.tint_index`.
//!   pub fn tintIndex(block: Block, face: sw_voxel.model.Face) i8
//!       The tint index of one face of a full cube, or -1 for no tint.
//!       sw_voxel calls it at comptime for each block type and face, so
//!       the result must be comptime-known. With no declaration, no full
//!       cube has a tint. It needs `tint`.
//!
//! The content module can declare fluids (REQ-VOXEL-014). With no
//! declaration, no block is a fluid:
//!
//!   pub fn fluid(block: Block) ?sw_voxel.fluid.Level
//!       The fluid and the level of `block`, or null for a block that is
//!       not a fluid. Give one block ID for each level of a fluid. The
//!       level is 1 to 8, and 8 is a full cell. sw_voxel calls it at
//!       comptime for each block type, so the result must be
//!       comptime-known. The greedy mesher does not mesh a fluid block.
//!       `fluid.generate` meshes it. A fluid block must not have a model.
//!       Give it an `opacity` and a `collision` too: the defaults are
//!       the values of a full cube.
//!
//! The content module can declare translucent blocks (REQ-VOXEL-029).
//! With no declaration, no block is translucent:
//!
//!   pub fn translucent(block: Block) ?[4]u8
//!       The colour (red, green, blue, alpha, 0 to 255, straight alpha)
//!       of the translucent block `block`, or null. A translucent block is
//!       a cell with 6 faces in the translucent stream of the mesh
//!       (`translucent.generate`). It is not a full cube: the greedy
//!       mesher skips it, and the faces of the blocks next to it show. It
//!       does not darken AO. sw_voxel calls it at comptime for each block
//!       type, so the result must be comptime-known. A translucent block
//!       must not have a model and must not be a fluid. Give it an
//!       `opacity` too: the default is the value of a full cube.
//!
//! The content module can declare the height of the world. With no
//! declaration, the world is y 0 to 255:
//!
//!   pub const min_y: i32
//!       The lowest world y. A multiple of 16. Default 0.
//!   pub const height: u32
//!       The number of cells in a column: a multiple of 16, 16 to 4096.
//!       Default 256. The world is y `min_y` to `min_y + height - 1`.
const std = @import("std");
const c = @import("sw_voxel_content");
const model_mod = @import("model.zig");
const collision_mod = @import("collision.zig");
const fluid_mod = @import("fluid.zig");

pub const Block = c.Block;
pub const GenConfig = c.GenConfig;
pub const GEN_CONFIG_LEN: usize = c.GEN_CONFIG_LEN;
pub const encodeGenConfig = c.encodeGenConfig;
pub const decodeGenConfig = c.decodeGenConfig;
pub const generate = c.generate;

/// The lowest world y.
pub const min_y: i32 = if (@hasDecl(c, "min_y")) c.min_y else 0;
/// The number of cells in a column, 16 cells per section.
pub const height: u32 = if (@hasDecl(c, "height")) c.height else 256;

/// The block light that `block` gives.
pub inline fn emission(block: Block) u8 {
    return c.emission(block);
}

/// The light that a cell of `block` stops, 0 to 15 (REQ-VOXEL-003). With
/// no `opacity` in the content, `air` is 0 and all other blocks are 15.
pub inline fn opacity(block: Block) u8 {
    if (@hasDecl(c, "opacity")) return c.opacity(block);
    return if (block == .air) 0 else 15;
}

/// The baked model of `block`, or null for a full cube. Comptime only:
/// the mesher uses the tables of `models.zig`.
pub fn model(comptime block: Block) ?*const model_mod.BakedModel {
    return if (@hasDecl(c, "model")) c.model(block) else null;
}

/// The collision boxes of `block`, or null for the default (REQ-VOXEL-006).
/// Comptime only: `collision.zig` makes a table.
pub fn collision(comptime block: Block) ?[]const collision_mod.CellBox {
    return if (@hasDecl(c, "collision")) c.collision(block) else null;
}

/// The fluid and the level of `block`, or null (REQ-VOXEL-014). Comptime
/// only: `fluid.zig` makes a table.
pub fn fluid(comptime block: Block) ?fluid_mod.Level {
    return if (@hasDecl(c, "fluid")) c.fluid(block) else null;
}

/// The colour of the translucent block `block`, or null (REQ-VOXEL-029).
/// Comptime only: `translucent.zig` makes a table.
pub fn translucent(comptime block: Block) ?[4]u8 {
    return if (@hasDecl(c, "translucent")) c.translucent(block) else null;
}

/// True when the content gives tint colours (REQ-VOXEL-009).
pub const has_tint: bool = @hasDecl(c, "tint");

/// The tint colour of a quad with tint index `tint_index` of `block` in
/// the world cell (x, y, z). Call it only when `has_tint` is true.
pub inline fn tint(block: Block, tint_index: u8, x: i32, y: i32, z: i32) [3]u8 {
    return c.tint(block, tint_index, x, y, z);
}

/// The tint index of one face of a full cube, or -1. Comptime only: the
/// mesher uses the table of `models.zig`.
pub fn tintIndex(comptime block: Block, comptime face: model_mod.Face) i8 {
    return if (@hasDecl(c, "tintIndex")) c.tintIndex(block, face) else -1;
}

comptime {
    if (@hasDecl(c, "tintIndex") and !has_tint)
        @compileError("sw_voxel_content.tintIndex needs sw_voxel_content.tint");
}

comptime {
    const info = @typeInfo(Block);
    if (info != .@"enum" or info.@"enum".tag_type != u8)
        @compileError("sw_voxel_content.Block must be an enum(u8)");
    if (!@hasField(Block, "air") or @backingInt(Block.air) != 0)
        @compileError("sw_voxel_content.Block must have air = 0");
    if (!@hasField(GenConfig, "seed") or @FieldType(GenConfig, "seed") != u64)
        @compileError("sw_voxel_content.GenConfig must have a field seed: u64");
    if (height < 16 or height > 4096 or height % 16 != 0)
        @compileError("sw_voxel_content.height must be a multiple of 16, 16 to 4096");
    if (@mod(min_y, 16) != 0)
        @compileError("sw_voxel_content.min_y must be a multiple of 16");
    @setEvalBranchQuota(100_000);
    for (info.@"enum".field_values) |v| {
        const b: Block = @fromBackingInt(v);
        if (opacity(b) > 15) @compileError("sw_voxel_content.opacity must be 0 to 15");
        if (emission(b) > 15) @compileError("sw_voxel_content.emission must be 0 to 15");
    }
    if (opacity(.air) != 0) @compileError("sw_voxel_content.opacity(.air) must be 0");
    if (emission(.air) != 0) @compileError("sw_voxel_content.emission(.air) must be 0");
}
