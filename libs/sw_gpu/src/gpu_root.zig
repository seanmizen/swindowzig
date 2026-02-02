//! GPU module root - exports WebGPU wrapper
const gpu_mod = @import("gpu.zig");
const types_mod = @import("types.zig");

// Main GPU context
pub const GPU = gpu_mod.GPU;
pub const GPUState = gpu_mod.GPUState;

// Resource handles
pub const Buffer = gpu_mod.Buffer;
pub const Texture = gpu_mod.Texture;
pub const TextureView = gpu_mod.TextureView;
pub const Sampler = gpu_mod.Sampler;
pub const ShaderModule = gpu_mod.ShaderModule;
pub const RenderPipeline = gpu_mod.RenderPipeline;
pub const ComputePipeline = gpu_mod.ComputePipeline;
pub const BindGroupLayout = gpu_mod.BindGroupLayout;
pub const BindGroup = gpu_mod.BindGroup;
pub const CommandEncoder = gpu_mod.CommandEncoder;
pub const RenderPassEncoder = gpu_mod.RenderPassEncoder;
pub const CommandBuffer = gpu_mod.CommandBuffer;

// Type definitions (re-exported from types.zig)
pub const BufferUsage = types_mod.BufferUsage;
pub const TextureUsage = types_mod.TextureUsage;
pub const ShaderStage = types_mod.ShaderStage;
pub const TextureFormat = types_mod.TextureFormat;
pub const PrimitiveTopology = types_mod.PrimitiveTopology;
pub const IndexFormat = types_mod.IndexFormat;
pub const CompareFunction = types_mod.CompareFunction;
pub const LoadOp = types_mod.LoadOp;
pub const StoreOp = types_mod.StoreOp;
pub const Color = types_mod.Color;
pub const Extent3D = types_mod.Extent3D;
pub const Origin3D = types_mod.Origin3D;

// Descriptors that don't reference handles (from types.zig)
pub const BufferDescriptor = types_mod.BufferDescriptor;
pub const TextureDescriptor = types_mod.TextureDescriptor;
pub const SamplerDescriptor = types_mod.SamplerDescriptor;
pub const ShaderModuleDescriptor = types_mod.ShaderModuleDescriptor;
pub const BindGroupLayoutDescriptor = types_mod.BindGroupLayoutDescriptor;
pub const BindGroupLayoutEntry = types_mod.BindGroupLayoutEntry;
pub const BufferBindingLayout = types_mod.BufferBindingLayout;
pub const PrimitiveState = types_mod.PrimitiveState;
pub const DepthStencilState = types_mod.DepthStencilState;
pub const MultisampleState = types_mod.MultisampleState;
pub const VertexBufferLayout = types_mod.VertexBufferLayout;
pub const VertexAttribute = types_mod.VertexAttribute;
pub const VertexFormat = types_mod.VertexFormat;
pub const ColorTargetState = types_mod.ColorTargetState;
pub const BlendState = types_mod.BlendState;

// Descriptors that reference handles (from gpu.zig, override types.zig versions)
pub const RenderPipelineDescriptor = gpu_mod.RenderPipelineDescriptor;
pub const ComputePipelineDescriptor = gpu_mod.ComputePipelineDescriptor;
pub const RenderPassDescriptor = gpu_mod.RenderPassDescriptor;
pub const RenderPassColorAttachment = gpu_mod.RenderPassColorAttachment;
pub const RenderPassDepthStencilAttachment = gpu_mod.RenderPassDepthStencilAttachment;
pub const BindGroupDescriptor = gpu_mod.BindGroupDescriptor;
pub const BindGroupEntry = gpu_mod.BindGroupEntry;
pub const PipelineLayoutDescriptor = gpu_mod.PipelineLayoutDescriptor;
pub const VertexState = gpu_mod.VertexState;
pub const FragmentState = gpu_mod.FragmentState;
pub const ComputeState = gpu_mod.ComputeState;
