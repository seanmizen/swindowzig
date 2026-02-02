//! Native WebGPU Bindings (wgpu-native / Dawn)
//! Source: https://github.com/webgpu-native/webgpu-headers
//!
//! This file provides Zig bindings to the WebGPU C API (webgpu.h).
//! It works with both wgpu-native (Rust) and Dawn (Google C++).

const std = @import("std");
const types = @import("types.zig");

// =============================================================================
// C Type Mappings
// =============================================================================
// WebGPU C API uses WGPU prefix for all types

pub const WGPUInstance = ?*opaque {};
pub const WGPUAdapter = ?*opaque {};
pub const WGPUDevice = ?*opaque {};
pub const WGPUQueue = ?*opaque {};
pub const WGPUBuffer = ?*opaque {};
pub const WGPUTexture = ?*opaque {};
pub const WGPUTextureView = ?*opaque {};
pub const WGPUSampler = ?*opaque {};
pub const WGPUBindGroupLayout = ?*opaque {};
pub const WGPUBindGroup = ?*opaque {};
pub const WGPUPipelineLayout = ?*opaque {};
pub const WGPUShaderModule = ?*opaque {};
pub const WGPURenderPipeline = ?*opaque {};
pub const WGPUComputePipeline = ?*opaque {};
pub const WGPUCommandEncoder = ?*opaque {};
pub const WGPURenderPassEncoder = ?*opaque {};
pub const WGPUComputePassEncoder = ?*opaque {};
pub const WGPUCommandBuffer = ?*opaque {};
pub const WGPUQuerySet = ?*opaque {};
pub const WGPUSurface = ?*opaque {};
pub const WGPUSwapChain = ?*opaque {}; // Deprecated, kept for compatibility

// =============================================================================
// C API Function Declarations
// =============================================================================
// These match webgpu.h exactly. Link with wgpu-native or Dawn library.

// Instance & Adapter
pub extern fn wgpuCreateInstance(descriptor: ?*const WGPUInstanceDescriptor) WGPUInstance;
pub extern fn wgpuInstanceRequestAdapter(
    instance: WGPUInstance,
    options: ?*const WGPURequestAdapterOptions,
    callback: WGPURequestAdapterCallback,
    userdata: ?*anyopaque,
) void;

// Device
pub extern fn wgpuAdapterRequestDevice(
    adapter: WGPUAdapter,
    descriptor: ?*const WGPUDeviceDescriptor,
    callback: WGPURequestDeviceCallback,
    userdata: ?*anyopaque,
) void;
pub extern fn wgpuDeviceGetQueue(device: WGPUDevice) WGPUQueue;
pub extern fn wgpuDevicePoll(device: WGPUDevice, wait: u32, wrapped_submission_index: ?*const anyopaque) u32;

// Buffer
pub extern fn wgpuDeviceCreateBuffer(device: WGPUDevice, descriptor: *const WGPUBufferDescriptor) WGPUBuffer;
pub extern fn wgpuBufferGetMappedRange(buffer: WGPUBuffer, offset: usize, size: usize) ?*anyopaque;
pub extern fn wgpuBufferUnmap(buffer: WGPUBuffer) void;
pub extern fn wgpuBufferDestroy(buffer: WGPUBuffer) void;

// Texture
pub extern fn wgpuDeviceCreateTexture(device: WGPUDevice, descriptor: *const WGPUTextureDescriptor) WGPUTexture;
pub extern fn wgpuTextureCreateView(texture: WGPUTexture, descriptor: ?*const WGPUTextureViewDescriptor) WGPUTextureView;
pub extern fn wgpuTextureDestroy(texture: WGPUTexture) void;
pub extern fn wgpuTextureRelease(texture: WGPUTexture) void;
pub extern fn wgpuTextureViewRelease(view: WGPUTextureView) void;

// Sampler
pub extern fn wgpuDeviceCreateSampler(device: WGPUDevice, descriptor: *const WGPUSamplerDescriptor) WGPUSampler;

// Shader
pub extern fn wgpuDeviceCreateShaderModule(device: WGPUDevice, descriptor: *const WGPUShaderModuleDescriptor) WGPUShaderModule;

// Bind Groups
pub extern fn wgpuDeviceCreateBindGroupLayout(device: WGPUDevice, descriptor: *const WGPUBindGroupLayoutDescriptor) WGPUBindGroupLayout;
pub extern fn wgpuDeviceCreateBindGroup(device: WGPUDevice, descriptor: *const WGPUBindGroupDescriptor) WGPUBindGroup;
pub extern fn wgpuDeviceCreatePipelineLayout(device: WGPUDevice, descriptor: *const WGPUPipelineLayoutDescriptor) WGPUPipelineLayout;

// Pipelines
pub extern fn wgpuDeviceCreateRenderPipeline(device: WGPUDevice, descriptor: *const WGPURenderPipelineDescriptor) WGPURenderPipeline;
pub extern fn wgpuDeviceCreateComputePipeline(device: WGPUDevice, descriptor: *const WGPUComputePipelineDescriptor) WGPUComputePipeline;

// Command Encoding
pub extern fn wgpuDeviceCreateCommandEncoder(device: WGPUDevice, descriptor: ?*const WGPUCommandEncoderDescriptor) WGPUCommandEncoder;
pub extern fn wgpuCommandEncoderBeginRenderPass(encoder: WGPUCommandEncoder, descriptor: *const WGPURenderPassDescriptor) WGPURenderPassEncoder;
pub extern fn wgpuCommandEncoderBeginComputePass(encoder: WGPUCommandEncoder, descriptor: ?*const WGPUComputePassDescriptor) WGPUComputePassEncoder;
pub extern fn wgpuCommandEncoderFinish(encoder: WGPUCommandEncoder, descriptor: ?*const WGPUCommandBufferDescriptor) WGPUCommandBuffer;
pub extern fn wgpuCommandEncoderRelease(encoder: WGPUCommandEncoder) void;
pub extern fn wgpuCommandBufferRelease(buffer: WGPUCommandBuffer) void;

// Render Pass
pub extern fn wgpuRenderPassEncoderSetPipeline(pass: WGPURenderPassEncoder, pipeline: WGPURenderPipeline) void;
pub extern fn wgpuRenderPassEncoderSetBindGroup(pass: WGPURenderPassEncoder, group_index: u32, group: WGPUBindGroup, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void;
pub extern fn wgpuRenderPassEncoderSetVertexBuffer(pass: WGPURenderPassEncoder, slot: u32, buffer: WGPUBuffer, offset: u64, size: u64) void;
pub extern fn wgpuRenderPassEncoderSetIndexBuffer(pass: WGPURenderPassEncoder, buffer: WGPUBuffer, format: WGPUIndexFormat, offset: u64, size: u64) void;
pub extern fn wgpuRenderPassEncoderDraw(pass: WGPURenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
pub extern fn wgpuRenderPassEncoderDrawIndexed(pass: WGPURenderPassEncoder, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void;
pub extern fn wgpuRenderPassEncoderEnd(pass: WGPURenderPassEncoder) void;
pub extern fn wgpuRenderPassEncoderRelease(pass: WGPURenderPassEncoder) void;

// Compute Pass
pub extern fn wgpuComputePassEncoderSetPipeline(pass: WGPUComputePassEncoder, pipeline: WGPUComputePipeline) void;
pub extern fn wgpuComputePassEncoderSetBindGroup(pass: WGPUComputePassEncoder, group_index: u32, group: WGPUBindGroup, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void;
pub extern fn wgpuComputePassEncoderDispatchWorkgroups(pass: WGPUComputePassEncoder, workgroup_count_x: u32, workgroup_count_y: u32, workgroup_count_z: u32) void;
pub extern fn wgpuComputePassEncoderEnd(pass: WGPUComputePassEncoder) void;

// Queue
pub extern fn wgpuQueueSubmit(queue: WGPUQueue, command_count: u32, commands: [*]const WGPUCommandBuffer) void;
pub extern fn wgpuQueueWriteBuffer(queue: WGPUQueue, buffer: WGPUBuffer, buffer_offset: u64, data: *const anyopaque, size: usize) void;
pub extern fn wgpuQueueWriteTexture(queue: WGPUQueue, destination: *const WGPUImageCopyTexture, data: *const anyopaque, data_size: usize, data_layout: *const WGPUTextureDataLayout, write_size: *const WGPUExtent3D) void;

// Surface (platform-specific)
pub extern fn wgpuInstanceCreateSurface(instance: WGPUInstance, descriptor: *const WGPUSurfaceDescriptor) WGPUSurface;
pub extern fn wgpuSurfaceConfigure(surface: WGPUSurface, config: *const WGPUSurfaceConfiguration) void;
pub extern fn wgpuSurfaceGetCurrentTexture(surface: WGPUSurface, surface_texture: *WGPUSurfaceTexture) void;
pub extern fn wgpuSurfacePresent(surface: WGPUSurface) void;

// Deprecated swap chain functions (kept for compatibility)
pub extern fn wgpuDeviceCreateSwapChain(device: WGPUDevice, surface: WGPUSurface, descriptor: *const WGPUSwapChainDescriptor) WGPUSwapChain;
pub extern fn wgpuSwapChainGetCurrentTextureView(swapchain: WGPUSwapChain) WGPUTextureView;
pub extern fn wgpuSwapChainPresent(swapchain: WGPUSwapChain) void;

// =============================================================================
// C Descriptor Structs
// =============================================================================
// These match the C API layout exactly

pub const WGPUInstanceDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
};

// wgpu-native specific extensions
pub const WGPUInstanceBackendFlags = u32;
pub const WGPUInstanceBackend_All: WGPUInstanceBackendFlags = 0x00000000;
pub const WGPUInstanceBackend_Vulkan: WGPUInstanceBackendFlags = 1 << 0;
pub const WGPUInstanceBackend_GL: WGPUInstanceBackendFlags = 1 << 1;
pub const WGPUInstanceBackend_Metal: WGPUInstanceBackendFlags = 1 << 2;
pub const WGPUInstanceBackend_DX12: WGPUInstanceBackendFlags = 1 << 3;
pub const WGPUInstanceBackend_DX11: WGPUInstanceBackendFlags = 1 << 4;
pub const WGPUInstanceBackend_BrowserWebGPU: WGPUInstanceBackendFlags = 1 << 5;

pub const WGPUInstanceFlags = u32;

pub const WGPUInstanceExtras = extern struct {
    chain: WGPUChainedStruct,
    backends: WGPUInstanceBackendFlags,
    flags: WGPUInstanceFlags = 0,
    dx12_shader_compiler: u32 = 0,
    gles3_minor_version: u32 = 0,
    dxil_path: ?[*:0]const u8 = null,
    dxc_path: ?[*:0]const u8 = null,
};

pub const WGPUChainedStruct = extern struct {
    next: ?*const WGPUChainedStruct,
    s_type: WGPUSType,
};

pub const WGPUSType = enum(u32) {
    invalid = 0x00000000,
    surface_descriptor_from_metal_layer = 0x00000001,
    surface_descriptor_from_windows_hwnd = 0x00000002,
    surface_descriptor_from_xlib_window = 0x00000003,
    surface_descriptor_from_canvas_html_selector = 0x00000004,
    shader_module_spirv_descriptor = 0x00000005,
    shader_module_wgsl_descriptor = 0x00000006,
    primitive_depth_clip_control = 0x00000007,
    surface_descriptor_from_wayland_surface = 0x00000008,
    surface_descriptor_from_android_native_window = 0x00000009,
    surface_descriptor_from_xcb_window = 0x0000000A,
    render_pass_descriptor_max_draw_count = 0x0000000F,
    instance_extras = 0x00030006,
    _,
};

pub const WGPURequestAdapterOptions = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    compatible_surface: WGPUSurface = null,
    power_preference: WGPUPowerPreference = .undefined,
    force_fallback_adapter: bool = false,
};

pub const WGPUPowerPreference = enum(u32) {
    undefined = 0,
    low_power = 1,
    high_performance = 2,
};

pub const WGPURequestAdapterCallback = *const fn (
    status: WGPURequestAdapterStatus,
    adapter: WGPUAdapter,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void;

pub const WGPURequestAdapterStatus = enum(u32) {
    success = 0,
    unavailable = 1,
    err = 2,
    unknown = 3,
};

pub const WGPUDeviceDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    required_features_count: u32 = 0,
    required_features: ?[*]const WGPUFeatureName = null,
    required_limits: ?*const WGPURequiredLimits = null,
    default_queue: WGPUQueueDescriptor = .{},
};

pub const WGPUFeatureName = enum(u32) {
    depth_clip_control = 1,
    depth32float_stencil8 = 2,
    timestamp_query = 3,
    texture_compression_bc = 4,
    texture_compression_etc2 = 5,
    texture_compression_astc = 6,
    indirect_first_instance = 7,
    _,
};

pub const WGPURequiredLimits = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    limits: WGPULimits,
};

pub const WGPULimits = extern struct {
    max_texture_dimension_1d: u32 = 8192,
    max_texture_dimension_2d: u32 = 8192,
    max_texture_dimension_3d: u32 = 2048,
    max_texture_array_layers: u32 = 256,
    max_bind_groups: u32 = 4,
    max_dynamic_uniform_buffers_per_pipeline_layout: u32 = 8,
    max_dynamic_storage_buffers_per_pipeline_layout: u32 = 4,
    max_sampled_textures_per_shader_stage: u32 = 16,
    max_samplers_per_shader_stage: u32 = 16,
    max_storage_buffers_per_shader_stage: u32 = 8,
    max_storage_textures_per_shader_stage: u32 = 4,
    max_uniform_buffers_per_shader_stage: u32 = 12,
    max_uniform_buffer_binding_size: u64 = 65536,
    max_storage_buffer_binding_size: u64 = 134217728,
    min_uniform_buffer_offset_alignment: u32 = 256,
    min_storage_buffer_offset_alignment: u32 = 256,
    max_vertex_buffers: u32 = 8,
    max_vertex_attributes: u32 = 16,
    max_vertex_buffer_array_stride: u32 = 2048,
    max_inter_stage_shader_components: u32 = 60,
    max_compute_workgroup_storage_size: u32 = 16384,
    max_compute_invocations_per_workgroup: u32 = 256,
    max_compute_workgroup_size_x: u32 = 256,
    max_compute_workgroup_size_y: u32 = 256,
    max_compute_workgroup_size_z: u32 = 64,
    max_compute_workgroups_per_dimension: u32 = 65535,
};

pub const WGPUQueueDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
};

pub const WGPURequestDeviceCallback = *const fn (
    status: WGPURequestDeviceStatus,
    device: WGPUDevice,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void;

pub const WGPURequestDeviceStatus = enum(u32) {
    success = 0,
    err = 1,
    unknown = 2,
};

pub const WGPUBufferDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    usage: WGPUBufferUsageFlags,
    size: u64,
    mapped_at_creation: u32 = 0, // WGPUBool is uint32_t
};

pub const WGPUBufferUsageFlags = u32;
pub const WGPUBufferUsage_MapRead: u32 = 0x00000001;
pub const WGPUBufferUsage_MapWrite: u32 = 0x00000002;
pub const WGPUBufferUsage_CopySrc: u32 = 0x00000004;
pub const WGPUBufferUsage_CopyDst: u32 = 0x00000008;
pub const WGPUBufferUsage_Index: u32 = 0x00000010;
pub const WGPUBufferUsage_Vertex: u32 = 0x00000020;
pub const WGPUBufferUsage_Uniform: u32 = 0x00000040;
pub const WGPUBufferUsage_Storage: u32 = 0x00000080;
pub const WGPUBufferUsage_Indirect: u32 = 0x00000100;
pub const WGPUBufferUsage_QueryResolve: u32 = 0x00000200;

pub const WGPUTextureDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    usage: WGPUTextureUsageFlags,
    dimension: WGPUTextureDimension = .@"2d",
    size: WGPUExtent3D,
    format: WGPUTextureFormat,
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
    view_format_count: u32 = 0,
    view_formats: ?[*]const WGPUTextureFormat = null,
};

pub const WGPUTextureUsageFlags = u32;
pub const WGPUTextureUsage_CopySrc: u32 = 0x00000001;
pub const WGPUTextureUsage_CopyDst: u32 = 0x00000002;
pub const WGPUTextureUsage_TextureBinding: u32 = 0x00000004;
pub const WGPUTextureUsage_StorageBinding: u32 = 0x00000008;
pub const WGPUTextureUsage_RenderAttachment: u32 = 0x00000010;

pub const WGPUTextureDimension = enum(u32) {
    @"1d" = 0,
    @"2d" = 1,
    @"3d" = 2,
};

pub const WGPUTextureFormat = enum(u32) {
    undefined = 0x00000000,
    r8unorm = 0x00000001,
    r8snorm = 0x00000002,
    r8uint = 0x00000003,
    r8sint = 0x00000004,
    rgba8unorm = 0x00000012,
    rgba8unorm_srgb = 0x00000013,
    bgra8unorm = 0x00000017,
    bgra8unorm_srgb = 0x00000018,
    depth24plus = 0x00000029,
    depth32float = 0x0000002B,
    _,
};

pub const WGPUExtent3D = extern struct {
    width: u32,
    height: u32 = 1,
    depth_or_array_layers: u32 = 1,
};

pub const WGPUTextureViewDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    format: WGPUTextureFormat = .undefined,
    dimension: WGPUTextureViewDimension = .undefined,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0xFFFFFFFF,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0xFFFFFFFF,
    aspect: WGPUTextureAspect = .all,
};

pub const WGPUTextureViewDimension = enum(u32) {
    undefined = 0,
    @"1d" = 1,
    @"2d" = 2,
    @"2d_array" = 3,
    cube = 4,
    cube_array = 5,
    @"3d" = 6,
};

pub const WGPUTextureAspect = enum(u32) {
    all = 0,
    stencil_only = 1,
    depth_only = 2,
};

pub const WGPUSamplerDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    address_mode_u: WGPUAddressMode = .clamp_to_edge,
    address_mode_v: WGPUAddressMode = .clamp_to_edge,
    address_mode_w: WGPUAddressMode = .clamp_to_edge,
    mag_filter: WGPUFilterMode = .nearest,
    min_filter: WGPUFilterMode = .nearest,
    mipmap_filter: WGPUMipmapFilterMode = .nearest,
    lod_min_clamp: f32 = 0.0,
    lod_max_clamp: f32 = 32.0,
    compare: WGPUCompareFunction = .undefined,
    max_anisotropy: u16 = 1,
};

pub const WGPUAddressMode = enum(u32) {
    repeat = 0,
    mirror_repeat = 1,
    clamp_to_edge = 2,
};

pub const WGPUFilterMode = enum(u32) {
    nearest = 0,
    linear = 1,
};

pub const WGPUMipmapFilterMode = enum(u32) {
    nearest = 0,
    linear = 1,
};

pub const WGPUCompareFunction = enum(u32) {
    undefined = 0,
    never = 1,
    less = 2,
    less_equal = 3,
    greater = 4,
    greater_equal = 5,
    equal = 6,
    not_equal = 7,
    always = 8,
};

pub const WGPUShaderModuleDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
};

// Shader source is specified via chained structs
pub const WGPUShaderModuleWGSLDescriptor = extern struct {
    chain: WGPUChainedStruct,
    code: [*:0]const u8,
};

pub const WGPUBindGroupLayoutDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    entry_count: u32,
    entries: [*]const WGPUBindGroupLayoutEntry,
};

pub const WGPUBindGroupLayoutEntry = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    binding: u32,
    visibility: WGPUShaderStageFlags,
    buffer: WGPUBufferBindingLayout,
    sampler: WGPUSamplerBindingLayout,
    texture: WGPUTextureBindingLayout,
    storage_texture: WGPUStorageTextureBindingLayout,
};

pub const WGPUShaderStageFlags = u32;
pub const WGPUShaderStage_Vertex: u32 = 0x00000001;
pub const WGPUShaderStage_Fragment: u32 = 0x00000002;
pub const WGPUShaderStage_Compute: u32 = 0x00000004;

pub const WGPUBufferBindingLayout = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    type: WGPUBufferBindingType = .undefined,
    has_dynamic_offset: u32 = 0, // WGPUBool (uint32_t, not bool!)
    min_binding_size: u64 = 0,
};

pub const WGPUBufferBindingType = enum(u32) {
    undefined = 0,
    uniform = 1,
    storage = 2,
    read_only_storage = 3,
};

pub const WGPUSamplerBindingLayout = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    type: WGPUSamplerBindingType = .undefined,
};

pub const WGPUSamplerBindingType = enum(u32) {
    undefined = 0,
    filtering = 1,
    non_filtering = 2,
    comparison = 3,
};

pub const WGPUTextureBindingLayout = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    sample_type: WGPUTextureSampleType = .undefined,
    view_dimension: WGPUTextureViewDimension = .undefined,
    multisampled: bool = false,
};

pub const WGPUTextureSampleType = enum(u32) {
    undefined = 0,
    float = 1,
    unfilterable_float = 2,
    depth = 3,
    sint = 4,
    uint = 5,
};

pub const WGPUStorageTextureBindingLayout = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    access: WGPUStorageTextureAccess = .undefined,
    format: WGPUTextureFormat = .undefined,
    view_dimension: WGPUTextureViewDimension = .undefined,
};

pub const WGPUStorageTextureAccess = enum(u32) {
    undefined = 0,
    write_only = 1,
    read_only = 2,
    read_write = 3,
};

pub const WGPUBindGroupDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    layout: WGPUBindGroupLayout,
    entry_count: u32,
    entries: [*]const WGPUBindGroupEntry,
};

pub const WGPUBindGroupEntry = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    binding: u32,
    buffer: WGPUBuffer = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler: WGPUSampler = null,
    texture_view: WGPUTextureView = null,
};

pub const WGPUPipelineLayoutDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    bind_group_layout_count: u32,
    bind_group_layouts: [*]const WGPUBindGroupLayout,
};

pub const WGPURenderPipelineDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    layout: WGPUPipelineLayout = null,
    vertex: WGPUVertexState,
    primitive: WGPUPrimitiveState,
    depth_stencil: ?*const WGPUDepthStencilState = null,
    multisample: WGPUMultisampleState,
    fragment: ?*const WGPUFragmentState = null,
};

pub const WGPUVertexState = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    module: WGPUShaderModule,
    entry_point: ?[*:0]const u8,
    constant_count: usize = 0,
    constants: ?[*]const WGPUConstantEntry = null,
    buffer_count: usize = 0,
    buffers: ?[*]const WGPUVertexBufferLayout = null,
};

pub const WGPUConstantEntry = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    key: [*:0]const u8,
    value: f64,
};

pub const WGPUVertexBufferLayout = extern struct {
    array_stride: u64,
    step_mode: WGPUVertexStepMode = .vertex,
    attribute_count: usize,
    attributes: [*]const WGPUVertexAttribute,
};

pub const WGPUVertexStepMode = enum(u32) {
    vertex = 0,
    instance = 1,
};

pub const WGPUVertexAttribute = extern struct {
    format: WGPUVertexFormat,
    offset: u64,
    shader_location: u32,
};

pub const WGPUVertexFormat = enum(u32) {
    undefined = 0,
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

pub const WGPUPrimitiveState = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    topology: WGPUPrimitiveTopology = .triangle_list,
    strip_index_format: WGPUIndexFormat = .undefined,
    front_face: WGPUFrontFace = .ccw,
    cull_mode: WGPUCullMode = .none,
};

pub const WGPUPrimitiveTopology = enum(u32) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
};

pub const WGPUIndexFormat = enum(u32) {
    undefined = 0,
    uint16 = 1,
    uint32 = 2,
};

pub const WGPUFrontFace = enum(u32) {
    ccw = 0,
    cw = 1,
};

pub const WGPUCullMode = enum(u32) {
    none = 0,
    front = 1,
    back = 2,
};

pub const WGPUDepthStencilState = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    format: WGPUTextureFormat,
    depth_write_enabled: bool,
    depth_compare: WGPUCompareFunction,
    stencil_front: WGPUStencilFaceState,
    stencil_back: WGPUStencilFaceState,
    stencil_read_mask: u32 = 0xFFFFFFFF,
    stencil_write_mask: u32 = 0xFFFFFFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
};

pub const WGPUStencilFaceState = extern struct {
    compare: WGPUCompareFunction = .always,
    fail_op: WGPUStencilOperation = .keep,
    depth_fail_op: WGPUStencilOperation = .keep,
    pass_op: WGPUStencilOperation = .keep,
};

pub const WGPUStencilOperation = enum(u32) {
    keep = 0,
    zero = 1,
    replace = 2,
    invert = 3,
    increment_clamp = 4,
    decrement_clamp = 5,
    increment_wrap = 6,
    decrement_wrap = 7,
};

pub const WGPUMultisampleState = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    count: u32 = 1,
    mask: u32 = 0xFFFFFFFF,
    alpha_to_coverage_enabled: u32 = 0,
};

pub const WGPUFragmentState = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    module: WGPUShaderModule,
    entry_point: ?[*:0]const u8,
    constant_count: usize = 0,
    constants: ?[*]const WGPUConstantEntry = null,
    target_count: usize,
    targets: [*]const WGPUColorTargetState,
};

pub const WGPUColorTargetState = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    format: WGPUTextureFormat,
    blend: ?*const WGPUBlendState = null,
    write_mask: WGPUColorWriteMaskFlags = WGPUColorWriteMask_All,
};

pub const WGPUBlendState = extern struct {
    color: WGPUBlendComponent,
    alpha: WGPUBlendComponent,
};

pub const WGPUBlendComponent = extern struct {
    operation: WGPUBlendOperation = .add,
    src_factor: WGPUBlendFactor = .one,
    dst_factor: WGPUBlendFactor = .zero,
};

pub const WGPUBlendOperation = enum(u32) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

pub const WGPUBlendFactor = enum(u32) {
    zero = 0,
    one = 1,
    src = 2,
    one_minus_src = 3,
    src_alpha = 4,
    one_minus_src_alpha = 5,
    dst = 6,
    one_minus_dst = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    src_alpha_saturated = 10,
    constant = 11,
    one_minus_constant = 12,
};

pub const WGPUColorWriteMaskFlags = u32;
pub const WGPUColorWriteMask_None: u32 = 0x00000000;
pub const WGPUColorWriteMask_Red: u32 = 0x00000001;
pub const WGPUColorWriteMask_Green: u32 = 0x00000002;
pub const WGPUColorWriteMask_Blue: u32 = 0x00000004;
pub const WGPUColorWriteMask_Alpha: u32 = 0x00000008;
pub const WGPUColorWriteMask_All: u32 = 0x0000000F;

pub const WGPUComputePipelineDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    layout: WGPUPipelineLayout = null,
    compute: WGPUProgrammableStageDescriptor,
};

pub const WGPUProgrammableStageDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    module: WGPUShaderModule,
    entry_point: [*:0]const u8,
    constant_count: u32 = 0,
    constants: ?[*]const WGPUConstantEntry = null,
};

pub const WGPUCommandEncoderDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
};

pub const WGPURenderPassDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    color_attachment_count: usize,
    color_attachments: [*]const WGPURenderPassColorAttachment,
    depth_stencil_attachment: ?*const WGPURenderPassDepthStencilAttachment = null,
    occlusion_query_set: WGPUQuerySet = null,
    timestamp_write_count: usize = 0,
    timestamp_writes: ?[*]const WGPURenderPassTimestampWrite = null,
};

pub const WGPURenderPassColorAttachment = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    view: WGPUTextureView,
    depth_slice: u32 = 0xFFFFFFFF, // WGPU_DEPTH_SLICE_UNDEFINED
    resolve_target: WGPUTextureView = null,
    load_op: WGPULoadOp,
    store_op: WGPUStoreOp,
    clear_value: WGPUColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
};

pub const WGPULoadOp = enum(u32) {
    undefined = 0,
    clear = 1,
    load = 2,
};

pub const WGPUStoreOp = enum(u32) {
    undefined = 0,
    store = 1,
    discard = 2,
};

pub const WGPUColor = extern struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

pub const WGPURenderPassDepthStencilAttachment = extern struct {
    view: WGPUTextureView,
    depth_load_op: WGPULoadOp = .undefined,
    depth_store_op: WGPUStoreOp = .undefined,
    depth_clear_value: f32 = 0.0,
    depth_read_only: u32 = 0,
    stencil_load_op: WGPULoadOp = .undefined,
    stencil_store_op: WGPUStoreOp = .undefined,
    stencil_clear_value: u32 = 0,
    stencil_read_only: u32 = 0,
};

pub const WGPURenderPassTimestampWrite = extern struct {
    query_set: WGPUQuerySet,
    query_index: u32,
    location: WGPURenderPassTimestampLocation,
};

pub const WGPURenderPassTimestampLocation = enum(u32) {
    beginning = 0,
    end = 1,
};

pub const WGPUComputePassDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    timestamp_write_count: u32 = 0,
    timestamp_writes: ?[*]const WGPUComputePassTimestampWrite = null,
};

pub const WGPUComputePassTimestampWrite = extern struct {
    query_set: WGPUQuerySet,
    query_index: u32,
    location: WGPUComputePassTimestampLocation,
};

pub const WGPUComputePassTimestampLocation = enum(u32) {
    beginning = 0,
    end = 1,
};

pub const WGPUCommandBufferDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
};

pub const WGPUSurfaceDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
};

pub const WGPUSurfaceDescriptorFromMetalLayer = extern struct {
    chain: WGPUChainedStruct,
    layer: *anyopaque,
};

pub const WGPUSurfaceDescriptorFromXlibWindow = extern struct {
    chain: WGPUChainedStruct,
    display: *anyopaque,
    window: u64,
};

pub const WGPUSurfaceDescriptorFromWaylandSurface = extern struct {
    chain: WGPUChainedStruct,
    display: *anyopaque,
    surface: *anyopaque,
};

pub const WGPUSurfaceDescriptorFromWindowsHWND = extern struct {
    chain: WGPUChainedStruct,
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

pub const WGPUSurfaceConfiguration = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    device: WGPUDevice,
    format: WGPUTextureFormat,
    usage: WGPUTextureUsageFlags = WGPUTextureUsage_RenderAttachment,
    view_format_count: usize = 0,
    view_formats: ?[*]const WGPUTextureFormat = null,
    alpha_mode: WGPUCompositeAlphaMode = .auto,
    width: u32,
    height: u32,
    present_mode: WGPUPresentMode = .fifo,
};

pub const WGPUCompositeAlphaMode = enum(u32) {
    auto = 0,
    @"opaque" = 1,
    premultiplied = 2,
    unpremultiplied = 3,
    inherit = 4,
};

pub const WGPUSurfaceTexture = extern struct {
    texture: WGPUTexture,
    suboptimal: bool,
    status: WGPUSurfaceGetCurrentTextureStatus,
};

pub const WGPUSurfaceGetCurrentTextureStatus = enum(u32) {
    success = 0,
    timeout = 1,
    outdated = 2,
    lost = 3,
    out_of_memory = 4,
    device_lost = 5,
};

pub const WGPUSwapChainDescriptor = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    label: ?[*:0]const u8 = null,
    usage: WGPUTextureUsageFlags,
    format: WGPUTextureFormat,
    width: u32,
    height: u32,
    present_mode: WGPUPresentMode,
};

pub const WGPUPresentMode = enum(u32) {
    fifo = 0,
    fifo_relaxed = 1,
    immediate = 2,
    mailbox = 3,
};

pub const WGPUImageCopyTexture = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    texture: WGPUTexture,
    mip_level: u32 = 0,
    origin: WGPUOrigin3D = .{},
    aspect: WGPUTextureAspect = .all,
};

pub const WGPUOrigin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const WGPUTextureDataLayout = extern struct {
    next_in_chain: ?*const WGPUChainedStruct = null,
    offset: u64 = 0,
    bytes_per_row: u32,
    rows_per_image: u32,
};

// =============================================================================
// Helper Functions for Type Conversion
// =============================================================================

/// Convert Zig BufferUsage to C flags
pub fn bufferUsageToFlags(usage: types.BufferUsage) WGPUBufferUsageFlags {
    var flags: WGPUBufferUsageFlags = 0;
    if (usage.map_read) flags |= WGPUBufferUsage_MapRead;
    if (usage.map_write) flags |= WGPUBufferUsage_MapWrite;
    if (usage.copy_src) flags |= WGPUBufferUsage_CopySrc;
    if (usage.copy_dst) flags |= WGPUBufferUsage_CopyDst;
    if (usage.index) flags |= WGPUBufferUsage_Index;
    if (usage.vertex) flags |= WGPUBufferUsage_Vertex;
    if (usage.uniform) flags |= WGPUBufferUsage_Uniform;
    if (usage.storage) flags |= WGPUBufferUsage_Storage;
    if (usage.indirect) flags |= WGPUBufferUsage_Indirect;
    if (usage.query_resolve) flags |= WGPUBufferUsage_QueryResolve;
    return flags;
}

/// Convert Zig TextureUsage to C flags
pub fn textureUsageToFlags(usage: types.TextureUsage) WGPUTextureUsageFlags {
    var flags: WGPUTextureUsageFlags = 0;
    if (usage.copy_src) flags |= WGPUTextureUsage_CopySrc;
    if (usage.copy_dst) flags |= WGPUTextureUsage_CopyDst;
    if (usage.texture_binding) flags |= WGPUTextureUsage_TextureBinding;
    if (usage.storage_binding) flags |= WGPUTextureUsage_StorageBinding;
    if (usage.render_attachment) flags |= WGPUTextureUsage_RenderAttachment;
    return flags;
}

/// Convert Zig ShaderStage to C flags
pub fn shaderStageToFlags(stage: types.ShaderStage) WGPUShaderStageFlags {
    var flags: WGPUShaderStageFlags = 0;
    if (stage.vertex) flags |= WGPUShaderStage_Vertex;
    if (stage.fragment) flags |= WGPUShaderStage_Fragment;
    if (stage.compute) flags |= WGPUShaderStage_Compute;
    return flags;
}

// =============================================================================
// Platform-Specific Surface Creation
// =============================================================================

// SDL2 declarations for platform-specific surface creation
pub extern fn SDL_Metal_CreateView(window: *anyopaque) ?*anyopaque;
pub extern fn SDL_Metal_GetLayer(view: *anyopaque) ?*anyopaque;
pub extern fn SDL_Metal_DestroyView(view: *anyopaque) void;

// SDL2 X11 declarations
const SDL_SYSWM_X11 = 2;
const SDL_SYSWM_WAYLAND = 3;

const SDL_SysWMinfo = extern struct {
    version: SDL_version,
    subsystem: u32,
    info: extern union {
        x11: extern struct {
            display: *anyopaque,
            window: u64,
        },
        wl: extern struct {
            display: *anyopaque,
            surface: *anyopaque,
        },
        dummy: [64]u8,
    },
};

const SDL_version = extern struct {
    major: u8,
    minor: u8,
    patch: u8,
};

pub extern fn SDL_GetVersion(ver: *SDL_version) void;
pub extern fn SDL_GetWindowWMInfo(window: *anyopaque, info: *SDL_SysWMinfo) c_int;

/// Create a WGPUSurface from an SDL2 window (cross-platform)
pub fn createSurfaceFromSDLWindow(instance: WGPUInstance, sdl_window: *anyopaque) !WGPUSurface {
    const builtin = @import("builtin");
    
    switch (builtin.os.tag) {
        .macos => {
            // Create Metal view from SDL window
            const metal_view = SDL_Metal_CreateView(sdl_window) orelse return error.MetalViewCreationFailed;

            // Get the CAMetalLayer from the view
            const metal_layer = SDL_Metal_GetLayer(metal_view) orelse return error.MetalLayerCreationFailed;

            // Create surface descriptor with Metal layer
            const metal_desc = WGPUSurfaceDescriptorFromMetalLayer{
                .chain = .{
                    .next = null,
                    .s_type = .surface_descriptor_from_metal_layer,
                },
                .layer = metal_layer,
            };

            const surface_desc = WGPUSurfaceDescriptor{
                .next_in_chain = @ptrCast(&metal_desc),
                .label = null,
            };

            const surface = wgpuInstanceCreateSurface(instance, &surface_desc);
            if (surface == null) return error.SurfaceCreationFailed;

            return surface;
        },
        .linux => {
            // Get window manager info from SDL
            var wm_info: SDL_SysWMinfo = undefined;
            SDL_GetVersion(&wm_info.version);
            
            if (SDL_GetWindowWMInfo(sdl_window, &wm_info) == 0) {
                return error.SDLWMInfoFailed;
            }

            if (wm_info.subsystem == SDL_SYSWM_X11) {
                // X11 surface
                const x11_desc = WGPUSurfaceDescriptorFromXlibWindow{
                    .chain = .{
                        .next = null,
                        .s_type = .surface_descriptor_from_xlib_window,
                    },
                    .display = wm_info.info.x11.display,
                    .window = wm_info.info.x11.window,
                };

                const surface_desc = WGPUSurfaceDescriptor{
                    .next_in_chain = @ptrCast(&x11_desc),
                    .label = null,
                };

                const surface = wgpuInstanceCreateSurface(instance, &surface_desc);
                if (surface == null) return error.SurfaceCreationFailed;

                return surface;
            } else if (wm_info.subsystem == SDL_SYSWM_WAYLAND) {
                // Wayland surface
                const wl_desc = WGPUSurfaceDescriptorFromWaylandSurface{
                    .chain = .{
                        .next = null,
                        .s_type = .surface_descriptor_from_wayland_surface,
                    },
                    .display = wm_info.info.wl.display,
                    .surface = wm_info.info.wl.surface,
                };

                const surface_desc = WGPUSurfaceDescriptor{
                    .next_in_chain = @ptrCast(&wl_desc),
                    .label = null,
                };

                const surface = wgpuInstanceCreateSurface(instance, &surface_desc);
                if (surface == null) return error.SurfaceCreationFailed;

                return surface;
            } else {
                return error.UnsupportedWindowSystem;
            }
        },
        .windows => {
            // TODO: Implement Windows HWND surface creation
            return error.NotImplementedYet;
        },
        else => {
            return error.UnsupportedPlatform;
        },
    }
}
