/// swindowzig app module - the main entry point for building apps.
/// Import this as `const sw = @import("sw_app");` and call `sw.run()`.
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");
const audio_mod = @import("sw_audio");

pub const app = @import("app.zig");
pub const context = @import("context.zig");

/// Main entry point - call this from your main() function.
pub const run = app.run;
/// App configuration (title, size, tick rate).
pub const Config = app.Config;
/// Context passed to all callbacks (provides input, GPU, timing, etc).
pub const Context = context.Context;

/// Core framework types (usually accessed via Context, not directly).
pub const core_types = struct {
    pub const FixedStepTimeline = core.FixedStepTimeline;
    pub const Bus = core.Bus;
    pub const InputSnapshot = core.InputSnapshot;
};

/// Platform backend types (internal use).
pub const platform_types = struct {
    pub const WasmBackend = platform.wasm_canvas.WasmBackend;
    pub const Backend = platform.backend.Backend;
};

/// GPU types (accessed via ctx.gpu()).
pub const gpu_types = struct {
    pub const GPU = gpu_mod.GPU;
    pub const Buffer = gpu_mod.Buffer;
    pub const Texture = gpu_mod.Texture;
    pub const TextureView = gpu_mod.TextureView;
    pub const Sampler = gpu_mod.Sampler;
    pub const ShaderModule = gpu_mod.ShaderModule;
    pub const BindGroupLayout = gpu_mod.BindGroupLayout;
    pub const BindGroup = gpu_mod.BindGroup;
    pub const PipelineLayout = gpu_mod.PipelineLayout;
    pub const RenderPipeline = gpu_mod.RenderPipeline;
    pub const ComputePipeline = gpu_mod.ComputePipeline;
    pub const CommandEncoder = gpu_mod.CommandEncoder;
    pub const RenderPassEncoder = gpu_mod.RenderPassEncoder;
    pub const ComputePassEncoder = gpu_mod.ComputePassEncoder;
    pub const CommandBuffer = gpu_mod.CommandBuffer;

    // Descriptors and types
    pub const BufferDescriptor = gpu_mod.BufferDescriptor;
    pub const TextureDescriptor = gpu_mod.TextureDescriptor;
    pub const SamplerDescriptor = gpu_mod.SamplerDescriptor;
    pub const ShaderModuleDescriptor = gpu_mod.ShaderModuleDescriptor;
    pub const RenderPipelineDescriptor = gpu_mod.RenderPipelineDescriptor;
    pub const ComputePipelineDescriptor = gpu_mod.ComputePipelineDescriptor;
    pub const BindGroupLayoutDescriptor = gpu_mod.BindGroupLayoutDescriptor;
    pub const BindGroupDescriptor = gpu_mod.BindGroupDescriptor;
    pub const PipelineLayoutDescriptor = gpu_mod.PipelineLayoutDescriptor;
    pub const RenderPassDescriptor = gpu_mod.RenderPassDescriptor;
    pub const RenderPassColorAttachment = gpu_mod.RenderPassColorAttachment;
    pub const VertexBufferLayout = gpu_mod.VertexBufferLayout;
    pub const VertexAttribute = gpu_mod.VertexAttribute;
    pub const ColorTargetState = gpu_mod.ColorTargetState;
    pub const VertexFormat = gpu_mod.VertexFormat;
};

/// Audio types (not implemented in v0.1).
pub const audio_types = struct {
    pub const Audio = audio_mod.Audio;
    pub const Sound = audio_mod.Sound;
    pub const Waveform = audio_mod.Waveform;
};
