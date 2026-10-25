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
const world_gen = @import("../world_gen.zig");
const stages = @import("stages.zig");

const BlockType = chunk_mod.BlockType;
const PalettedBlocks = chunk_mod.PalettedBlocks;
pub const PackedQuad = mesher_mod.PackedQuad;
pub const Stage = stages.Stage;
pub const Version = stages.Version;
pub const SLOTS = stages.SLOTS;

/// "VXCP" as little-endian bytes.
pub const MAGIC: u32 = 0x50435856;
/// Increment this value for each change of the layout.
pub const VERSION: u16 = 2;

pub const HEADER_LEN = 16;
pub const HELLO_LEN = 56;
pub const EDIT_LEN = 16;
pub const JOB_LEN = 88;
pub const RESULT_HEAD_LEN = 48;
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
    const parts = [_]u64{ VERSION, chunk_mod.CHUNK_W, chunk_mod.CHUNK_H, @sizeOf(PackedQuad), SLOTS, std.enums.values(BlockType).len };
    for (parts) |p| h.update(std.mem.asBytes(&p));
    break :blk h.final();
};

comptime {
    std.debug.assert(PAYLOAD_OFFSET % 16 == 0);
    // Edit stores the local cell in u8 fields.
    std.debug.assert(chunk_mod.CHUNK_W <= 256 and chunk_mod.CHUNK_H <= 256);
    std.debug.assert(@sizeOf(PackedQuad) == 16);
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

/// The first message in each direction. Main sends the world: the generation
/// config with the seed, and the cache limit of the worker (C14). The worker
/// answers with its own build hash.
///
/// Body (56 bytes):
///
///   0  u64  build hash
///   8  u64  seed
///   16 u64  cache limit in bytes
///   24 u8   preset
///   25 u8×3 reserved, 0
///   28 i32  sea level
///   32 i32  terrain height min
///   36 i32  terrain height max
///   40 f32  noise scale
///   44 u32  noise octaves
///   48 f32  noise persistence
///   52 f32  noise lacunarity
pub const Hello = struct {
    build_hash: u64 = BUILD_HASH,
    cache_limit: u64,
    config: world_gen.WorldGenConfig,
};

/// One block edit (P2). Main sends each edit to each worker, in the order of
/// the edits. `version` is the block version of the chunk after the edit.
///
/// Body (16 bytes):
///
///   0  i32  cx
///   4  i32  cz
///   8  u32  block version after the edit
///   12 u8   x (local, 0..15)
///   13 u8   y (0..255)
///   14 u8   z (local, 0..15)
///   15 u8   block type
pub const Edit = struct {
    cx: i32,
    cz: i32,
    version: Version,
    x: u8,
    y: u8,
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
///   3  u8      flags: bit 0 = send the blocks back (generate)
///   4  i32     cx
///   8  i32     cz
///   12 u32     reserved, 0
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
    blocks: [SLOTS]Version = @splat(0),
    light: [SLOTS]Version = @splat(0),
};

/// The fixed part of a Result.
///
/// Body (48 bytes, then the payload):
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
///   40 u64  reserved, 0
///   48 ...  payload: mesh: PackedQuad × count. generate: the blocks
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
};

pub const Payload = union(enum) {
    none,
    quads: []const PackedQuad,
    blocks: *const PalettedBlocks,
};

/// A decoded Result. `payload` points into the message bytes.
pub const Result = struct {
    head: ResultHead,
    /// The PackedQuad bytes of a mesh, or the blocks of a generate.
    payload: []const u8,
    has_blocks: bool,

    pub fn quadCount(self: Result) usize {
        return self.payload.len / @sizeOf(PackedQuad);
    }

    /// Copy the quads into `out`. `out.len` must be `quadCount()`.
    pub fn copyQuads(self: Result, out: []PackedQuad) void {
        std.debug.assert(out.len == self.quadCount());
        if (comptime builtin.cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(out), self.payload);
        } else {
            for (out, 0..) |*q, i| {
                for (q, 0..) |*w, k| w.* = std.mem.readInt(u32, self.payload[i * 16 + k * 4 ..][0..4], .little);
            }
        }
    }
};

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

pub fn encodeHello(allocator: std.mem.Allocator, hello: Hello) ![]u8 {
    var o = try begin(allocator, HEADER_LEN + HELLO_LEN, .hello, 0);
    const c = hello.config;
    o.int(u64, hello.build_hash);
    o.int(u64, c.seed);
    o.int(u64, hello.cache_limit);
    o.int(u8, @backingInt(c.preset));
    o.zeros(3);
    o.int(i32, c.sea_level);
    o.int(i32, c.terrain_height_min);
    o.int(i32, c.terrain_height_max);
    o.float(c.noise_scale);
    o.int(u32, c.noise_octaves);
    o.float(c.noise_persistence);
    o.float(c.noise_lacunarity);
    return finish(o);
}

pub fn encodeEdit(allocator: std.mem.Allocator, edit: Edit) ![]u8 {
    var o = try begin(allocator, HEADER_LEN + EDIT_LEN, .edit, 0);
    o.int(i32, edit.cx);
    o.int(i32, edit.cz);
    o.int(u32, edit.version);
    o.int(u8, edit.x);
    o.int(u8, edit.y);
    o.int(u8, edit.z);
    o.int(u8, @backingInt(edit.block));
    return finish(o);
}

pub fn encodeJob(allocator: std.mem.Allocator, id: u32, job: Job) ![]u8 {
    var o = try begin(allocator, HEADER_LEN + JOB_LEN, .job, id);
    o.int(u8, @backingInt(job.stage));
    o.int(u8, @backingInt(job.ao));
    o.int(u8, @backingInt(job.lighting));
    o.int(u8, @intFromBool(job.want_blocks));
    o.int(i32, job.cx);
    o.int(i32, job.cz);
    o.int(u32, 0);
    for (job.blocks) |v| o.int(u32, v);
    for (job.light) |v| o.int(u32, v);
    return finish(o);
}

/// The length of the blocks payload of `pb`.
pub fn blocksLen(pb: *const PalettedBlocks) usize {
    return 8 + std.mem.alignForward(usize, pb.palette_len, 8) + pb.data.len * 8;
}

pub fn encodeResult(allocator: std.mem.Allocator, id: u32, head: ResultHead, payload: Payload) ![]u8 {
    const payload_len: usize = switch (payload) {
        .none => 0,
        .quads => |q| q.len * @sizeOf(PackedQuad),
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
        .quads => |q| @intCast(q.len),
        .blocks => @intCast(payload_len),
    });
    o.int(u32, head.job_us);
    // The mesh hash goes in after the payload: it is the hash of the
    // payload bytes.
    o.int(u64, 0);
    o.int(u64, 0);
    switch (payload) {
        .none => {},
        .quads => |q| {
            if (comptime builtin.cpu.arch.endian() == .little) {
                o.bytes(std.mem.sliceAsBytes(q));
            } else {
                for (q) |quad| for (quad) |w| o.int(u32, w);
            }
        },
        .blocks => |pb| {
            o.int(u16, pb.palette_len);
            o.int(u8, pb.bits_per_entry);
            o.int(u8, 0);
            o.int(u32, @intCast(pb.data.len));
            for (pb.palette[0..pb.palette_len]) |b| o.int(u8, @backingInt(b));
            o.zeros(std.mem.alignForward(usize, pb.palette_len, 8) - pb.palette_len);
            for (pb.data) |w| o.int(u64, w);
        },
    }
    if (payload == .quads) {
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
            const preset = try b.enumOf(world_gen.Preset);
            for (0..3) |_| if (b.int(u8) != 0) return error.BadField;
            break :blk .{ .hello = .{
                .build_hash = build_hash,
                .cache_limit = cache_limit,
                .config = .{
                    .preset = preset,
                    .seed = seed,
                    .sea_level = b.int(i32),
                    .terrain_height_min = b.int(i32),
                    .terrain_height_max = b.int(i32),
                    .noise_scale = b.float(),
                    .noise_octaves = b.int(u32),
                    .noise_persistence = b.float(),
                    .noise_lacunarity = b.float(),
                },
            } };
        },
        .edit => blk: {
            if (body_len != EDIT_LEN) return error.BadLength;
            const e: Edit = .{
                .cx = b.int(i32),
                .cz = b.int(i32),
                .version = b.int(u32),
                .x = b.int(u8),
                .y = b.int(u8),
                .z = b.int(u8),
                .block = try b.enumOf(BlockType),
            };
            if (e.x >= chunk_mod.CHUNK_W or e.z >= chunk_mod.CHUNK_W) return error.BadField;
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
            if (flags & ~@as(u8, 1) != 0) return error.BadField;
            j.want_blocks = flags & 1 != 0;
            j.cx = b.int(i32);
            j.cz = b.int(i32);
            if (b.int(u32) != 0) return error.BadField;
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
    if (b.int(u64) != 0) return error.BadField;
    const payload_len: usize = body_len - RESULT_HEAD_LEN;
    switch (r.stage) {
        .mesh => {
            if (has_blocks) return error.BadField;
            if (@as(u64, count) * @sizeOf(PackedQuad) != payload_len) return error.BadLength;
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

/// Check a blocks payload: the palette, the bit width and the length.
fn checkBlocks(p: []const u8) DecodeError!void {
    if (p.len < 8) return error.BadLength;
    var in: In = .{ .buf = p };
    const palette_len = in.int(u16);
    const bits = in.int(u8);
    if (in.int(u8) != 0) return error.BadField;
    const words = in.int(u32);
    if (palette_len < 1 or palette_len > 256) return error.BadField;
    if (bits != PalettedBlocks.minBitsFor(palette_len)) return error.BadField;
    const want_words: usize = if (bits == 0) 0 else PalettedBlocks.wordCountFor(bits);
    if (words != want_words) return error.BadField;
    const pal_padded = std.mem.alignForward(usize, palette_len, 8);
    if (p.len != 8 + pal_padded + @as(usize, words) * 8) return error.BadLength;
    for (p[8..][0..palette_len]) |b| {
        if (std.enums.fromInt(BlockType, b) == null) return error.BadField;
    }
    for (p[8 + palette_len ..][0 .. pal_padded - palette_len]) |b| {
        if (b != 0) return error.BadField;
    }
}

/// The blocks of a generate Result. The caller owns them.
pub fn decodeBlocks(allocator: std.mem.Allocator, r: Result) !PalettedBlocks {
    std.debug.assert(r.has_blocks);
    const p = r.payload;
    var in: In = .{ .buf = p };
    var out: PalettedBlocks = .{};
    out.palette_len = in.int(u16);
    out.bits_per_entry = in.int(u8);
    _ = in.int(u8);
    const words = in.int(u32);
    for (p[8..][0..out.palette_len], 0..) |b, i| out.palette[i] = @fromBackingInt(b);
    if (words == 0) return out;
    const data = try allocator.alloc(u64, words);
    var w: In = .{ .buf = p, .pos = 8 + std.mem.alignForward(usize, out.palette_len, 8) };
    for (data) |*d| d.* = w.int(u64);
    out.data = data;
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
