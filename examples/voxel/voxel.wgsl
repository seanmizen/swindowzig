// Voxel shader with per-face lighting

struct Uniforms {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    _padding: f32,
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
};

// Block type colors
fn getBlockColor(block_type: u32) -> vec3<f32> {
    switch block_type {
        case 1u: { // Grass (special: green top, dirt sides)
            return vec3<f32>(0.4, 0.8, 0.2); // Green (will be modulated by normal)
        }
        case 2u: { // Dirt
            return vec3<f32>(0.6, 0.4, 0.2); // Brown
        }
        case 3u: { // Stone
            return vec3<f32>(0.5, 0.5, 0.5); // Gray
        }
        default: {
            return vec3<f32>(1.0, 0.0, 1.0); // Magenta (error color)
        }
    }
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    out.world_pos = in.position;
    out.clip_position = uniforms.view_proj * vec4<f32>(in.position, 1.0);
    out.normal = in.normal;

    // Get base color
    var base_color = getBlockColor(in.block_type);

    // Special handling for grass: green on top, dirt on sides
    if (in.block_type == 1u && in.normal.y < 0.5) {
        base_color = vec3<f32>(0.6, 0.4, 0.2); // Dirt color for sides
    }

    out.color = base_color;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Simple directional lighting
    let light_dir = normalize(vec3<f32>(0.5, 1.0, 0.3));
    let ambient = 0.4;
    let diffuse = max(dot(in.normal, light_dir), 0.0) * 0.6;
    let brightness = ambient + diffuse;

    let final_color = in.color * brightness;

    return vec4<f32>(final_color, 1.0);
}
