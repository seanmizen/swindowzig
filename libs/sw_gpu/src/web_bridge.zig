//! Web WebGPU Bridge (JavaScript)
//! Source: W3C WebGPU Specification (https://www.w3.org/TR/webgpu/)
//!
//! This file provides Zig bindings to the browser's WebGPU API via JavaScript.
//! These extern functions are implemented in backends/wasm/webgpu.ts

const std = @import("std");
const types = @import("types.zig");

// =============================================================================
// Handle Types for Web
// =============================================================================
// On web, these are opaque JavaScript objects passed through WASM boundary

pub const WebGPUAdapter = u32; // JS object handle
pub const WebGPUDevice = u32;
pub const WebGPUQueue = u32;
pub const WebGPUBuffer = u32;
pub const WebGPUTexture = u32;
pub const WebGPUTextureView = u32;
pub const WebGPUSampler = u32;
pub const WebGPUBindGroupLayout = u32;
pub const WebGPUBindGroup = u32;
pub const WebGPUPipelineLayout = u32;
pub const WebGPUShaderModule = u32;
pub const WebGPURenderPipeline = u32;
pub const WebGPUComputePipeline = u32;
pub const WebGPUCommandEncoder = u32;
pub const WebGPURenderPassEncoder = u32;
pub const WebGPUComputePassEncoder = u32;
pub const WebGPUCommandBuffer = u32;

// =============================================================================
// JavaScript WebGPU API Functions
// =============================================================================
// These are implemented in backends/wasm/webgpu.ts and exported to WASM
// The "webgpu" namespace groups all WebGPU-related imports

// Initialization
pub extern "webgpu" fn webgpuInit() void;
pub extern "webgpu" fn webgpuRequestAdapter() WebGPUAdapter;
pub extern "webgpu" fn webgpuRequestDevice(adapter: WebGPUAdapter) WebGPUDevice;
pub extern "webgpu" fn webgpuGetQueue(device: WebGPUDevice) WebGPUQueue;

// Buffer Operations
pub extern "webgpu" fn webgpuCreateBuffer(
    device: WebGPUDevice,
    size: u64,
    usage: u32, // BufferUsage flags
    mapped_at_creation: bool,
) WebGPUBuffer;

pub extern "webgpu" fn webgpuBufferGetMappedRange(
    buffer: WebGPUBuffer,
    offset: u64,
    size: u64,
) u32; // Returns handle to ArrayBuffer

pub extern "webgpu" fn webgpuBufferUnmap(buffer: WebGPUBuffer) void;
pub extern "webgpu" fn webgpuBufferDestroy(buffer: WebGPUBuffer) void;

pub extern "webgpu" fn webgpuWriteBuffer(
    queue: WebGPUQueue,
    buffer: WebGPUBuffer,
    buffer_offset: u64,
    data_ptr: [*]const u8,
    data_size: u64,
) void;

// Texture Operations
pub extern "webgpu" fn webgpuCreateTexture(
    device: WebGPUDevice,
    width: u32,
    height: u32,
    depth: u32,
    format: u32, // TextureFormat enum value
    usage: u32, // TextureUsage flags
    mip_levels: u32,
    sample_count: u32,
) WebGPUTexture;

pub extern "webgpu" fn webgpuCreateTextureView(
    texture: WebGPUTexture,
    format: u32, // TextureFormat or 0 for default
    dimension: u32, // TextureViewDimension
    aspect: u32, // TextureAspect
    base_mip_level: u32,
    mip_level_count: u32,
    base_array_layer: u32,
    array_layer_count: u32,
) WebGPUTextureView;

pub extern "webgpu" fn webgpuTextureDestroy(texture: WebGPUTexture) void;

pub extern "webgpu" fn webgpuWriteTexture(
    queue: WebGPUQueue,
    texture: WebGPUTexture,
    mip_level: u32,
    origin_x: u32,
    origin_y: u32,
    origin_z: u32,
    width: u32,
    height: u32,
    depth: u32,
    data_ptr: [*]const u8,
    data_size: u64,
    bytes_per_row: u32,
    rows_per_image: u32,
) void;

// Sampler Operations
pub extern "webgpu" fn webgpuCreateSampler(
    device: WebGPUDevice,
    address_mode_u: u32,
    address_mode_v: u32,
    address_mode_w: u32,
    mag_filter: u32,
    min_filter: u32,
    mipmap_filter: u32,
    lod_min: f32,
    lod_max: f32,
    compare: u32, // CompareFunction or 0 for none
) WebGPUSampler;

// Shader Operations
pub extern "webgpu" fn webgpuCreateShaderModule(
    device: WebGPUDevice,
    code_ptr: [*]const u8,
    code_len: u32,
) WebGPUShaderModule;

// Bind Group Layout Operations
pub extern "webgpu" fn webgpuCreateBindGroupLayout(
    device: WebGPUDevice,
    entries_ptr: [*]const BindGroupLayoutEntryJS,
    entry_count: u32,
) WebGPUBindGroupLayout;

// JavaScript-compatible bind group layout entry
pub const BindGroupLayoutEntryJS = extern struct {
    binding: u32,
    visibility: u32, // ShaderStage flags

    // Buffer binding (if buffer_type != 0)
    buffer_type: u32, // 0=none, 1=uniform, 2=storage, 3=read-only-storage
    // NOTE: Was `bool` but Zig's debug mode fills the 3 padding bytes with
    // 0xAA, and the JS DataView.getUint32 reader sees `0xAAAAAA00` which
    // is nonzero → reads as true. Widen to u32 so the wire format is a
    // full 4-byte 0/1 with no undef padding.
    buffer_has_dynamic_offset: u32,
    buffer_min_binding_size: u64,

    // Sampler binding (if sampler_type != 0)
    sampler_type: u32, // 0=none, 1=filtering, 2=non-filtering, 3=comparison

    // Texture binding (if texture_sample_type != 0)
    texture_sample_type: u32, // 0=none, 1=float, 2=unfilterable-float, 3=depth, 4=sint, 5=uint
    texture_view_dimension: u32,
    texture_multisampled: u32, // u32 for the same reason as buffer_has_dynamic_offset.

    // Storage texture binding (if storage_access != 0)
    storage_access: u32, // 0=none, 1=write-only, 2=read-only, 3=read-write
    storage_format: u32,
    storage_view_dimension: u32,
};

// Bind Group Operations
pub extern "webgpu" fn webgpuCreateBindGroup(
    device: WebGPUDevice,
    layout: WebGPUBindGroupLayout,
    entries_ptr: [*]const BindGroupEntryJS,
    entry_count: u32,
) WebGPUBindGroup;

// Field order: u64s first so the C-ABI alignment doesn't insert any
// padding bytes (Zig fills padding with 0xAA in debug, which corrupts
// the JS decoder that sees uninitialised memory through `DataView`).
pub const BindGroupEntryJS = extern struct {
    buffer_offset: u64, // 0
    buffer_size: u64, // 8
    binding: u32, // 16
    resource_type: u32, // 20  (1=buffer, 2=sampler, 3=texture_view)
    buffer: WebGPUBuffer, // 24
    sampler: WebGPUSampler, // 28
    texture_view: WebGPUTextureView, // 32
    _padding: u32, // 36 — trailing alignment padding (align=8 from u64 fields)
    // total = 40 bytes
};

// Pipeline Layout Operations
pub extern "webgpu" fn webgpuCreatePipelineLayout(
    device: WebGPUDevice,
    bind_group_layouts_ptr: [*]const WebGPUBindGroupLayout,
    bind_group_layout_count: u32,
) WebGPUPipelineLayout;

// Render Pipeline Operations
pub extern "webgpu" fn webgpuCreateRenderPipeline(
    device: WebGPUDevice,
    layout: WebGPUPipelineLayout, // 0 for auto layout

    // Vertex stage
    vertex_module: WebGPUShaderModule,
    vertex_entry_ptr: [*]const u8,
    vertex_entry_len: u32,
    vertex_buffers_ptr: [*]const VertexBufferLayoutJS,
    vertex_buffer_count: u32,

    // Primitive state
    topology: u32,
    strip_index_format: u32, // 0=none, 1=uint16, 2=uint32
    front_face: u32, // 0=ccw, 1=cw
    cull_mode: u32, // 0=none, 1=front, 2=back

    // Fragment stage (0 values = no fragment stage)
    fragment_module: WebGPUShaderModule,
    fragment_entry_ptr: [*]const u8,
    fragment_entry_len: u32,
    fragment_targets_ptr: [*]const ColorTargetStateJS,
    fragment_target_count: u32,

    // Depth/stencil (0 = none)
    depth_stencil_format: u32,
    depth_write_enabled: bool,
    depth_compare: u32,

    // Multisample
    sample_count: u32,
    sample_mask: u32,
    alpha_to_coverage_enabled: bool,
) WebGPURenderPipeline;

pub const VertexBufferLayoutJS = extern struct {
    array_stride: u64,
    step_mode: u32, // 0=vertex, 1=instance
    attributes_ptr: [*]const VertexAttributeJS,
    attribute_count: u32,
};

pub const VertexAttributeJS = extern struct {
    offset: u64, // 0  — u64 first so the struct has no padding
    format: u32, // 8  — VertexFormat enum
    shader_location: u32, // 12
    // total = 16 bytes, no padding
};

pub const ColorTargetStateJS = extern struct {
    format: u32, // TextureFormat
    // u32 instead of bool to avoid Zig's 0xAA debug padding leaking
    // into the JS reader.
    blend_enabled: u32,

    // Color blend
    color_operation: u32,
    color_src_factor: u32,
    color_dst_factor: u32,

    // Alpha blend
    alpha_operation: u32,
    alpha_src_factor: u32,
    alpha_dst_factor: u32,

    write_mask: u32, // 0xF for all channels
};

// Compute Pipeline Operations
pub extern "webgpu" fn webgpuCreateComputePipeline(
    device: WebGPUDevice,
    layout: WebGPUPipelineLayout, // 0 for auto layout
    module: WebGPUShaderModule,
    entry_point_ptr: [*]const u8,
    entry_point_len: u32,
) WebGPUComputePipeline;

// Command Encoding
pub extern "webgpu" fn webgpuCreateCommandEncoder(device: WebGPUDevice) WebGPUCommandEncoder;

pub extern "webgpu" fn webgpuCommandEncoderBeginRenderPass(
    encoder: WebGPUCommandEncoder,
    color_attachments_ptr: [*]const RenderPassColorAttachmentJS,
    color_attachment_count: u32,
    depth_stencil_view: WebGPUTextureView, // 0 for none
    depth_load_op: u32,
    depth_store_op: u32,
    depth_clear_value: f32,
    stencil_load_op: u32,
    stencil_store_op: u32,
    stencil_clear_value: u32,
) WebGPURenderPassEncoder;

pub const RenderPassColorAttachmentJS = extern struct {
    view: WebGPUTextureView,
    resolve_target: WebGPUTextureView, // 0 for none
    load_op: u32, // 1=clear, 2=load
    store_op: u32, // 1=store, 2=discard
    clear_r: f64,
    clear_g: f64,
    clear_b: f64,
    clear_a: f64,
};

pub extern "webgpu" fn webgpuCommandEncoderBeginComputePass(
    encoder: WebGPUCommandEncoder,
) WebGPUComputePassEncoder;

pub extern "webgpu" fn webgpuCommandEncoderFinish(
    encoder: WebGPUCommandEncoder,
) WebGPUCommandBuffer;

// Render Pass Encoding
pub extern "webgpu" fn webgpuRenderPassSetPipeline(
    pass: WebGPURenderPassEncoder,
    pipeline: WebGPURenderPipeline,
) void;

pub extern "webgpu" fn webgpuRenderPassSetBindGroup(
    pass: WebGPURenderPassEncoder,
    index: u32,
    bind_group: WebGPUBindGroup,
    dynamic_offsets_ptr: [*]const u32,
    dynamic_offset_count: u32,
) void;

pub extern "webgpu" fn webgpuRenderPassSetVertexBuffer(
    pass: WebGPURenderPassEncoder,
    slot: u32,
    buffer: WebGPUBuffer,
    offset: u64,
    size: u64,
) void;

pub extern "webgpu" fn webgpuRenderPassSetIndexBuffer(
    pass: WebGPURenderPassEncoder,
    buffer: WebGPUBuffer,
    format: u32, // 1=uint16, 2=uint32
    offset: u64,
    size: u64,
) void;

pub extern "webgpu" fn webgpuRenderPassDraw(
    pass: WebGPURenderPassEncoder,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void;

pub extern "webgpu" fn webgpuRenderPassDrawIndexed(
    pass: WebGPURenderPassEncoder,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    first_instance: u32,
) void;

pub extern "webgpu" fn webgpuRenderPassEnd(pass: WebGPURenderPassEncoder) void;

// Compute Pass Encoding
pub extern "webgpu" fn webgpuComputePassSetPipeline(
    pass: WebGPUComputePassEncoder,
    pipeline: WebGPUComputePipeline,
) void;

pub extern "webgpu" fn webgpuComputePassSetBindGroup(
    pass: WebGPUComputePassEncoder,
    index: u32,
    bind_group: WebGPUBindGroup,
    dynamic_offsets_ptr: [*]const u32,
    dynamic_offset_count: u32,
) void;

pub extern "webgpu" fn webgpuComputePassDispatch(
    pass: WebGPUComputePassEncoder,
    workgroup_count_x: u32,
    workgroup_count_y: u32,
    workgroup_count_z: u32,
) void;

pub extern "webgpu" fn webgpuComputePassEnd(pass: WebGPUComputePassEncoder) void;

// Queue Submission
pub extern "webgpu" fn webgpuQueueSubmit(
    queue: WebGPUQueue,
    command_buffers_ptr: [*]const WebGPUCommandBuffer,
    command_buffer_count: u32,
) void;

// Canvas/SwapChain Operations (web-specific)
pub extern "webgpu" fn webgpuGetCurrentTextureView() WebGPUTextureView;
pub extern "webgpu" fn webgpuPresent() void;

// =============================================================================
// Helper Functions
// =============================================================================

/// Initialize WebGPU on the web (must be called once before using WebGPU)
pub fn init() void {
    webgpuInit();
}

/// Convert BufferUsage to JavaScript flags
pub fn bufferUsageToJS(usage: types.BufferUsage) u32 {
    var flags: u32 = 0;
    if (usage.map_read) flags |= 0x0001;
    if (usage.map_write) flags |= 0x0002;
    if (usage.copy_src) flags |= 0x0004;
    if (usage.copy_dst) flags |= 0x0008;
    if (usage.index) flags |= 0x0010;
    if (usage.vertex) flags |= 0x0020;
    if (usage.uniform) flags |= 0x0040;
    if (usage.storage) flags |= 0x0080;
    if (usage.indirect) flags |= 0x0100;
    if (usage.query_resolve) flags |= 0x0200;
    return flags;
}

/// Convert TextureUsage to JavaScript flags
pub fn textureUsageToJS(usage: types.TextureUsage) u32 {
    var flags: u32 = 0;
    if (usage.copy_src) flags |= 0x01;
    if (usage.copy_dst) flags |= 0x02;
    if (usage.texture_binding) flags |= 0x04;
    if (usage.storage_binding) flags |= 0x08;
    if (usage.render_attachment) flags |= 0x10;
    return flags;
}

/// Convert ShaderStage to JavaScript flags
pub fn shaderStageToJS(stage: types.ShaderStage) u32 {
    var flags: u32 = 0;
    if (stage.vertex) flags |= 0x1;
    if (stage.fragment) flags |= 0x2;
    if (stage.compute) flags |= 0x4;
    return flags;
}
