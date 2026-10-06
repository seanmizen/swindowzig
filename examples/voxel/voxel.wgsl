// Voxel shader with per-face lighting and hover outline

struct Uniforms {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    _padding: f32,
    hover_block: vec3<f32>,
    hover_active: f32, // 1.0 if a block is hovered, 0.0 otherwise
    fog_start: f32,    // distance at which fog begins
    fog_end: f32,      // distance at which fog is fully opaque (sky colour)
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) block_type: u32,
    @location(3) uv: vec2<f32>,
    @location(4) ao: f32,
    @location(5) skylight: f32,
    @location(6) block_light: f32,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
    @location(3) alpha: f32,
    @location(4) highlight: f32,
    @location(5) uv: vec2<f32>,
    @location(6) ao: f32,
    @location(7) skylight: f32,
    @location(8) block_light: f32,
    // Block type, lower 16 bits only. fs_main picks the texture rules from it.
    @location(9) @interpolate(flat) block_type: u32,
};

// Block type colors
fn getBlockColor(block_type: u32) -> vec3<f32> {
    switch block_type {
        case 1u: { // Grass (green top, dirt sides handled in vertex shader)
            return vec3<f32>(0.4, 0.8, 0.2);
        }
        case 2u: { // Dirt
            return vec3<f32>(0.6, 0.4, 0.2);
        }
        case 3u: { // Stone
            return vec3<f32>(0.5, 0.5, 0.5);
        }
        case 4u: { // Bedrock
            return vec3<f32>(0.3, 0.3, 0.3);
        }
        case 5u: { // Glowstone — warm yellow-gold base; fs_main bumps per-texel variance for chunky pixel art.
            return vec3<f32>(1.0, 0.88, 0.42);
        }
        case 6u: { // Wood / oak log — warm brown bark colour.
            return vec3<f32>(0.45, 0.30, 0.12);
        }
        case 7u: { // Leaves — dark forest green.
            return vec3<f32>(0.18, 0.50, 0.12);
        }
        case 8u: { // Sand — warm sandy yellow.
            return vec3<f32>(0.85, 0.78, 0.48);
        }
        case 99u: { // Debug marker
            return vec3<f32>(1.0, 0.0, 0.0);
        }
        case 100u: { // Player hitbox cylinder
            return vec3<f32>(0.2, 0.85, 0.9);
        }
        case 101u: { // Chunk border wireframe
            return vec3<f32>(0.9, 0.9, 1.0);
        }
        case 102u: { // Spawn point marker
            return vec3<f32>(1.0, 0.1, 0.1);
        }
        default: {
            return vec3<f32>(1.0, 0.0, 1.0); // Magenta = error
        }
    }
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    return shadeVertex(in);
}

// Chunk meshes: one 16-byte packed quad per quad, read from a storage buffer.
// The layout is in mesher.zig (PackedQuad), and mesher.unpackCorner is the
// same decode in Zig: change both together. A draw of quad_count * 6 vertices
// with no vertex or index buffer makes the 2 triangles of each quad.
struct ChunkQuads {
    origin: vec4<i32>, // chunk origin in world blocks: x, unused, z, unused
    quads: array<vec4<u32>>,
};

@group(1) @binding(0) var<storage, read> chunk: ChunkQuads;

// Faces are numbered px, nx, py, ny, pz, nz (0..5). The normal axis is
// face / 2 and the face is positive when face is even. The in-plane axes are
// i (W) and j (H): i = z for x faces, else x. j = z for y faces, else y.
// Per face and corner, the 0/1 step along i and j is 2 bits (i | j << 1),
// 8 bits per face: faces 0-3 in the _A constant, faces 4-5 in _B.
// mesher.zig computes the same constants from face_layouts, and a test checks
// these literals. No arrays: a runtime index into an array costs a copy of
// the array per vertex on some backends.
const FACE_POS_A: u32 = 0xd2782d78u;
const FACE_POS_B: u32 = 0x0000e1b4u;
const FACE_UV_A: u32 = 0x78787878u;
const FACE_UV_B: u32 = 0x0000b4b4u;
// The 2 triangles of a quad: corners 0,1,2 and 0,2,3, 2 bits per vertex.
const TRI_CORNERS: u32 = 0x00000e24u;

fn axisVec(axis: u32) -> vec3<f32> {
    return vec3<f32>(f32(axis == 0u), f32(axis == 1u), f32(axis == 2u));
}

fn cornerStep(a: u32, b: u32, face: u32, corner: u32) -> vec2<f32> {
    let bits = select(b >> ((face - 4u) * 8u), a >> (face * 8u), face < 4u) >> (corner * 2u);
    return vec2<f32>(f32(bits & 1u), f32((bits >> 1u) & 1u));
}

fn lightField(q: vec4<u32>, i: u32) -> u32 {
    let word = select(select(q.w, q.z, i < 10u), q.y, i < 5u);
    return (word >> (6u * (i % 5u))) & 0x3Fu;
}

@vertex
fn vs_chunk(@builtin(vertex_index) vi: u32) -> VertexOutput {
    let q = chunk.quads[vi / 6u];
    let corner = (TRI_CORNERS >> ((vi % 6u) * 2u)) & 3u;
    let face = (q.x >> 16u) & 0x7u;
    let w = f32(((q.x >> 19u) & 0xFu) + 1u);
    let h = f32(((q.x >> 23u) & 0xFFu) + 1u);
    let normal_axis = face / 2u;
    let positive = (face & 1u) == 0u;
    let i_axis = select(0u, 2u, normal_axis == 0u);
    let j_axis = select(1u, 2u, normal_axis == 1u);
    let n = axisVec(normal_axis);

    let cell = vec3<f32>(
        f32(i32(q.x & 0xFu) + chunk.origin.x),
        f32((q.x >> 4u) & 0xFFu),
        f32(i32((q.x >> 12u) & 0xFu) + chunk.origin.z),
    );
    let p = cornerStep(FACE_POS_A, FACE_POS_B, face, corner);
    let t = cornerStep(FACE_UV_A, FACE_UV_B, face, corner);

    var in: VertexInput;
    in.position = cell + select(vec3<f32>(0.0), n, positive) + axisVec(i_axis) * (p.x * w) + axisVec(j_axis) * (p.y * h);
    in.normal = select(-n, n, positive);
    in.block_type = ((q.w >> 12u) & 0xFFu) | (((q.w >> 20u) & 0xFFu) << 16u);
    in.uv = vec2<f32>(t.x * w, t.y * h);
    in.ao = f32(lightField(q, corner)) / 42.0;
    in.skylight = f32(lightField(q, 4u + corner)) / 60.0;
    in.block_light = f32(lightField(q, 8u + corner)) / 60.0;
    return shadeVertex(in);
}

fn shadeVertex(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    out.world_pos = in.position;
    out.clip_position = uniforms.view_proj * vec4<f32>(in.position, 1.0);
    out.normal = in.normal;

    // Upper 16 bits = highlight intensity (0–255), lower 16 bits = actual block type.
    // GPU debug mode encodes highlight at upload time; when off, upper bits are 0.
    let block_type = in.block_type & 0xFFFFu;
    out.highlight = f32((in.block_type >> 16u) & 0xFFu) / 255.0;

    var base_color = getBlockColor(block_type);

    // Grass: green on top, dirt color on sides
    if (block_type == 1u && in.normal.y < 0.5) {
        base_color = vec3<f32>(0.6, 0.4, 0.2);
    }

    if (block_type == 99u) {
        base_color = vec3<f32>(1.0, 0.0, 0.0);
    }

    out.color = base_color;
    out.alpha = select(1.0, 0.2, block_type == 100u || block_type == 101u || block_type == 102u);
    out.uv = in.uv;
    out.ao = in.ao;
    out.skylight = in.skylight;
    out.block_light = in.block_light;
    out.block_type = block_type;
    return out;
}

// Deterministic hash for a 2D integer texel coordinate → [0, 1].
// Two rounds of xorshift-multiply gives good avalanche with no visible
// patterns at 16x16 block resolution. `seed` selects one pattern per block
// (blockSeed). Seed 0 gives the pattern of the CPU port in main.zig.
fn texelHash(p: vec2<u32>, seed: u32) -> f32 {
    var h: u32 = p.x * 1664525u + p.y * 1013904223u + (seed ^ 0xDEADBEEFu);
    h ^= h >> 16u;
    h *= 2246822519u;
    h ^= h >> 13u;
    h *= 3266489917u;
    h ^= h >> 16u;
    return f32(h & 0xFFu) / 255.0;
}

// A 32-bit hash of a block position. Two blocks of the same type get
// different texel patterns from it.
fn blockSeed(b: vec3<i32>) -> u32 {
    var h: u32 = (u32(b.x) * 73856093u) ^ (u32(b.y) * 19349663u) ^ (u32(b.z) * 83492791u);
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    h ^= h >> 16u;
    return h;
}

// Turn texel `t` of a 16x16 grid by r * 90 degrees (r in 0..3).
fn rotateTexel(t: vec2<u32>, r: u32) -> vec2<u32> {
    switch r {
        case 1u: { return vec2<u32>(15u - t.y, t.x); }
        case 2u: { return vec2<u32>(15u - t.x, 15u - t.y); }
        case 3u: { return vec2<u32>(t.y, 15u - t.x); }
        default: { return t; }
    }
}

// Smooth 2D value noise in [0, 1], one lattice point per `cell` blocks.
// The colour tint of grass and leaves uses it, so the tint changes slowly
// over tens of blocks.
fn valueNoise(p: vec2<f32>, cell: f32) -> f32 {
    let q = p / cell;
    let i = floor(q);
    let f = q - i;
    let u = f * f * (3.0 - 2.0 * f);
    let c = vec2<u32>(vec2<i32>(i));
    let a = texelHash(c, 0x5EEDu);
    let b = texelHash(c + vec2<u32>(1u, 0u), 0x5EEDu);
    let d = texelHash(c + vec2<u32>(0u, 1u), 0x5EEDu);
    let e = texelHash(c + vec2<u32>(1u, 1u), 0x5EEDu);
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// How much to fade a hashed texel pattern toward its mean (0.5), from the
// texel coordinate `t` of that pattern. fwidth(t) is the number of texels
// that one pixel covers. At one texel or less the pattern stays as it is.
// Above that, one pixel samples a single texel out of many, so the hash
// aliases into moiré. The fade gets to 1 (the plain mean) at 3 texels.
// fwidth must run in uniform control flow, so call this before any branch.
fn texelNoiseFade(t: vec2<f32>) -> f32 {
    let fw = fwidth(t);
    return smoothstep(1.0, 3.0, max(fw.x, fw.y));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Texel noise fade for far faces (texelNoiseFade): 16x16 grid and the
    // glowstone 4x4 grid. Near faces do not change. fwidth needs uniform
    // control flow, so these come before the hover branch, which can return.
    // Take the derivative of uv and not of fract(uv): fract jumps at block
    // edges on merged faces, and the jump would give a false fade.
    let fine_fade = texelNoiseFade(in.uv * 16.0);
    let coarse_fade = texelNoiseFade(in.uv * 4.0);

    // Hover outline: detect if this fragment is on the hovered block's face edge
    if (uniforms.hover_active > 0.5) {
        // Recover block coordinate from world position and face normal.
        // For a face with outward normal n, the block is at floor(world_pos - max(0, n)).
        let block_coord = floor(in.world_pos - max(vec3f(0.0), in.normal));
        let is_hovered = all(block_coord == uniforms.hover_block);

        if (is_hovered) {
            // Edge detection: check fractional position on the two axes perpendicular to normal.
            let f = fract(in.world_pos);
            let n_abs = abs(in.normal);
            let t = 0.07; // Edge thickness (fraction of block face)

            let edge_x = (f.x < t || f.x > (1.0 - t)) && n_abs.x < 0.5;
            let edge_y = (f.y < t || f.y > (1.0 - t)) && n_abs.y < 0.5;
            let edge_z = (f.z < t || f.z > (1.0 - t)) && n_abs.z < 0.5;

            if (edge_x || edge_y || edge_z) {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0); // Black outline
            }
        }
    }

    // Minecraft-style procedural texel noise.
    // Subdivide each block face into a 16x16 grid; hash each cell to a
    // deterministic brightness offset so the face looks like a low-res
    // pixel-art texture. No shimmer — hash is position-only, not time-based.
    //
    // Greedy-mesh tiling: merged faces span multiple blocks, so `uv` is in
    // [0, w] × [0, h] rather than [0, 1] × [0, 1]. `fract` wraps the texel
    // coordinate back into a 16-texel grid per unit block, so the same noise
    // pattern tiles correctly across a merged face. Naive 1×1 quads have uv
    // in [0, 1]² so `fract(uv) == uv` and the rendered output is byte-identical
    // to the pre-greedy shader.
    //
    // Far faces: the noise fades toward its mean (fine_fade, at the top of
    // this function).
    //
    // Per-block variation: the block position seeds the hash, so two blocks
    // of the same type do not look the same. A merged face also gets one
    // pattern per block. The block is one half step in from the face along
    // the normal. A floor of exactly the face plane can give the wrong block
    // when interpolation puts world_pos a little below an integer.
    let block_pos = vec3<i32>(floor(in.world_pos - in.normal * 0.5));
    let seed = blockSeed(block_pos);
    let is_grass_top = in.block_type == 1u && in.normal.y > 0.5;
    // Grass tops, dirt, stone and sand turn their pattern by 0, 90, 180 or
    // 270 degrees, from the top 2 bits of the seed.
    let turns = in.block_type == 2u || in.block_type == 3u || in.block_type == 8u || is_grass_top;
    let texel = rotateTexel(vec2<u32>(floor(fract(in.uv) * 16.0)), select(0u, seed >> 30u, turns));
    let noise = mix(texelHash(texel, seed), 0.5, fine_fade);
    // Map [0,1] → [0.875, 1.125]: ±12.5% brightness variation per texel.
    var texel_brightness = 0.875 + noise * 0.25;

    // Glowstone distinctive look: a coarser 4×4 grid and wider brightness
    // variance give the face a chunky, molten-cluster pixel-art pattern.
    if (in.block_type == 5u) {
        let coarse = vec2<u32>(floor(fract(in.uv) * 4.0));
        // The 4x4 pattern fades at its own scale (coarse_fade).
        let n2 = mix(texelHash(coarse + vec2<u32>(7u, 13u), seed), 0.5, coarse_fade);
        // Wider ±25% variance across big 4×4 chunks. Layer on the fine 16×16
        // noise at reduced amplitude so single texels still shimmer subtly.
        texel_brightness = 0.75 + n2 * 0.5 + (noise - 0.5) * 0.08;
    }

    // Directional lighting
    let light_dir = normalize(vec3<f32>(0.5, 1.0, 0.3));
    let ambient = 0.4;
    let diffuse = max(dot(in.normal, light_dir), 0.0) * 0.6;
    let brightness = ambient + diffuse;

    // Ambient occlusion: map 0..1 → 0.55..1.0 (raised floor reduces harsh MSAA blends)
    let ao_brightness = 0.55 + in.ao * 0.45;

    // Skylight: per-vertex sky brightness baked at mesh time. Map 0..1 → 0.05..1.0
    // so a fully shadowed cave wall is dim (≈5%) but not literally black —
    // a 0.0 floor would make caves unplayable until block-light lands. The
    // 0.05 floor matches vanilla Minecraft's "minimum brightness" intuition.
    let sky_brightness = 0.05 + in.skylight * 0.95;

    // Block light: phase-3 per-vertex emitter light (glowstone). Unlike sky,
    // block light has no floor on its own — a cell with no emitter nearby
    // contributes 0 to this channel, and the sky floor (0.05) provides the
    // global "can see your hand in a cave" minimum. A glowstone cell's face
    // reads owner_level=1.0, so the face lights up to full 1.0.
    let block_brightness = in.block_light;

    // Combine: sky and block light compete for maximum brightness; neither
    // "adds" to the other. This matches the Minecraft Wiki formula
    //     final = max(sky_nibble * day_curve, block_nibble) / 15
    // and ensures a glowstone buried in a cave still renders bright even
    // though the sky channel is near zero there.
    let world_light = max(sky_brightness, block_brightness);

    // Grass tops and leaves: a slow colour tint over tens of blocks, from
    // dry yellow-green to deep green. It is constant on each block.
    var color = in.color;
    if (is_grass_top || in.block_type == 7u) {
        let lush = valueNoise(vec2<f32>(block_pos.xz) + 0.5, 24.0);
        color *= mix(vec3<f32>(1.22, 0.98, 0.80), vec3<f32>(0.82, 1.02, 1.12), lush);
    }

    // GPU debug: mix in orange tint for freshly rebuilt quads
    let base = color * brightness * texel_brightness * ao_brightness * world_light;
    let highlighted = mix(base, vec3<f32>(1.0, 0.5, 0.1), in.highlight * 0.6);

    // Distance fog: fade to sky colour before the render distance cutoff.
    let sky = vec3<f32>(0.5, 0.7, 1.0);
    let dist = length(in.world_pos - uniforms.camera_pos);
    let fog_t = clamp((dist - uniforms.fog_start) / (uniforms.fog_end - uniforms.fog_start), 0.0, 1.0);
    let final_color = mix(highlighted, sky, fog_t);

    return vec4<f32>(final_color, in.alpha);
}
