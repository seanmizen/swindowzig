//! WebGPU Type Definitions
//! Source: W3C WebGPU Specification (https://www.w3.org/TR/webgpu/)
//! Last synced: 2026-01-29
//!
//! These types match the WebGPU specification exactly to ensure
//! identical behavior on web (JavaScript API) and native (wgpu-native/Dawn).

const std = @import("std");

// =============================================================================
// Opaque Handle Types
// =============================================================================
// NOTE: Handle types (Buffer, Texture, ShaderModule, etc.) are defined in gpu.zig
// as concrete structs wrapping platform-specific handles. We don't define them here
// to avoid duplication and circular dependencies.

// =============================================================================
// Enums
// =============================================================================

/// Texture format (subset - add more as needed)
/// Full list: https://www.w3.org/TR/webgpu/#enumdef-gputextureformat
pub const TextureFormat = enum(u32) {
    // 8-bit formats
    r8unorm = 0x01,
    r8snorm = 0x02,
    r8uint = 0x03,
    r8sint = 0x04,

    // 16-bit formats
    r16uint = 0x05,
    r16sint = 0x06,
    r16float = 0x07,
    rg8unorm = 0x08,
    rg8snorm = 0x09,
    rg8uint = 0x0A,
    rg8sint = 0x0B,

    // 32-bit formats
    r32uint = 0x0C,
    r32sint = 0x0D,
    r32float = 0x0E,
    rg16uint = 0x0F,
    rg16sint = 0x10,
    rg16float = 0x11,
    rgba8unorm = 0x12,
    rgba8unorm_srgb = 0x13,
    rgba8snorm = 0x14,
    rgba8uint = 0x15,
    rgba8sint = 0x16,
    bgra8unorm = 0x17,
    bgra8unorm_srgb = 0x18,

    // Packed 32-bit formats
    rgb10a2unorm = 0x19,

    // 64-bit formats
    rg32uint = 0x1A,
    rg32sint = 0x1B,
    rg32float = 0x1C,
    rgba16uint = 0x1D,
    rgba16sint = 0x1E,
    rgba16float = 0x1F,

    // 128-bit formats
    rgba32uint = 0x20,
    rgba32sint = 0x21,
    rgba32float = 0x22,

    // Depth/stencil formats
    depth32float = 0x2B,
    depth24plus = 0x29,
    depth24plus_stencil8 = 0x2A,

    // BC compressed formats (desktop)
    bc1_rgba_unorm = 0x2C,
    bc1_rgba_unorm_srgb = 0x2D,
    bc4_r_unorm = 0x2E,
    bc4_r_snorm = 0x2F,
    bc5_rg_unorm = 0x30,
    bc5_rg_snorm = 0x31,
};

/// Buffer usage flags (bitfield)
/// Spec: https://www.w3.org/TR/webgpu/#buffer-usage
pub const BufferUsage = packed struct(u32) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _padding: u22 = 0,
};

/// Texture usage flags (bitfield)
/// Spec: https://www.w3.org/TR/webgpu/#texture-usage
pub const TextureUsage = packed struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _padding: u27 = 0,
};

/// Shader stage flags
pub const ShaderStage = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u29 = 0,
};

/// Primitive topology
/// Spec: https://www.w3.org/TR/webgpu/#enumdef-gpuprimitivetopology
pub const PrimitiveTopology = enum(u32) {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

/// Front face orientation
pub const FrontFace = enum(u32) {
    ccw, // counter-clockwise
    cw, // clockwise
};

/// Cull mode
pub const CullMode = enum(u32) {
    none,
    front,
    back,
};

/// Compare function for depth/stencil tests
pub const CompareFunction = enum(u32) {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

/// Blend factor
pub const BlendFactor = enum(u32) {
    zero,
    one,
    src,
    one_minus_src,
    src_alpha,
    one_minus_src_alpha,
    dst,
    one_minus_dst,
    dst_alpha,
    one_minus_dst_alpha,
    src_alpha_saturated,
    constant,
    one_minus_constant,
};

/// Blend operation
pub const BlendOperation = enum(u32) {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

/// Load operation for render pass
pub const LoadOp = enum(u32) {
    clear = 1, // clear to specified value
    load = 2, // preserve existing contents
};

/// Store operation for render pass
pub const StoreOp = enum(u32) {
    store = 1, // save results to attachment
    discard = 2, // discard results
};

/// Index format
pub const IndexFormat = enum(u32) {
    uint16,
    uint32,
};

/// Vertex step mode
pub const VertexStepMode = enum(u32) {
    vertex, // advance per vertex
    instance, // advance per instance
};

/// Vertex format
pub const VertexFormat = enum(u32) {
    uint8x2 = 1,
    uint8x4 = 2,
    sint8x2 = 3,
    sint8x4 = 4,
    unorm8x2 = 5,
    unorm8x4 = 6,
    snorm8x2 = 7,
    snorm8x4 = 8,
    uint16x2 = 9,
    uint16x4 = 10,
    sint16x2 = 11,
    sint16x4 = 12,
    unorm16x2 = 13,
    unorm16x4 = 14,
    snorm16x2 = 15,
    snorm16x4 = 16,
    float16x2 = 17,
    float16x4 = 18,
    float32 = 19,
    float32x2 = 20,
    float32x3 = 21,
    float32x4 = 22,
    uint32 = 23,
    uint32x2 = 24,
    uint32x3 = 25,
    uint32x4 = 26,
    sint32 = 27,
    sint32x2 = 28,
    sint32x3 = 29,
    sint32x4 = 30,
};

/// Texture dimension
pub const TextureDimension = enum(u32) {
    @"1d",
    @"2d",
    @"3d",
};

/// Texture view dimension
pub const TextureViewDimension = enum(u32) {
    @"1d",
    @"2d",
    @"2d-array",
    cube,
    cube_array,
    @"3d",
};

/// Texture aspect
pub const TextureAspect = enum(u32) {
    all,
    stencil_only,
    depth_only,
};

/// Address mode for texture sampling
pub const AddressMode = enum(u32) {
    clamp_to_edge,
    repeat,
    mirror_repeat,
};

/// Filter mode
pub const FilterMode = enum(u32) {
    nearest,
    linear,
};

// =============================================================================
// Descriptor Structs
// =============================================================================
// These describe how to create GPU objects

/// Buffer descriptor
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsage,
    mapped_at_creation: bool = false,
};

/// Texture descriptor
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    size: Extent3D,
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
    dimension: TextureDimension = .@"2d",
    format: TextureFormat,
    usage: TextureUsage,
};

/// Texture view descriptor
pub const TextureViewDescriptor = struct {
    label: ?[]const u8 = null,
    format: ?TextureFormat = null,
    dimension: ?TextureViewDimension = null,
    aspect: TextureAspect = .all,
    base_mip_level: u32 = 0,
    mip_level_count: ?u32 = null,
    base_array_layer: u32 = 0,
    array_layer_count: ?u32 = null,
};

/// Sampler descriptor
pub const SamplerDescriptor = struct {
    label: ?[]const u8 = null,
    address_mode_u: AddressMode = .clamp_to_edge,
    address_mode_v: AddressMode = .clamp_to_edge,
    address_mode_w: AddressMode = .clamp_to_edge,
    mag_filter: FilterMode = .nearest,
    min_filter: FilterMode = .nearest,
    mipmap_filter: FilterMode = .nearest,
    lod_min_clamp: f32 = 0.0,
    lod_max_clamp: f32 = 32.0,
    compare: ?CompareFunction = null,
    max_anisotropy: u16 = 1,
};

/// Shader module descriptor
pub const ShaderModuleDescriptor = struct {
    label: ?[]const u8 = null,
    code: []const u8, // WGSL source code
};

/// Bind group layout entry
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStage,
    buffer: ?BufferBindingLayout = null,
    sampler: ?SamplerBindingLayout = null,
    texture: ?TextureBindingLayout = null,
    storage_texture: ?StorageTextureBindingLayout = null,
};

pub const BufferBindingLayout = struct {
    type: BufferBindingType = .uniform,
    has_dynamic_offset: bool = false,
    min_binding_size: u64 = 0,
};

pub const BufferBindingType = enum(u32) {
    uniform,
    storage,
    read_only_storage,
};

pub const SamplerBindingLayout = struct {
    type: SamplerBindingType = .filtering,
};

pub const SamplerBindingType = enum(u32) {
    filtering,
    non_filtering,
    comparison,
};

pub const TextureBindingLayout = struct {
    sample_type: TextureSampleType = .float,
    view_dimension: TextureViewDimension = .@"2d",
    multisampled: bool = false,
};

pub const TextureSampleType = enum(u32) {
    float,
    unfilterable_float,
    depth,
    sint,
    uint,
};

pub const StorageTextureBindingLayout = struct {
    access: StorageTextureAccess = .write_only,
    format: TextureFormat,
    view_dimension: TextureViewDimension = .@"2d",
};

pub const StorageTextureAccess = enum(u32) {
    write_only,
    read_only,
    read_write,
};

/// Bind group layout descriptor
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

// NOTE: BindGroupEntry, BindGroupDescriptor, and PipelineLayoutDescriptor
// are defined in gpu.zig to reference concrete handle types

/// Vertex attribute
pub const VertexAttribute = struct {
    format: VertexFormat,
    offset: u64,
    shader_location: u32,
};

/// Vertex buffer layout
pub const VertexBufferLayout = struct {
    array_stride: u64,
    step_mode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

// NOTE: VertexState is defined in gpu.zig to reference concrete ShaderModule type

/// Primitive state
pub const PrimitiveState = struct {
    topology: PrimitiveTopology = .triangle_list,
    strip_index_format: ?IndexFormat = null,
    front_face: FrontFace = .ccw,
    cull_mode: CullMode = .none,
};

/// Blend component
pub const BlendComponent = struct {
    operation: BlendOperation = .add,
    src_factor: BlendFactor = .one,
    dst_factor: BlendFactor = .zero,
};

/// Blend state
pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

/// Color target state
pub const ColorTargetState = struct {
    format: TextureFormat,
    blend: ?BlendState = null,
    write_mask: u32 = 0xF, // all channels
};

// NOTE: FragmentState is defined in gpu.zig to reference concrete ShaderModule type

/// Depth stencil state
pub const DepthStencilState = struct {
    format: TextureFormat,
    depth_write_enabled: bool = false,
    depth_compare: CompareFunction = .always,
    stencil_front: StencilFaceState = .{},
    stencil_back: StencilFaceState = .{},
    stencil_read_mask: u32 = 0xFFFFFFFF,
    stencil_write_mask: u32 = 0xFFFFFFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
};

pub const StencilFaceState = struct {
    compare: CompareFunction = .always,
    fail_op: StencilOperation = .keep,
    depth_fail_op: StencilOperation = .keep,
    pass_op: StencilOperation = .keep,
};

pub const StencilOperation = enum(u32) {
    keep,
    zero,
    replace,
    invert,
    increment_clamp,
    decrement_clamp,
    increment_wrap,
    decrement_wrap,
};

pub const MultisampleState = struct {
    count: u32 = 1,
    mask: u32 = 0xFFFFFFFF,
    alpha_to_coverage_enabled: bool = false,
};

// NOTE: RenderPipelineDescriptor, ComputePipelineDescriptor, ComputeState,
// RenderPassColorAttachment, RenderPassDepthStencilAttachment, and
// RenderPassDescriptor are defined in gpu.zig to reference concrete handle types

/// Compute pass descriptor
pub const ComputePassDescriptor = struct {
    label: ?[]const u8 = null,
};

// =============================================================================
// Common Structs
// =============================================================================

/// 3D extent (width, height, depth)
pub const Extent3D = struct {
    width: u32,
    height: u32 = 1,
    depth_or_array_layers: u32 = 1,
};

/// Origin 3D (x, y, z)
pub const Origin3D = struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

/// Color (RGBA, 0.0-1.0)
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

// NOTE: ImageCopyBuffer and ImageCopyTexture are defined in gpu.zig to reference concrete handle types

// =============================================================================
// Utility Functions
// =============================================================================

/// Calculate aligned size for uniform buffers (must be 256-byte aligned on many GPUs)
pub fn alignedUniformSize(size: u64) u64 {
    const alignment = 256;
    return (size + alignment - 1) / alignment * alignment;
}

/// Get bytes per pixel for a texture format
pub fn bytesPerPixel(format: TextureFormat) u32 {
    return switch (format) {
        .r8unorm, .r8snorm, .r8uint, .r8sint => 1,
        .r16uint, .r16sint, .r16float, .rg8unorm, .rg8snorm, .rg8uint, .rg8sint => 2,
        .r32uint, .r32sint, .r32float, .rg16uint, .rg16sint, .rg16float, .rgba8unorm, .rgba8unorm_srgb, .rgba8snorm, .rgba8uint, .rgba8sint, .bgra8unorm, .bgra8unorm_srgb, .rgb10a2unorm => 4,
        .rg32uint, .rg32sint, .rg32float, .rgba16uint, .rgba16sint, .rgba16float => 8,
        .rgba32uint, .rgba32sint, .rgba32float => 16,
        .depth32float, .depth24plus, .depth24plus_stencil8 => 4,
        else => 4, // compressed formats vary
    };
}
