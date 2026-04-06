// Voxel shader with per-face lighting and hover outline

struct Uniforms {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    _padding: f32,
    hover_block: vec3<f32>,
    hover_active: f32, // 1.0 if a block is hovered, 0.0 otherwise
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) block_type: u32,
    @location(3) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
    @location(3) alpha: f32,
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
        case 99u: { // Debug marker
            return vec3<f32>(1.0, 0.0, 0.0);
        }
        case 100u: { // Player hitbox cylinder
            return vec3<f32>(0.2, 0.85, 0.9);
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

    var base_color = getBlockColor(in.block_type);

    // Grass: green on top, dirt color on sides
    if (in.block_type == 1u && in.normal.y < 0.5) {
        base_color = vec3<f32>(0.6, 0.4, 0.2);
    }

    if (in.block_type == 99u) {
        base_color = vec3<f32>(1.0, 0.0, 0.0);
    }

    out.color = base_color;
    out.alpha = select(1.0, 0.2, in.block_type == 100u);
    return out;
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

    // Directional lighting
    let light_dir = normalize(vec3<f32>(0.5, 1.0, 0.3));
    let ambient = 0.4;
    let diffuse = max(dot(in.normal, light_dir), 0.0) * 0.6;
    let brightness = ambient + diffuse;

    return vec4<f32>(in.color * brightness, in.alpha);
}
