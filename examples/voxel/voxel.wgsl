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

    // Minecraft-style procedural texel noise.
    // Subdivide each block face into a 16x16 grid; hash each cell to a
    // deterministic brightness offset so the face looks like a low-res
    // pixel-art texture. No shimmer — hash is position-only, not time-based.
    let texel = vec2<u32>(floor(in.uv * 16.0));
    let noise = texelHash(texel);
    // Map [0,1] → [0.875, 1.125]: ±12.5% brightness variation per texel.
    let texel_brightness = 0.875 + noise * 0.25;

    // Directional lighting
    let light_dir = normalize(vec3<f32>(0.5, 1.0, 0.3));
    let ambient = 0.4;
    let diffuse = max(dot(in.normal, light_dir), 0.0) * 0.6;
    let brightness = ambient + diffuse;

    // Ambient occlusion: map 0..1 → 0.55..1.0 (raised floor reduces harsh MSAA blends)
    let ao_brightness = 0.55 + in.ao * 0.45;

    // GPU debug: mix in orange tint for freshly rebuilt quads
    let base = in.color * brightness * texel_brightness * ao_brightness;
    let highlighted = mix(base, vec3<f32>(1.0, 0.5, 0.1), in.highlight * 0.6);

    // Distance fog: fade to sky colour before the render distance cutoff.
    let sky = vec3<f32>(0.5, 0.7, 1.0);
    let dist = length(in.world_pos - uniforms.camera_pos);
    let fog_t = clamp((dist - uniforms.fog_start) / (uniforms.fog_end - uniforms.fog_start), 0.0, 1.0);
    let final_color = mix(highlighted, sky, fog_t);

    return vec4<f32>(final_color, in.alpha);
}
