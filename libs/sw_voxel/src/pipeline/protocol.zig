//! The chunk protocol: the bytes that go between main and a chunk worker
//! (C4 option b, P6).
//!
//! Main sends `Hello`, `Edit` and `Job` messages. A worker sends `Hello`,
//! `Result` and `Error` messages. The Inline executor, the ThreadPool
//! executor and the Web Workers use the same bytes. So the native tests
//! also test the web format (P6).
//!
//! Rules of the format:
//!
//! - No pointers. Each field has a fixed offset, and each size is explicit.
//! - All integers are little-endian. An f32 is its IEEE 754 bits as a u32.
//! - Each message starts with a header of 16 bytes: a magic number, the
//!   protocol version, the message kind, the body length and an id.
//! - A `Result` payload starts at byte 64, so the PackedQuad bytes of a
//!   mesh are 16-byte aligned in the message, ready for upload (C5). Main
//!   reads only the first 64 bytes of a mesh Result. The quad count, the y
//!   range and a hash of the quads are in them. Main gives the quad bytes to
//!   the GPU and does not copy them (C5).
//!
//! Header (16 bytes):
//!
//!   0  u32  magic: MAGIC ("VXCP")
//!   4  u16  protocol version: VERSION
//!   6  u8   kind: Kind
//!   7  u8   reserved, 0
//!   8  u32  body length in bytes (the message length less 16)
//!   12 u32  id: the job id of a Job, a Result or an Error, else 0
//!
//! docs/chunk-pipeline.md has the layout of each body.
const std = @import("std");
const builtin = @import("builtin");
const chunk_mod = @import("../chunk.zig");
const mesher_mod = @import("../mesher.zig");
const fluid_mod = @import("../fluid.zig");
const translucent_mod = @import("../translucent.zig");
const content = @import("../content.zig");
const stages = @import("stages.zig");
const lod = @import("lod.zig");

const BlockType = chunk_mod.BlockType;
const PalettedBlocks = chunk_mod.PalettedBlocks;
const Section = chunk_mod.Section;
pub const PackedQuad = mesher_mod.PackedQuad;
pub const FluidVertex = fluid_mod.Vertex;
/// The bytes of one fluid quad in a mesh payload: 4 `fluid.Vertex`.
pub const FLUID_QUAD_LEN = 4 * @sizeOf(FluidVertex);
pub const TranslucentVertex = translucent_mod.Vertex;
/// The bytes of one translucent quad in a mesh payload: 4
/// `translucent.Vertex`.
pub const TRANSLUCENT_QUAD_LEN = 4 * @sizeOf(TranslucentVertex);
/// The bytes of the centre of one translucent quad: 3 f32.
pub const CENTER_LEN = 12;
pub const Stage = stages.Stage;
pub const Version = stages.Version;
pub const SLOTS = stages.SLOTS;

/// "VXCP" as little-endian bytes.
pub const MAGIC: u32 = 0x50435856;
/// Increment this value for each change of the layout.
pub const VERSION: u16 = 8;

pub const HEADER_LEN = 16;
pub const HELLO_LEN = 24 + content.GEN_CONFIG_LEN;
pub const EDIT_LEN = 16;
pub const JOB_LEN = 88;
/// The length of the section connections of a mesh Result (REQ-VOXEL-019):
/// one u16 for each section, to a multiple of 16 bytes.
pub const SECTION_COUNT = chunk_mod.SECTION_COUNT;
pub const SECTIONS_LEN = std.mem.alignForward(usize, chunk_mod.SECTION_COUNT * 2, 16);
/// The length of the draw ranges of a mesh Result (REQ-VOXEL-023): one u32
/// (`mesher.SectionRange`) for each section, to a multiple of 16 bytes.
pub const RANGES_LEN = std.mem.alignForward(usize, chunk_mod.SECTION_COUNT * 4, 16);
pub const RESULT_HEAD_LEN = 48 + SECTIONS_LEN + RANGES_LEN;
pub const ERROR_HEAD_LEN = 16;
/// The offset of a Result payload in the message.
pub const PAYLOAD_OFFSET = HEADER_LEN + RESULT_HEAD_LEN;
/// The offset of the mesh hash of a Result in the message.
pub const MESH_HASH_OFFSET = HEADER_LEN + 32;
/// The longest Error text that a message can hold.
pub const MAX_ERROR_TEXT = 256;

/// The build hash of this build. A worker from another build has another
/// hash, and the Hello handshake stops it (C9). It covers the protocol
/// version and the sizes that the stages use.
pub const BUILD_HASH: u64 = blk: {
    var h = std.hash.Wyhash.init(0);
    const parts = [_]u64{ VERSION, chunk_mod.CHUNK_W, chunk_mod.CHUNK_H, @bitCast(@as(i64, chunk_mod.MIN_Y)), @sizeOf(PackedQuad), SLOTS, std.enums.values(BlockType).len, @sizeOf(FluidVertex), @sizeOf(TranslucentVertex) };
    for (parts) |p| h.update(std.mem.asBytes(&p));
    break :blk h.final();
};

comptime {
    std.debug.assert(PAYLOAD_OFFSET % 16 == 0);
    // Edit stores local x and z in 4 bits each, and local y in a u16.
    std.debug.assert(chunk_mod.CHUNK_W == 16 and chunk_mod.CHUNK_H <= 65536);
    std.debug.assert(@sizeOf(PackedQuad) == 16);
    // The fluid quads keep the next stream 16-byte aligned.
    std.debug.assert(FLUID_QUAD_LEN % 16 == 0);
    std.debug.assert(TRANSLUCENT_QUAD_LEN % 16 == 0);
}

pub const Kind = enum(u8) {
    hello = 1,
    edit = 2,
    job = 3,
    result = 4,
    err = 5,
};

// ---------------------------------------------------------------------------
// Message bodies
// ---------------------------------------------------------------------------

/// The first message in each direction. Main sends the world: the generator
/// settings of the content with the seed, and the cache limit of the worker
/// (C14). The worker answers with its own build hash.
///
/// Body (24 + content.GEN_CONFIG_LEN bytes):
///
///   0  u64  build hash
///   8  u64  seed
///   16 u64  cache limit in bytes
///   24 ...  the generator settings without the seed
///           (content.encodeGenConfig)
pub const Hello = struct {
    build_hash: u64 = BUILD_HASH,
    cache_limit: u64,
    config: content.GenConfig,
};

/// One block edit (P2). Main sends each edit to each worker, in the order of
/// the edits. `version` is the block version of the chunk after the edit.
///
/// Body (16 bytes):
///
///   0  i32  cx
///   4  i32  cz
///   8  u32  block version after the edit
///   12 u16  y (local, 0..CHUNK_H - 1)
///   14 u8   x | z << 4 (local, 0..15 each)
///   15 u8   block type
pub const Edit = struct {
    cx: i32,
    cz: i32,
    version: Version,
    /// The local cell. y is local: world y is y + chunk.MIN_Y.
    x: u8,
    y: u16,
    z: u8,
    block: BlockType,
};

/// One stage for one chunk. The versions are the versions of the inputs
/// on main when the job started (C3), by slot of the 3×3 neighbourhood.
///
/// Body (88 bytes):
///
///   0  u8      stage
///   1  u8      AO strategy (mesh)
///   2  u8      lighting mode (mesh)
///   3  u8      flags: bit 0 = send the blocks back (generate),
///              bit 1 = flat light, smooth light off (mesh)
///   4  i32     cx
///   8  i32     cz
///   12 u8      level of detail, 0 to lod.MAX_LEVEL (mesh, REQ-VOXEL-021)
///   13 u8      reserved, 0
///   14 u16     reserved, 0
///   16 u32×9   block versions
///   52 u32×9   light versions
pub const Job = struct {
    stage: Stage,
    cx: i32,
    cz: i32,
    ao: stages.AOStrategy = .none,
    lighting: stages.LightingMode = .none,
    /// Generate: the Result also holds the blocks, for the simulation
    /// radius of main (C6).
    want_blocks: bool = false,
    /// Mesh: false gives flat light (REQ-VOXEL-008).
    smooth_light: bool = true,
    /// Mesh: the level of detail, 0 to `lod.MAX_LEVEL` (REQ-VOXEL-021).
    lod: u8 = 0,
    blocks: [SLOTS]Version = @splat(0),
    light: [SLOTS]Version = @splat(0),
};

/// The fixed part of a Result.
///
/// Body (RESULT_HEAD_LEN bytes, then the payload):
///
///   0  u8   stage
///   1  u8   flags: bit 0 = the payload holds blocks
///   2  u16  reserved, 0
///   4  i32  cx
///   8  i32  cz
///   12 u32  block version of the chunk
///   16 u64  light: the light hash. mesh: y min (f32) at 16, y max (f32) at 20
///   24 u32  mesh: the quad count. generate: the payload length. light: 0
///   28 u32  job time in µs, or 0
///   32 u64  mesh: meshHash of the payload. generate and light: 0
///   40 u32  mesh: the fluid quad count (REQ-VOXEL-027). generate and
///           light: 0
///   44 u32  mesh: the translucent quad count (REQ-VOXEL-030). generate
///           and light: 0
///   48 u16  mesh: the face connections of each section (visibility.zig),
///           SECTION_COUNT values, then 0 to a multiple of 16 bytes
///           (SECTIONS_LEN). generate and light: 0
///   48 + SECTIONS_LEN  u32  mesh: the draw range of each section
///           (mesher.SectionRange), SECTION_COUNT values, then 0 to a
///           multiple of 16 bytes (RANGES_LEN). generate and light: 0
///   48 + SECTIONS_LEN + RANGES_LEN ...  payload: mesh: PackedQuad × count,
///           then fluid.Vertex × 4 × the fluid quad count, then
///           translucent.Vertex × 4 × the translucent quad count, then the
///           centre (3 f32) of each translucent quad. generate: the blocks
pub const ResultHead = struct {
    stage: Stage,
    cx: i32,
    cz: i32,
    block_ver: Version = 0,
    light_hash: u64 = 0,
    y_min: f32 = 0,
    y_max: f32 = 0,
    job_us: u32 = 0,
    /// Mesh: meshHash of the quad bytes. The encoder calculates it.
    mesh_hash: u64 = 0,
    /// Mesh: the face connections of each section (REQ-VOXEL-019).
    sections: [chunk_mod.SECTION_COUNT]u16 = @splat(0x7FFF),
    /// Mesh: the draw range of each section (REQ-VOXEL-023).
    ranges: mesher_mod.SectionRanges = mesher_mod.EMPTY_RANGES,
    /// Mesh: the fluid quads after the PackedQuads (REQ-VOXEL-027). The
    /// encoder sets it from the payload.
    fluid_quads: u32 = 0,
    /// Mesh: the translucent quads after the fluid quads (REQ-VOXEL-030).
    /// The encoder sets it from the payload.
    translucent_quads: u32 = 0,
};

/// The hash of the quad bytes of a mesh. The worker calculates it, so main
/// can compare meshes without the bytes (C5). Equal quads give an equal hash.
pub fn meshHash(quad_bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x4D45_5348, quad_bytes);
}

/// The fixed part of a Result, from the first PAYLOAD_OFFSET bytes of the
/// message (`decodeResultHead`). It does not include the payload.
pub const ResultInfo = struct {
    id: u32,
    head: ResultHead,
    has_blocks: bool,
    /// The payload length that the header gives.
    payload_len: usize,
    /// Mesh: the quad count.
    quad_count: u32,

    /// Mesh: the offset of the fluid vertices in the message.
    pub fn fluidOffset(self: ResultInfo) usize {
        return PAYLOAD_OFFSET + @as(usize, self.quad_count) * @sizeOf(PackedQuad);
    }

    /// Mesh: the length of the fluid vertices.
    pub fn fluidLen(self: ResultInfo) usize {
        return @as(usize, self.head.fluid_quads) * FLUID_QUAD_LEN;
    }

    /// Mesh: the offset of the translucent vertices in the message.
    pub fn translucentOffset(self: ResultInfo) usize {
        return self.fluidOffset() + self.fluidLen();
    }

    /// Mesh: the length of the translucent vertices.
    pub fn translucentLen(self: ResultInfo) usize {
        return @as(usize, self.head.translucent_quads) * TRANSLUCENT_QUAD_LEN;
    }

    /// Mesh: the offset of the translucent quad centres in the message.
    pub fn centersOffset(self: ResultInfo) usize {
        return self.translucentOffset() + self.translucentLen();
    }

    /// Mesh: the length of the translucent quad centres.
    pub fn centersLen(self: ResultInfo) usize {
        return @as(usize, self.head.translucent_quads) * CENTER_LEN;
    }
};

/// The streams of a mesh Result.
pub const MeshPayload = struct {
    quads: []const PackedQuad,
    /// 4 vertices for each fluid quad (REQ-VOXEL-027).
    fluid: []const FluidVertex = &.{},
    /// 4 vertices for each translucent quad (REQ-VOXEL-030).
    translucent: []const TranslucentVertex = &.{},
    /// The centre of each translucent quad.
    centers: []const [3]f32 = &.{},
};

pub const Payload = union(enum) {
    none,
    /// A mesh with only PackedQuads.
    quads: []const PackedQuad,
    mesh: MeshPayload,
    blocks: *const PalettedBlocks,
};

/// A decoded Result. `payload` points into the message bytes.
pub const Result = struct {
    head: ResultHead,
    /// The PackedQuad bytes of a mesh, or the blocks of a generate.
    payload: []const u8,
    has_blocks: bool,

    fn tailLen(self: Result) usize {
        return @as(usize, self.head.fluid_quads) * FLUID_QUAD_LEN + @as(usize, self.head.translucent_quads) * (TRANSLUCENT_QUAD_LEN + CENTER_LEN);
    }

    /// The bytes of the PackedQuads of a mesh.
    pub fn quadBytes(self: Result) []const u8 {
        return self.payload[0 .. self.payload.len - self.tailLen()];
    }

    /// The bytes of the fluid vertices of a mesh (REQ-VOXEL-027).
    pub fn fluidBytes(self: Result) []const u8 {
        return self.payload[self.quadBytes().len..][0 .. @as(usize, self.head.fluid_quads) * FLUID_QUAD_LEN];
    }

    /// The bytes of the translucent vertices of a mesh (REQ-VOXEL-030).
    pub fn translucentBytes(self: Result) []const u8 {
        const start = self.quadBytes().len + self.fluidBytes().len;
        return self.payload[start..][0 .. @as(usize, self.head.translucent_quads) * TRANSLUCENT_QUAD_LEN];
    }

    /// The bytes of the translucent quad centres of a mesh.
    pub fn centerBytes(self: Result) []const u8 {
        return self.payload[self.payload.len - @as(usize, self.head.translucent_quads) * CENTER_LEN ..];
    }

    /// Copy the translucent vertices into `out` (4 × the quad count) and
    /// the centres into `centers` (the quad count).
    pub fn copyTranslucent(self: Result, out: []TranslucentVertex, centers: [][3]f32) void {
        std.debug.assert(out.len == @as(usize, self.head.translucent_quads) * 4);
        std.debug.assert(centers.len == self.head.translucent_quads);
        const vb = self.translucentBytes();
        for (out, 0..) |*v, i| {
            var in: In = .{ .buf = vb[i * @sizeOf(TranslucentVertex) ..][0..@sizeOf(TranslucentVertex)] };
            for (&v.pos) |*f| f.* = in.float();
            for (&v.color) |*f| f.* = in.float();
        }
        readCenters(self.centerBytes(), centers);
    }

    pub fn quadCount(self: Result) usize {
        return self.quadBytes().len / @sizeOf(PackedQuad);
    }

    pub fn fluidQuadCount(self: Result) usize {
        return self.head.fluid_quads;
    }

    /// Copy the quads into `out`. `out.len` must be `quadCount()`.
    pub fn copyQuads(self: Result, out: []PackedQuad) void {
        std.debug.assert(out.len == self.quadCount());
        const bytes = self.quadBytes();
        if (comptime builtin.cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(out), bytes);
        } else {
            for (out, 0..) |*q, i| {
                for (q, 0..) |*w, k| w.* = std.mem.readInt(u32, bytes[i * 16 + k * 4 ..][0..4], .little);
            }
        }
    }

    /// Copy the fluid vertices into `out`. `out.len` must be 4 ×
    /// `fluidQuadCount()`.
    pub fn copyFluid(self: Result, out: []FluidVertex) void {
        std.debug.assert(out.len == self.fluidQuadCount() * 4);
        const bytes = self.fluidBytes();
        for (out, 0..) |*v, i| {
            var in: In = .{ .buf = bytes[i * @sizeOf(FluidVertex) ..][0..@sizeOf(FluidVertex)] };
            for (&v.pos) |*f| f.* = in.float();
            for (&v.uv) |*f| f.* = in.float();
            v.info = in.int(u32);
        }
    }
};

/// Read the centres of translucent quads (3 little-endian f32 each) from
/// `bytes` into `out`. Main reads them from a mesh Result for the sort
/// (REQ-VOXEL-030).
pub fn readCenters(bytes: []const u8, out: [][3]f32) void {
    std.debug.assert(bytes.len == out.len * CENTER_LEN);
    for (out, 0..) |*c, i| {
        for (c, 0..) |*f, k| f.* = @bitCast(std.mem.readInt(u32, bytes[i * CENTER_LEN + k * 4 ..][0..4], .little));
    }
}

pub const ErrorCode = enum(u16) {
    /// The message is not a valid message of this protocol.
    bad_message = 1,
    /// The Hello has another protocol version or build hash.
    version_mismatch = 2,
    out_of_memory = 3,
    /// The block versions of the job are not the versions of the worker.
    stale_input = 4,
    /// The worker got a Job before a Hello.
    no_world = 5,
};

/// Body (16 bytes, then the text):
///
///   0  u16  error code
///   2  u8   stage
///   3  u8   reserved, 0
///   4  i32  cx
///   8  i32  cz
///   12 u32  text length (at most MAX_ERROR_TEXT)
///   16 ...  text, UTF-8
pub const Error = struct {
    code: ErrorCode,
    stage: Stage = .generate,
    cx: i32 = 0,
    cz: i32 = 0,
    text: []const u8 = "",
};

pub const Message = union(Kind) {
    hello: Hello,
    edit: Edit,
    job: Job,
    result: Result,
    err: Error,
};

pub const Decoded = struct {
    id: u32,
    msg: Message,
};

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// A fixed-size byte writer. The encoders compute the length first.
const Out = struct {
    buf: []u8,
    pos: usize = 0,

    fn int(self: *Out, comptime T: type, v: T) void {
        const n = @sizeOf(T);
        std.mem.writeInt(T, self.buf[self.pos..][0..n], v, .little);
        self.pos += n;
    }

    fn float(self: *Out, v: f32) void {
        self.int(u32, @bitCast(v));
    }

    fn bytes(self: *Out, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }

    fn zeros(self: *Out, n: usize) void {
        @memset(self.buf[self.pos..][0..n], 0);
        self.pos += n;
    }

    fn header(self: *Out, kind: Kind, id: u32) void {
        self.int(u32, MAGIC);
        self.int(u16, VERSION);
        self.int(u8, @backingInt(kind));
        self.int(u8, 0);
        self.int(u32, @intCast(self.buf.len - HEADER_LEN));
        self.int(u32, id);
    }
};

fn begin(allocator: std.mem.Allocator, len: usize, kind: Kind, id: u32) !Out {
    var out: Out = .{ .buf = try allocator.alloc(u8, len) };
    out.header(kind, id);
    return out;
}

fn finish(out: Out) []u8 {
    std.debug.assert(out.pos == out.buf.len);
    return out.buf;
}

fn genConfigBytes(config: content.GenConfig) [content.GEN_CONFIG_LEN]u8 {
    var out: [content.GEN_CONFIG_LEN]u8 = undefined;
    content.encodeGenConfig(config, &out);
    return out;
}

pub fn encodeHello(allocator: std.mem.Allocator, hello: Hello) ![]u8 {
    var o = try begin(allocator, HEADER_LEN + HELLO_LEN, .hello, 0);
    const c = hello.config;
    o.int(u64, hello.build_hash);
    o.int(u64, c.seed);
    o.int(u64, hello.cache_limit);
    o.bytes(&genConfigBytes(c));
    return finish(o);
}

pub fn encodeEdit(allocator: std.mem.Allocator, edit: Edit) ![]u8 {
    var o = try begin(allocator, HEADER_LEN + EDIT_LEN, .edit, 0);
    o.int(i32, edit.cx);
    o.int(i32, edit.cz);
    o.int(u32, edit.version);
    o.int(u16, edit.y);
    o.int(u8, edit.x | (edit.z << 4));
    o.int(u8, @backingInt(edit.block));
    return finish(o);
}

pub fn encodeJob(allocator: std.mem.Allocator, id: u32, job: Job) ![]u8 {
    var o = try begin(allocator, HEADER_LEN + JOB_LEN, .job, id);
    o.int(u8, @backingInt(job.stage));
    o.int(u8, @backingInt(job.ao));
    o.int(u8, @backingInt(job.lighting));
    o.int(u8, @as(u8, @intFromBool(job.want_blocks)) | (@as(u8, @intFromBool(!job.smooth_light)) << 1));
    o.int(i32, job.cx);
    o.int(i32, job.cz);
    o.int(u8, job.lod);
    o.int(u8, 0);
    o.int(u16, 0);
    for (job.blocks) |v| o.int(u32, v);
    for (job.light) |v| o.int(u32, v);
    return finish(o);
}

/// The length of the blocks payload of `pb`.
///
/// Blocks payload: an 8-byte head, then each section from local y 0 up.
///
///   0  u16  section count: chunk.SECTION_COUNT
///   2  u16  0
///   4  u32  0
///
/// Section (8-byte aligned):
///
///   0  u8   index bits: 0, 1, 2, 4 or 8 (Section.bitsFor of the length)
///   1  u8   0
///   2  u16  palette length, 1 to 256
///   4  ...  the palette (one byte for each block type), then 0 bytes to
///           the next 8-byte boundary
///   ...     the index words: u64 × Section.indexWords(bits)
pub fn blocksLen(pb: *const PalettedBlocks) usize {
    var n: usize = 8;
    for (&pb.sections) |*sec| n += sectionLen(sec.bits, sec.len);
    return n;
}

fn sectionLen(bits: u8, palette_len: usize) usize {
    return std.mem.alignForward(usize, 4 + palette_len, 8) + Section.indexWords(bits) * 8;
}

pub fn encodeResult(allocator: std.mem.Allocator, id: u32, head: ResultHead, payload: Payload) ![]u8 {
    const mesh: ?MeshPayload = switch (payload) {
        .quads => |q| .{ .quads = q },
        .mesh => |m| m,
        else => null,
    };
    if (mesh) |m| {
        std.debug.assert(m.fluid.len % 4 == 0);
        std.debug.assert(m.translucent.len == m.centers.len * 4);
    }
    const payload_len: usize = switch (payload) {
        .none => 0,
        .quads, .mesh => mesh.?.quads.len * @sizeOf(PackedQuad) + mesh.?.fluid.len * @sizeOf(FluidVertex) +
            mesh.?.centers.len * (TRANSLUCENT_QUAD_LEN + CENTER_LEN),
        .blocks => |pb| blocksLen(pb),
    };
    var o = try begin(allocator, PAYLOAD_OFFSET + payload_len, .result, id);
    o.int(u8, @backingInt(head.stage));
    o.int(u8, @intFromBool(payload == .blocks));
    o.int(u16, 0);
    o.int(i32, head.cx);
    o.int(i32, head.cz);
    o.int(u32, head.block_ver);
    switch (head.stage) {
        .mesh => {
            o.float(head.y_min);
            o.float(head.y_max);
        },
        else => o.int(u64, head.light_hash),
    }
    o.int(u32, switch (payload) {
        .none => 0,
        .quads, .mesh => @intCast(mesh.?.quads.len),
        .blocks => @intCast(payload_len),
    });
    o.int(u32, head.job_us);
    // The mesh hash goes in after the payload: it is the hash of the
    // payload bytes.
    o.int(u64, 0);
    o.int(u32, if (mesh) |m| @intCast(m.fluid.len / 4) else 0);
    o.int(u32, if (mesh) |m| @intCast(m.centers.len) else 0);
    for (head.sections) |c| o.int(u16, if (head.stage == .mesh) c else 0);
    o.zeros(SECTIONS_LEN - chunk_mod.SECTION_COUNT * 2);
    for (head.ranges) |r| o.int(u32, if (head.stage == .mesh) @bitCast(r) else 0);
    o.zeros(RANGES_LEN - chunk_mod.SECTION_COUNT * 4);
    switch (payload) {
        .none => {},
        .quads, .mesh => {
            const m = mesh.?;
            if (comptime builtin.cpu.arch.endian() == .little) {
                o.bytes(std.mem.sliceAsBytes(m.quads));
            } else {
                for (m.quads) |quad| for (quad) |w| o.int(u32, w);
            }
            for (m.fluid) |v| {
                for (v.pos) |f| o.float(f);
                for (v.uv) |f| o.float(f);
                o.int(u32, v.info);
            }
            for (m.translucent) |v| {
                for (v.pos) |f| o.float(f);
                for (v.color) |f| o.float(f);
            }
            for (m.centers) |c| for (c) |f| o.float(f);
        },
        .blocks => |pb| {
            o.int(u16, chunk_mod.SECTION_COUNT);
            o.int(u16, 0);
            o.int(u32, 0);
            for (&pb.sections) |*sec| {
                o.int(u8, sec.bits);
                o.int(u8, 0);
                o.int(u16, sec.len);
                for (sec.palette()) |b| o.int(u8, @backingInt(b));
                o.zeros(std.mem.alignForward(usize, 4 + sec.len, 8) - 4 - sec.len);
                for (sec.indices()) |w| o.int(u64, w);
            }
        },
    }
    if (mesh != null) {
        std.mem.writeInt(u64, o.buf[MESH_HASH_OFFSET..][0..8], meshHash(o.buf[PAYLOAD_OFFSET..]), .little);
    }
    return finish(o);
}

pub fn encodeError(allocator: std.mem.Allocator, id: u32, e: Error) ![]u8 {
    const text = e.text[0..@min(e.text.len, MAX_ERROR_TEXT)];
    var o = try begin(allocator, HEADER_LEN + ERROR_HEAD_LEN + text.len, .err, id);
    o.int(u16, @backingInt(e.code));
    o.int(u8, @backingInt(e.stage));
    o.int(u8, 0);
    o.int(i32, e.cx);
    o.int(i32, e.cz);
    o.int(u32, @intCast(text.len));
    o.bytes(text);
    return finish(o);
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

pub const DecodeError = error{
    /// The message is shorter than its header or its body says.
    Truncated,
    BadMagic,
    /// Another protocol version.
    BadVersion,
    BadKind,
    /// The body length is not the length that the kind needs.
    BadLength,
    /// A field has a value that the protocol does not allow.
    BadField,
};

const In = struct {
    buf: []const u8,
    pos: usize = 0,

    fn int(self: *In, comptime T: type) T {
        const n = @sizeOf(T);
        const v = std.mem.readInt(T, self.buf[self.pos..][0..n], .little);
        self.pos += n;
        return v;
    }

    fn float(self: *In) f32 {
        return @bitCast(self.int(u32));
    }

    fn enumOf(self: *In, comptime E: type) DecodeError!E {
        return std.enums.fromInt(E, self.int(u8)) orelse error.BadField;
    }
};

/// Read the header of `bytes`. The views in the result point into `bytes`.
/// It checks each field. It never reads past `bytes`.
pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < HEADER_LEN) return error.Truncated;
    var h: In = .{ .buf = bytes };
    if (h.int(u32) != MAGIC) return error.BadMagic;
    if (h.int(u16) != VERSION) return error.BadVersion;
    const kind = std.enums.fromInt(Kind, h.int(u8)) orelse return error.BadKind;
    if (h.int(u8) != 0) return error.BadField;
    const body_len = h.int(u32);
    const id = h.int(u32);
    if (bytes.len - HEADER_LEN != body_len) return error.Truncated;
    // A Hello and an Edit have no job id.
    if ((kind == .hello or kind == .edit) and id != 0) return error.BadField;
    var b: In = .{ .buf = bytes[HEADER_LEN..] };
    const msg: Message = switch (kind) {
        .hello => blk: {
            if (body_len != HELLO_LEN) return error.BadLength;
            const build_hash = b.int(u64);
            const seed = b.int(u64);
            const cache_limit = b.int(u64);
            var config = try content.decodeGenConfig(b.buf[b.pos..][0..content.GEN_CONFIG_LEN]);
            config.seed = seed;
            break :blk .{ .hello = .{
                .build_hash = build_hash,
                .cache_limit = cache_limit,
                .config = config,
            } };
        },
        .edit => blk: {
            if (body_len != EDIT_LEN) return error.BadLength;
            const cx = b.int(i32);
            const cz = b.int(i32);
            const version = b.int(u32);
            const y = b.int(u16);
            const xz = b.int(u8);
            const e: Edit = .{
                .cx = cx,
                .cz = cz,
                .version = version,
                .x = xz & 0xF,
                .y = y,
                .z = xz >> 4,
                .block = try b.enumOf(BlockType),
            };
            if (e.y >= chunk_mod.CHUNK_H) return error.BadField;
            break :blk .{ .edit = e };
        },
        .job => blk: {
            if (body_len != JOB_LEN) return error.BadLength;
            var j: Job = .{
                .stage = try b.enumOf(Stage),
                .ao = try b.enumOf(stages.AOStrategy),
                .lighting = try b.enumOf(stages.LightingMode),
                .cx = 0,
                .cz = 0,
            };
            const flags = b.int(u8);
            if (flags & ~@as(u8, 3) != 0) return error.BadField;
            j.want_blocks = flags & 1 != 0;
            j.smooth_light = flags & 2 == 0;
            j.cx = b.int(i32);
            j.cz = b.int(i32);
            j.lod = b.int(u8);
            if (j.lod > lod.MAX_LEVEL) return error.BadField;
            if (b.int(u8) != 0 or b.int(u16) != 0) return error.BadField;
            for (&j.blocks) |*v| v.* = b.int(u32);
            for (&j.light) |*v| v.* = b.int(u32);
            break :blk .{ .job = j };
        },
        .result => blk: {
            const info = try resultInfo(bytes, kind, body_len, id);
            const r = info.head;
            const payload = bytes[PAYLOAD_OFFSET..];
            switch (r.stage) {
                .mesh => if (meshHash(payload) != r.mesh_hash) return error.BadField,
                .generate => if (info.has_blocks) try checkBlocks(payload),
                .light => {},
            }
            break :blk .{ .result = .{ .head = r, .payload = payload, .has_blocks = info.has_blocks } };
        },
        .err => blk: {
            if (body_len < ERROR_HEAD_LEN) return error.BadLength;
            var e: Error = .{ .code = std.enums.fromInt(ErrorCode, b.int(u16)) orelse return error.BadField };
            e.stage = try b.enumOf(Stage);
            if (b.int(u8) != 0) return error.BadField;
            e.cx = b.int(i32);
            e.cz = b.int(i32);
            const n = b.int(u32);
            if (n > MAX_ERROR_TEXT or n != body_len - ERROR_HEAD_LEN) return error.BadLength;
            e.text = bytes[HEADER_LEN + ERROR_HEAD_LEN ..];
            break :blk .{ .err = e };
        },
    };
    return .{ .id = id, .msg = msg };
}

/// Decode the header and the fixed part of a Result, from the first
/// PAYLOAD_OFFSET bytes of the message (`head`). `len` is the length of the
/// whole message. It does not read the payload, so main can decode a mesh
/// Result that JS holds (C5). It checks each field that it reads. Returns
/// null when the message is not a Result.
pub fn decodeResultHead(head: []const u8, len: usize) DecodeError!?ResultInfo {
    if (head.len < HEADER_LEN or len < HEADER_LEN) return error.Truncated;
    var h: In = .{ .buf = head };
    if (h.int(u32) != MAGIC) return error.BadMagic;
    if (h.int(u16) != VERSION) return error.BadVersion;
    const kind = std.enums.fromInt(Kind, h.int(u8)) orelse return error.BadKind;
    if (h.int(u8) != 0) return error.BadField;
    const body_len = h.int(u32);
    const id = h.int(u32);
    if (len - HEADER_LEN != body_len) return error.Truncated;
    if (kind != .result) return null;
    if (head.len < @min(len, PAYLOAD_OFFSET)) return error.Truncated;
    return try resultInfo(head, kind, body_len, id);
}

/// The fixed part of a Result. `bytes` holds at least the first
/// PAYLOAD_OFFSET bytes when the body is that long. `body_len` is from the
/// header.
fn resultInfo(bytes: []const u8, kind: Kind, body_len: u32, id: u32) DecodeError!ResultInfo {
    std.debug.assert(kind == .result);
    if (body_len < RESULT_HEAD_LEN or bytes.len < PAYLOAD_OFFSET) return error.BadLength;
    var b: In = .{ .buf = bytes[HEADER_LEN..PAYLOAD_OFFSET] };
    var r: ResultHead = .{ .stage = try b.enumOf(Stage), .cx = 0, .cz = 0 };
    const flags = b.int(u8);
    if (flags & ~@as(u8, 1) != 0) return error.BadField;
    const has_blocks = flags & 1 != 0;
    if (b.int(u16) != 0) return error.BadField;
    r.cx = b.int(i32);
    r.cz = b.int(i32);
    r.block_ver = b.int(u32);
    if (r.stage == .mesh) {
        r.y_min = b.float();
        r.y_max = b.float();
    } else {
        r.light_hash = b.int(u64);
    }
    const count = b.int(u32);
    r.job_us = b.int(u32);
    r.mesh_hash = b.int(u64);
    r.fluid_quads = b.int(u32);
    r.translucent_quads = b.int(u32);
    if (r.stage != .mesh and (r.fluid_quads != 0 or r.translucent_quads != 0)) return error.BadField;
    for (&r.sections) |*c| {
        c.* = b.int(u16);
        if (c.* > 0x7FFF or (r.stage != .mesh and c.* != 0)) return error.BadField;
    }
    if (r.stage != .mesh) r.sections = @splat(0x7FFF);
    for (0..SECTIONS_LEN - chunk_mod.SECTION_COUNT * 2) |_| {
        if (b.int(u8) != 0) return error.BadField;
    }
    var prev_end: u32 = 0;
    for (&r.ranges, 0..) |*rg, s| {
        const w = b.int(u32);
        if (r.stage != .mesh) {
            if (w != 0) return error.BadField;
            continue;
        }
        rg.* = @bitCast(w);
        if (rg.end < prev_end or rg.top < s or rg.top >= chunk_mod.SECTION_COUNT) return error.BadField;
        prev_end = rg.end;
    }
    if (r.stage != .mesh) r.ranges = mesher_mod.EMPTY_RANGES;
    for (0..RANGES_LEN - chunk_mod.SECTION_COUNT * 4) |_| {
        if (b.int(u8) != 0) return error.BadField;
    }
    const payload_len: usize = body_len - RESULT_HEAD_LEN;
    switch (r.stage) {
        .mesh => {
            if (has_blocks) return error.BadField;
            if (@as(u64, count) * @sizeOf(PackedQuad) + @as(u64, r.fluid_quads) * FLUID_QUAD_LEN +
                @as(u64, r.translucent_quads) * (TRANSLUCENT_QUAD_LEN + CENTER_LEN) != payload_len) return error.BadLength;
            if (r.ranges[chunk_mod.SECTION_COUNT - 1].end != count) return error.BadField;
        },
        .generate => {
            if (count != payload_len) return error.BadLength;
            if (has_blocks != (count != 0)) return error.BadField;
            if (r.mesh_hash != 0) return error.BadField;
        },
        .light => if (has_blocks or count != 0 or payload_len != 0 or r.mesh_hash != 0) return error.BadField,
    }
    return .{
        .id = id,
        .head = r,
        .has_blocks = has_blocks,
        .payload_len = payload_len,
        .quad_count = if (r.stage == .mesh) count else 0,
    };
}

/// Check a blocks payload: the section count, and for each section the
/// palette, the bit width and the length.
fn checkBlocks(p: []const u8) DecodeError!void {
    if (p.len < 8) return error.BadLength;
    var in: In = .{ .buf = p };
    if (in.int(u16) != chunk_mod.SECTION_COUNT) return error.BadField;
    if (in.int(u16) != 0 or in.int(u32) != 0) return error.BadField;
    for (0..chunk_mod.SECTION_COUNT) |_| {
        const start = in.pos;
        if (p.len - start < 4) return error.BadLength;
        const bits = in.int(u8);
        if (in.int(u8) != 0) return error.BadField;
        const palette_len = in.int(u16);
        if (palette_len < 1 or palette_len > 256) return error.BadField;
        if (bits != Section.bitsFor(palette_len)) return error.BadField;
        const len = sectionLen(bits, palette_len);
        if (p.len - start < len) return error.BadLength;
        for (p[start + 4 ..][0..palette_len]) |b| {
            if (std.enums.fromInt(BlockType, b) == null) return error.BadField;
        }
        const pal_end = start + 4 + palette_len;
        for (p[pal_end .. start + std.mem.alignForward(usize, 4 + palette_len, 8)]) |b| {
            if (b != 0) return error.BadField;
        }
        in.pos = start + len;
    }
    if (in.pos != p.len) return error.BadLength;
}

/// The blocks of a generate Result. The caller owns them.
pub fn decodeBlocks(allocator: std.mem.Allocator, r: Result) !PalettedBlocks {
    std.debug.assert(r.has_blocks);
    const p = r.payload;
    var out: PalettedBlocks = .{};
    errdefer out.deinit(allocator);
    var pos: usize = 8;
    for (&out.sections) |*sec| {
        var in: In = .{ .buf = p, .pos = pos };
        const bits = in.int(u8);
        _ = in.int(u8);
        const palette_len = in.int(u16);
        const pal = p[pos + 4 ..][0..palette_len];
        pos += sectionLen(bits, palette_len);
        if (bits == 0) {
            sec.* = Section.uniform(@fromBackingInt(pal[0]));
            continue;
        }
        const buf = try allocator.alloc(u64, Section.indexWords(bits) + Section.paletteWords(bits));
        @memset(buf, 0);
        sec.* = .{ .bits = bits, .len = palette_len, .buf = buf };
        var w: In = .{ .buf = p, .pos = pos - Section.indexWords(bits) * 8 };
        for (buf[0..Section.indexWords(bits)]) |*d| d.* = w.int(u64);
        const slots = std.mem.sliceAsBytes(buf[Section.indexWords(bits)..]);
        @memcpy(slots[0..palette_len], pal);
    }
    return out;
}

/// A hash of the light of a chunk (C3). Equal light gives an equal hash.
/// LightGrid keeps an array only for a section that is not uniform, so the
/// stored form of a light is unique.
pub fn lightHash(light: *const stages.ChunkLight) u64 {
    var h = std.hash.Wyhash.init(0x4C49_4748_54);
    for ([_]*const chunk_mod.LightGrid{ &light.sky, &light.block }) |g| {
        for (g.arrays, g.fill) |arr, fill| {
            if (arr) |a| {
                h.update(&.{1});
                h.update(std.mem.asBytes(a));
            } else {
                h.update(&.{ 0, fill });
            }
        }
    }
    return h.final();
}

test "a Hello carries the seed and the generator settings of the content" {
    const a = std.testing.allocator;
    var config: content.GenConfig = .{};
    config.seed = 0x5eed_0001;
    const bytes = try encodeHello(a, .{ .cache_limit = 1 << 20, .config = config });
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, HEADER_LEN + HELLO_LEN), bytes.len);
    const d = try decode(bytes);
    try std.testing.expectEqual(BUILD_HASH, d.msg.hello.build_hash);
    try std.testing.expectEqual(@as(u64, 1 << 20), d.msg.hello.cache_limit);
    try std.testing.expectEqual(config, d.msg.hello.config);
}
