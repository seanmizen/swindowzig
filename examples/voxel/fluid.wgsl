// The fluid pass of the voxel demo (REQ-VOXEL-028).
//
// The fluid mesher of sw_voxel (fluid.zig) gives 4 vertices for each fluid
// quad. The mesh result holds them after the packed quads, and main writes
// them to a storage buffer for each chunk, after a 16-byte header. A draw
// of fluid_quads * 6 vertices with no vertex or index buffer makes the 2
// triangles of each quad (fluid.quad_indices: 0, 1, 2, 0, 2, 3).
//
// The pass draws after the opaque chunks, far to near, with alpha blend,
// the depth test on and the depth write off. It does not cull back faces,
// so the player sees the surface from below.

// The same uniforms as voxel.wgsl. Change both together.
struct Uniforms {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    debug_tick: u32,
    hover_block: vec3<f32>,
    hover_active: f32,
    fog_start: f32,
    fog_end: f32,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// origin: x and z are the chunk origin in world blocks. Each vertex is 6
// words (fluid.Vertex): pos x, y, z (f32), uv u, v (f32), info (u32).
// info bits 0-7: the fluid. Bits 8-10: the face (px, nx, py, ny, pz, nz).
// Bit 11: the flow texture. Bits 16-19: the sky light. Bits 20-23: the
// block light.
struct FluidQuads {
    origin: vec4<i32>,
    words: array<u32>,
};

@group(1) @binding(0) var<storage, read> fluid: FluidQuads;

struct FluidOut {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) light: f32,
    @location(3) @interpolate(flat) info: u32,
};

// The corner of each of the 6 vertices of a quad, 4 bits each:
// 0, 1, 2, 0, 2, 3. No array: a runtime index into an array costs a copy
// of the array per vertex on some backends.
const QUAD_CORNERS: u32 = 0x320210u;
const VERTEX_WORDS: u32 = 6u;

@vertex
fn vs_fluid(@builtin(vertex_index) vid: u32) -> FluidOut {
    let quad = vid / 6u;
    let corner = (QUAD_CORNERS >> (4u * (vid % 6u))) & 0xFu;
    let base = (quad * 4u + corner) * VERTEX_WORDS;
    let rel = vec3<f32>(
        bitcast<f32>(fluid.words[base]),
        bitcast<f32>(fluid.words[base + 1u]),
        bitcast<f32>(fluid.words[base + 2u]),
    );
    let pos = rel + vec3<f32>(f32(fluid.origin.x), 0.0, f32(fluid.origin.z));
    let info = fluid.words[base + 5u];
    let sky = f32((info >> 16u) & 0xFu) / 15.0;
    let blk = f32((info >> 20u) & 0xFu) / 15.0;
    var out: FluidOut;
    out.clip_position = uniforms.view_proj * vec4<f32>(pos, 1.0);
    out.world_pos = pos;
    out.uv = vec2<f32>(bitcast<f32>(fluid.words[base + 3u]), bitcast<f32>(fluid.words[base + 4u]));
    // The same light floor as voxel.wgsl: sky 0.05 to 1, block 0 to 1.
    out.light = max(0.05 + sky * 0.95, blk);
    out.info = info;
    return out;
}

fn fluidHash(p: vec2<u32>) -> f32 {
    var h: u32 = p.x * 1664525u + p.y * 1013904223u + 0x9E3779B9u;
    h ^= h >> 16u;
    h *= 2246822519u;
    h ^= h >> 13u;
    return f32(h & 0xFFu) / 255.0;
}

@fragment
fn fs_fluid(in: FluidOut) -> @location(0) vec4<f32> {
    let face = (in.info >> 8u) & 7u;
    // The top is the brightest face, the bottom the darkest.
    var shade = 0.8;
    if (face == 2u) {
        shade = 1.0;
    } else if (face == 3u) {
        shade = 0.6;
    }
    // A still 8×8 pattern in the uv of the quad. The flow UVs turn it
    // along the flow (REQ-VOXEL-016).
    let texel = vec2<u32>(floor(fract(in.uv) * 8.0));
    let ripple = 0.92 + fluidHash(texel) * 0.16;
    let water = vec3<f32>(0.17, 0.38, 0.75);
    let base = water * shade * ripple * in.light;

    let sky = vec3<f32>(0.5, 0.7, 1.0);
    let dist = length(in.world_pos - uniforms.camera_pos);
    let fog_t = clamp((dist - uniforms.fog_start) / (uniforms.fog_end - uniforms.fog_start), 0.0, 1.0);
    return vec4<f32>(mix(base, sky, fog_t), mix(0.7, 1.0, fog_t));
}
