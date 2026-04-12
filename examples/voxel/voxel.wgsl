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
    return out;
}

// Deterministic hash for a 2D integer texel coordinate → [0, 1].
// Two rounds of xorshift-multiply gives good avalanche with no visible
// patterns at 16x16 block resolution.
fn texelHash(p: vec2<u32>) -> f32 {
    var h: u32 = p.x * 1664525u + p.y * 1013904223u + 0xDEADBEEFu;
    h ^= h >> 16u;
    h *= 2246822519u;
    h ^= h >> 13u;
    h *= 3266489917u;
    h ^= h >> 16u;
    return f32(h & 0xFFu) / 255.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
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

    // Block type needed again here (vs_main stripped it out of the VertexOutput).
    // Recover it by checking the color picked upstream; a simpler path is to
    // just bake a per-block texture selector here using a flag we can rebuild
    // from the color channel. For now, check the normal/color heuristic isn't
    // needed — we use UV-hashing with a slightly different pattern when the
    // base colour matches glowstone (yellow-gold dominance).
    //
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
    let texel = vec2<u32>(floor(fract(in.uv) * 16.0));
    let noise = texelHash(texel);
    // Map [0,1] → [0.875, 1.125]: ±12.5% brightness variation per texel.
    var texel_brightness = 0.875 + noise * 0.25;

    // Glowstone distinctive look: detect via base color (bright warm yellow,
    // R≈1.0 G≈0.88 B≈0.42). Use a coarser 4×4 grid and wider brightness
    // variance to give the face a chunky, molten-cluster pixel-art pattern.
    // Kept in the shader so we don't have to thread another "is emissive"
    // vertex attribute — the color channel already encodes the identity.
    let is_glowstone = in.color.r > 0.95 && in.color.g > 0.80 && in.color.b > 0.35 && in.color.b < 0.55;
    if (is_glowstone) {
        let coarse = vec2<u32>(floor(in.uv * 4.0));
        let n2 = texelHash(coarse + vec2<u32>(7u, 13u));
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

    // GPU debug: mix in orange tint for freshly rebuilt quads
    let base = in.color * brightness * texel_brightness * ao_brightness * world_light;
    let highlighted = mix(base, vec3<f32>(1.0, 0.5, 0.1), in.highlight * 0.6);

    // Distance fog: fade to sky colour before the render distance cutoff.
    let sky = vec3<f32>(0.5, 0.7, 1.0);
    let dist = length(in.world_pos - uniforms.camera_pos);
    let fog_t = clamp((dist - uniforms.fog_start) / (uniforms.fog_end - uniforms.fog_start), 0.0, 1.0);
    let final_color = mix(highlighted, sky, fog_t);

    return vec4<f32>(final_color, in.alpha);
}
