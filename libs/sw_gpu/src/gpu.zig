//! WebGPU Wrapper - Full 3D Graphics API
//! Source: W3C WebGPU Specification (https://www.w3.org/TR/webgpu/)
//!
//! This is a thin wrapper over WebGPU that works identically on web and native.
//! It exposes the full WebGPU API for 3D rendering, compute shaders, and everything
//! the GPU can do - not a simplified 2D Canvas subset.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const is_wasm = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false,
};

const native = if (!is_wasm) @import("native_webgpu.zig") else struct {};
const web = if (is_wasm) @import("web_bridge.zig") else struct {};

// Re-export types for convenience
pub const BufferUsage = types.BufferUsage;
pub const TextureUsage = types.TextureUsage;
pub const ShaderStage = types.ShaderStage;
pub const TextureFormat = types.TextureFormat;
pub const PrimitiveTopology = types.PrimitiveTopology;
pub const IndexFormat = types.IndexFormat;
pub const CompareFunction = types.CompareFunction;
pub const LoadOp = types.LoadOp;
pub const StoreOp = types.StoreOp;
pub const Color = types.Color;
pub const Extent3D = types.Extent3D;
pub const Origin3D = types.Origin3D;

// Re-export simple descriptors from types.zig (no handle references)
pub const BufferDescriptor = types.BufferDescriptor;
pub const TextureDescriptor = types.TextureDescriptor;
pub const SamplerDescriptor = types.SamplerDescriptor;
pub const ShaderModuleDescriptor = types.ShaderModuleDescriptor;
pub const BindGroupLayoutDescriptor = types.BindGroupLayoutDescriptor;

// Note: RenderPipelineDescriptor, ComputePipelineDescriptor, RenderPassDescriptor,
// BindGroupDescriptor, and PipelineLayoutDescriptor are defined later in this file
// to reference concrete handle types instead of opaque types

// =============================================================================
// Native-only: Adapter/Device request helpers
// =============================================================================

const AdapterRequestResult = if (!is_wasm) struct {
    received: bool = false,
    adapter: native.WGPUAdapter = null,
} else struct {};

const DeviceRequestResult = if (!is_wasm) struct {
    received: bool = false,
    device: native.WGPUDevice = null,
} else struct {};

fn adapterRequestCallback(
    status: native.WGPURequestAdapterStatus,
    adapter: native.WGPUAdapter,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (comptime is_wasm) unreachable;
    _ = message;
    const result: *AdapterRequestResult = @ptrCast(@alignCast(userdata.?));
    if (status == .success) {
        result.adapter = adapter;
    }
    result.received = true;
}

fn deviceRequestCallback(
    status: native.WGPURequestDeviceStatus,
    device: native.WGPUDevice,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (comptime is_wasm) unreachable;
    _ = message;
    const result: *DeviceRequestResult = @ptrCast(@alignCast(userdata.?));
    if (status == .success) {
        result.device = device;
    }
    result.received = true;
}

// =============================================================================
// Main GPU Context
// =============================================================================

pub const GPUState = enum {
    uninitialized,
    initializing,
    ready,
    failed,
};

/// Main GPU context - access via ctx.gpu()
pub const GPU = struct {
    state: GPUState = .uninitialized,
    device: if (is_wasm) web.WebGPUDevice else native.WGPUDevice = if (is_wasm) 0 else null,
    queue: if (is_wasm) web.WebGPUQueue else native.WGPUQueue = if (is_wasm) 0 else null,

    // Native-only fields for WebGPU state
    instance: if (!is_wasm) native.WGPUInstance else void = if (!is_wasm) null else {},
    adapter: if (!is_wasm) native.WGPUAdapter else void = if (!is_wasm) null else {},
    surface: if (!is_wasm) native.WGPUSurface else void = if (!is_wasm) null else {},
    width: if (!is_wasm) u32 else void = if (!is_wasm) 0 else {},
    height: if (!is_wasm) u32 else void = if (!is_wasm) 0 else {},

    /// Check if GPU is ready for use
    pub fn isReady(self: *const GPU) bool {
        return self.state == .ready;
    }

    /// Initialize WebGPU (call once at startup)
    pub fn init(self: *GPU, window: ?*anyopaque, width: u32, height: u32) !void {
        if (self.state != .uninitialized) return;
        self.state = .initializing;

        if (comptime is_wasm) {
            // Web: Request adapter and device from browser
            web.init();
            const adapter = web.webgpuRequestAdapter();
            const device = web.webgpuRequestDevice(adapter);
            const queue = web.webgpuGetQueue(device);

            self.device = device;
            self.queue = queue;
            self.state = .ready;
        } else {
            // Native: Initialize wgpu-native
            if (window == null) return error.WindowRequired;

            // Create instance with appropriate backend for platform
            const backend_flags = switch (builtin.os.tag) {
                .macos => native.WGPUInstanceBackend_Metal,
                .linux => native.WGPUInstanceBackend_Vulkan,
                .windows => native.WGPUInstanceBackend_DX12 | native.WGPUInstanceBackend_Vulkan,
                else => native.WGPUInstanceBackend_Vulkan,
            };
            
            const instance_extras = native.WGPUInstanceExtras{
                .chain = .{
                    .next = null,
                    .s_type = .instance_extras,
                },
                .backends = backend_flags,
            };

            const instance_desc = native.WGPUInstanceDescriptor{
                .next_in_chain = @ptrCast(&instance_extras),
            };

            const instance = native.wgpuCreateInstance(&instance_desc);
            if (instance == null) return error.InstanceCreationFailed;

            std.log.info("Instance created successfully", .{});

            // Request adapter FIRST (without surface) to avoid backend detection issues
            var adapter_result = AdapterRequestResult{};
            const adapter_options = native.WGPURequestAdapterOptions{
                .compatible_surface = null,
                .power_preference = .high_performance,
            };
            native.wgpuInstanceRequestAdapter(
                instance,
                &adapter_options,
                adapterRequestCallback,
                &adapter_result,
            );

            // Wait for adapter (simple spin-wait for now)
            while (!adapter_result.received) {}
            if (adapter_result.adapter == null) return error.AdapterRequestFailed;

            // Now create surface from SDL window
            const surface = try native.createSurfaceFromSDLWindow(instance, window.?);

            // Request device (using callback)
            var device_result = DeviceRequestResult{};
            const device_desc = native.WGPUDeviceDescriptor{};
            native.wgpuAdapterRequestDevice(
                adapter_result.adapter.?,
                &device_desc,
                deviceRequestCallback,
                &device_result,
            );

            // Wait for device
            while (!device_result.received) {}
            if (device_result.device == null) return error.DeviceRequestFailed;

            // Get queue
            const queue = native.wgpuDeviceGetQueue(device_result.device.?);
            if (queue == null) return error.QueueCreationFailed;

            // Configure surface (modern API, replaces swap chain)
            const surface_config = native.WGPUSurfaceConfiguration{
                .next_in_chain = null,
                .device = device_result.device.?,
                .format = .bgra8unorm,
                .usage = native.WGPUTextureUsage_RenderAttachment,
                .view_format_count = 0,
                .view_formats = null,
                .alpha_mode = .auto,
                .width = width,
                .height = height,
                .present_mode = .fifo,
            };
            native.wgpuSurfaceConfigure(surface, &surface_config);

            // Store everything
            self.instance = instance;
            self.adapter = adapter_result.adapter.?;
            self.surface = surface;
            self.device = device_result.device.?;
            self.queue = queue;
            self.width = width;
            self.height = height;
            self.state = .ready;
        }
    }

    // =========================================================================
    // Resource Creation
    // =========================================================================

    /// Create a GPU buffer for vertex data, uniforms, storage, etc.
    pub fn createBuffer(self: *GPU, desc: BufferDescriptor) !Buffer {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const usage = web.bufferUsageToJS(desc.usage);
            const handle = web.webgpuCreateBuffer(
                self.device,
                desc.size,
                usage,
                desc.mapped_at_creation,
            );
            return Buffer{ .handle = handle };
        } else {
            const c_desc = native.WGPUBufferDescriptor{
                .next_in_chain = null,
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
                .usage = native.bufferUsageToFlags(desc.usage),
                .size = desc.size,
                .mapped_at_creation = if (desc.mapped_at_creation) @as(u32, 1) else 0,
            };
            const handle = native.wgpuDeviceCreateBuffer(self.device, &c_desc);
            return Buffer{ .handle = handle orelse return error.BufferCreationFailed };
        }
    }

    /// Create a GPU texture for images, render targets, depth buffers, etc.
    pub fn createTexture(self: *GPU, desc: TextureDescriptor) !Texture {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const usage = web.textureUsageToJS(desc.usage);
            const handle = web.webgpuCreateTexture(
                self.device,
                desc.size.width,
                desc.size.height,
                desc.size.depth_or_array_layers,
                @intFromEnum(desc.format),
                usage,
                desc.mip_level_count,
                desc.sample_count,
            );
            return Texture{ .handle = handle };
        } else {
            const c_desc = native.WGPUTextureDescriptor{
                .next_in_chain = null,
                .label = null, // TODO: Support labels
                .usage = native.textureUsageToFlags(desc.usage),
                .dimension = @enumFromInt(@intFromEnum(desc.dimension)),
                .size = .{
                    .width = desc.size.width,
                    .height = desc.size.height,
                    .depth_or_array_layers = desc.size.depth_or_array_layers,
                },
                .format = @enumFromInt(@intFromEnum(desc.format)),
                .mip_level_count = desc.mip_level_count,
                .sample_count = desc.sample_count,
                .view_format_count = 0,
                .view_formats = null,
            };
            const handle = native.wgpuDeviceCreateTexture(self.device, &c_desc);
            return Texture{ .handle = handle orelse return error.TextureCreationFailed };
        }
    }

    /// Create a sampler for texture sampling
    pub fn createSampler(self: *GPU, desc: SamplerDescriptor) !Sampler {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const handle = web.webgpuCreateSampler(
                self.device,
                @intFromEnum(desc.address_mode_u),
                @intFromEnum(desc.address_mode_v),
                @intFromEnum(desc.address_mode_w),
                @intFromEnum(desc.mag_filter),
                @intFromEnum(desc.min_filter),
                @intFromEnum(desc.mipmap_filter),
                desc.lod_min_clamp,
                desc.lod_max_clamp,
                if (desc.compare) |c| @intFromEnum(c) else 0,
            );
            return Sampler{ .handle = handle };
        } else {
            const c_desc = native.WGPUSamplerDescriptor{
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
                .address_mode_u = @enumFromInt(@intFromEnum(desc.address_mode_u)),
                .address_mode_v = @enumFromInt(@intFromEnum(desc.address_mode_v)),
                .address_mode_w = @enumFromInt(@intFromEnum(desc.address_mode_w)),
                .mag_filter = @enumFromInt(@intFromEnum(desc.mag_filter)),
                .min_filter = @enumFromInt(@intFromEnum(desc.min_filter)),
                .mipmap_filter = @enumFromInt(@intFromEnum(desc.mipmap_filter)),
                .lod_min_clamp = desc.lod_min_clamp,
                .lod_max_clamp = desc.lod_max_clamp,
                .compare = if (desc.compare) |c| @enumFromInt(@intFromEnum(c)) else .undefined,
                .max_anisotropy = desc.max_anisotropy,
            };
            const handle = native.wgpuDeviceCreateSampler(self.device, &c_desc);
            return Sampler{ .handle = handle orelse return error.SamplerCreationFailed };
        }
    }

    /// Create a shader module from WGSL source code
    pub fn createShaderModule(self: *GPU, desc: ShaderModuleDescriptor) !ShaderModule {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const handle = web.webgpuCreateShaderModule(
                self.device,
                desc.code.ptr,
                @intCast(desc.code.len),
            );
            return ShaderModule{ .handle = handle };
        } else {
            // Native requires null-terminated string for WGSL source
            const allocator = std.heap.page_allocator;
            const code_z = try allocator.dupeZ(u8, desc.code);
            defer allocator.free(code_z);
            
            var wgsl_desc = native.WGPUShaderModuleWGSLDescriptor{
                .chain = .{
                    .next = null,
                    .s_type = .shader_module_wgsl_descriptor,
                },
                .code = code_z.ptr,
            };
            const c_desc = native.WGPUShaderModuleDescriptor{
                .next_in_chain = @ptrCast(&wgsl_desc.chain),
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
            };
            
            const handle = native.wgpuDeviceCreateShaderModule(self.device, &c_desc);
            return ShaderModule{ .handle = handle orelse return error.ShaderCreationFailed };
        }
    }

    /// Create a render pipeline (graphics pipeline state)
    pub fn createRenderPipeline(self: *GPU, desc: RenderPipelineDescriptor) !RenderPipeline {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            // Allocate and convert vertex buffer layouts
            var js_vertex_buffers = try std.heap.page_allocator.alloc(web.VertexBufferLayoutJS, desc.vertex.buffers.len);
            defer std.heap.page_allocator.free(js_vertex_buffers);

            // Track all attributes allocations for deferred cleanup
            var vertex_attributes_allocations = std.ArrayList([]web.VertexAttributeJS).init(std.heap.page_allocator);
            defer {
                for (vertex_attributes_allocations.items) |attrs| {
                    std.heap.page_allocator.free(attrs);
                }
                vertex_attributes_allocations.deinit();
            }

            for (desc.vertex.buffers, 0..) |buffer_layout, i| {
                // Allocate and convert attributes
                var js_attrs = try std.heap.page_allocator.alloc(web.VertexAttributeJS, buffer_layout.attributes.len);
                try vertex_attributes_allocations.append(js_attrs);

                for (buffer_layout.attributes, 0..) |attr, j| {
                    js_attrs[j] = .{
                        .format = @intFromEnum(attr.format),
                        .offset = attr.offset,
                        .shader_location = attr.shader_location,
                    };
                }

                js_vertex_buffers[i] = .{
                    .array_stride = buffer_layout.array_stride,
                    .step_mode = @intFromEnum(buffer_layout.step_mode),
                    .attributes_ptr = js_attrs.ptr,
                    .attribute_count = @intCast(js_attrs.len),
                };
            }

            // Convert fragment targets if present
            var js_fragment_targets: []web.ColorTargetStateJS = &.{};
            var fragment_targets_allocation: ?[]web.ColorTargetStateJS = null;
            defer if (fragment_targets_allocation) |alloc| std.heap.page_allocator.free(alloc);

            if (desc.fragment) |fragment| {
                var targets = try std.heap.page_allocator.alloc(web.ColorTargetStateJS, fragment.targets.len);
                fragment_targets_allocation = targets;

                for (fragment.targets, 0..) |target, i| {
                    targets[i] = .{
                        .format = @intFromEnum(target.format),
                        .blend_enabled = target.blend != null,
                        .color_operation = if (target.blend) |blend| @intFromEnum(blend.color.operation) else 0,
                        .color_src_factor = if (target.blend) |blend| @intFromEnum(blend.color.src_factor) else 0,
                        .color_dst_factor = if (target.blend) |blend| @intFromEnum(blend.color.dst_factor) else 0,
                        .alpha_operation = if (target.blend) |blend| @intFromEnum(blend.alpha.operation) else 0,
                        .alpha_src_factor = if (target.blend) |blend| @intFromEnum(blend.alpha.src_factor) else 0,
                        .alpha_dst_factor = if (target.blend) |blend| @intFromEnum(blend.alpha.dst_factor) else 0,
                        .write_mask = target.write_mask,
                    };
                }

                js_fragment_targets = targets;
            }

            const handle = web.webgpuCreateRenderPipeline(
                self.device,
                if (desc.layout) |layout| layout.handle else 0,
                // Vertex stage
                desc.vertex.module.handle,
                desc.vertex.entry_point.ptr,
                @intCast(desc.vertex.entry_point.len),
                js_vertex_buffers.ptr,
                @intCast(js_vertex_buffers.len),
                // Primitive
                @intFromEnum(desc.primitive.topology),
                if (desc.primitive.strip_index_format) |fmt| @intFromEnum(fmt) else 0,
                @intFromEnum(desc.primitive.front_face),
                @intFromEnum(desc.primitive.cull_mode),
                // Fragment stage
                if (desc.fragment) |frag| frag.module.handle else 0,
                if (desc.fragment) |frag| frag.entry_point.ptr else @as([*]const u8, undefined),
                if (desc.fragment) |frag| @as(u32, @intCast(frag.entry_point.len)) else 0,
                js_fragment_targets.ptr,
                @intCast(js_fragment_targets.len),
                // Depth/stencil
                if (desc.depth_stencil) |ds| @intFromEnum(ds.format) else 0,
                if (desc.depth_stencil) |ds| ds.depth_write_enabled else false,
                if (desc.depth_stencil) |ds| @intFromEnum(ds.depth_compare) else 0,
                // Multisample
                desc.multisample.count,
                desc.multisample.mask,
                desc.multisample.alpha_to_coverage_enabled,
            );

            return RenderPipeline{ .handle = handle };
        } else {
            // Native implementation
            const allocator = std.heap.page_allocator;

            // Convert vertex buffer layouts
            var wgpu_vertex_buffers = try allocator.alloc(native.WGPUVertexBufferLayout, desc.vertex.buffers.len);
            defer allocator.free(wgpu_vertex_buffers);

            // Track attribute allocations for cleanup
            var vertex_attributes_allocations: [8]?[]native.WGPUVertexAttribute = [_]?[]native.WGPUVertexAttribute{null} ** 8;
            defer {
                for (vertex_attributes_allocations) |maybe_attrs| {
                    if (maybe_attrs) |attrs| allocator.free(attrs);
                }
            }

            for (desc.vertex.buffers, 0..) |buffer_layout, i| {
                // Convert attributes
                var wgpu_attrs = try allocator.alloc(native.WGPUVertexAttribute, buffer_layout.attributes.len);
                vertex_attributes_allocations[i] = wgpu_attrs;

                for (buffer_layout.attributes, 0..) |attr, j| {
                    wgpu_attrs[j] = .{
                        .format = @enumFromInt(@intFromEnum(attr.format)),
                        .offset = attr.offset,
                        .shader_location = attr.shader_location,
                    };
                }

                wgpu_vertex_buffers[i] = .{
                    .array_stride = buffer_layout.array_stride,
                    .step_mode = @enumFromInt(@intFromEnum(buffer_layout.step_mode)),
                    .attribute_count = wgpu_attrs.len,
                    .attributes = wgpu_attrs.ptr,
                };
            }

            // Convert vertex shader entry point to null-terminated string
            const vertex_entry = try allocator.dupeZ(u8, desc.vertex.entry_point);
            defer allocator.free(vertex_entry);

            // Build vertex state
            const vertex_state = native.WGPUVertexState{
                .module = desc.vertex.module.handle,
                .entry_point = vertex_entry.ptr,
                .buffer_count = wgpu_vertex_buffers.len,
                .buffers = if (wgpu_vertex_buffers.len > 0) wgpu_vertex_buffers.ptr else null,
            };

            // Build primitive state
            const primitive_state = native.WGPUPrimitiveState{
                .topology = @enumFromInt(@intFromEnum(desc.primitive.topology)),
                .strip_index_format = if (desc.primitive.strip_index_format) |fmt| @enumFromInt(@intFromEnum(fmt)) else .undefined,
                .front_face = @enumFromInt(@intFromEnum(desc.primitive.front_face)),
                .cull_mode = @enumFromInt(@intFromEnum(desc.primitive.cull_mode)),
            };

            // Build multisample state
            const multisample_state = native.WGPUMultisampleState{
                .count = desc.multisample.count,
                .mask = desc.multisample.mask,
                .alpha_to_coverage_enabled = if (desc.multisample.alpha_to_coverage_enabled) @as(u32, 1) else 0,
            };

            // Convert fragment state if present
            var fragment_state_storage: native.WGPUFragmentState = undefined;
            var fragment_ptr: ?*const native.WGPUFragmentState = null;
            var fragment_entry: ?[:0]u8 = null;
            var wgpu_targets: ?[]native.WGPUColorTargetState = null;
            defer {
                if (fragment_entry) |fe| allocator.free(fe);
                if (wgpu_targets) |targets| allocator.free(targets);
            }

            if (desc.fragment) |fragment| {
                // Convert fragment entry point
                fragment_entry = try allocator.dupeZ(u8, fragment.entry_point);

                // Convert color targets
                var targets = try allocator.alloc(native.WGPUColorTargetState, fragment.targets.len);
                wgpu_targets = targets;

                for (fragment.targets, 0..) |target, i| {
                    targets[i] = .{
                        .format = @enumFromInt(@intFromEnum(target.format)),
                        .blend = null, // TODO: Handle blend state if needed
                        .write_mask = target.write_mask,
                    };
                }

                fragment_state_storage = native.WGPUFragmentState{
                    .module = fragment.module.handle,
                    .entry_point = fragment_entry.?.ptr,
                    .target_count = targets.len,
                    .targets = targets.ptr,
                };
                fragment_ptr = &fragment_state_storage;
            }

            // Build pipeline descriptor
            var pipeline_desc = native.WGPURenderPipelineDescriptor{
                .label = null,
                .layout = if (desc.layout) |layout| layout.handle else null,
                .vertex = vertex_state,
                .primitive = primitive_state,
                .depth_stencil = null, // TODO: Handle depth/stencil if needed
                .multisample = multisample_state,
                .fragment = fragment_ptr,
            };

            // Create pipeline
            const handle = native.wgpuDeviceCreateRenderPipeline(self.device, &pipeline_desc);
            if (handle == null) return error.PipelineCreationFailed;

            return RenderPipeline{ .handle = handle };
        }
    }

    /// Create a compute pipeline
    pub fn createComputePipeline(self: *GPU, desc: ComputePipelineDescriptor) !ComputePipeline {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const handle = web.webgpuCreateComputePipeline(
                self.device,
                if (desc.layout) |layout| layout.handle else 0,
                desc.compute.module.handle,
                desc.compute.entry_point.ptr,
                @intCast(desc.compute.entry_point.len),
            );
            return ComputePipeline{ .handle = handle };
        } else {
            // Native implementation
            // TODO: Implement when native backend is ready
            return error.NotImplementedYet;
        }
    }

    /// Create a bind group layout
    pub fn createBindGroupLayout(self: *GPU, desc: BindGroupLayoutDescriptor) !BindGroupLayout {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            // Convert entries to JS format
            var js_entries = try std.heap.page_allocator.alloc(web.BindGroupLayoutEntryJS, desc.entries.len);
            defer std.heap.page_allocator.free(js_entries);

            for (desc.entries, 0..) |entry, i| {
                js_entries[i] = .{
                    .binding = entry.binding,
                    .visibility = @bitCast(entry.visibility),
                    .buffer_type = if (entry.buffer) |buf| switch (buf.type) {
                        .uniform => 1,
                        .storage => 2,
                        .read_only_storage => 3,
                    } else 0,
                    .buffer_has_dynamic_offset = if (entry.buffer) |buf| buf.has_dynamic_offset else false,
                    .buffer_min_binding_size = if (entry.buffer) |buf| buf.min_binding_size else 0,
                    .sampler_type = if (entry.sampler) |samp| switch (samp.type) {
                        .filtering => 1,
                        .non_filtering => 2,
                        .comparison => 3,
                    } else 0,
                    .texture_sample_type = if (entry.texture) |tex| switch (tex.sample_type) {
                        .float => 1,
                        .unfilterable_float => 2,
                        .depth => 3,
                        .sint => 4,
                        .uint => 5,
                    } else 0,
                    .texture_view_dimension = if (entry.texture) |tex| @intFromEnum(tex.view_dimension) else 0,
                    .texture_multisampled = if (entry.texture) |tex| tex.multisampled else false,
                    .storage_access = if (entry.storage_texture) |st| @intFromEnum(st.access) + 1 else 0,
                    .storage_format = if (entry.storage_texture) |st| @intFromEnum(st.format) else 0,
                    .storage_view_dimension = if (entry.storage_texture) |st| @intFromEnum(st.view_dimension) else 0,
                };
            }

            const handle = web.webgpuCreateBindGroupLayout(
                self.device,
                js_entries.ptr,
                @intCast(js_entries.len),
            );
            return BindGroupLayout{ .handle = handle };
        } else {
            // Native implementation
            var native_entries = try std.heap.page_allocator.alloc(native.WGPUBindGroupLayoutEntry, desc.entries.len);
            defer std.heap.page_allocator.free(native_entries);

            for (desc.entries, 0..) |entry, i| {
                // Convert ShaderStage flags
                var visibility: u32 = 0;
                if (entry.visibility.vertex) {
                    visibility |= native.WGPUShaderStage_Vertex;
                }
                if (entry.visibility.fragment) {
                    visibility |= native.WGPUShaderStage_Fragment;
                }
                if (entry.visibility.compute) {
                    visibility |= native.WGPUShaderStage_Compute;
                }

                native_entries[i] = .{
                    .binding = entry.binding,
                    .visibility = visibility,
                    .buffer = if (entry.buffer) |buf| .{
                        .type = switch (buf.type) {
                            .uniform => .uniform,
                            .storage => .storage,
                            .read_only_storage => .read_only_storage,
                        },
                        .has_dynamic_offset = if (buf.has_dynamic_offset) 1 else 0,
                        .min_binding_size = buf.min_binding_size,
                    } else .{},
                    .sampler = if (entry.sampler) |samp| .{
                        .type = switch (samp.type) {
                            .filtering => .filtering,
                            .non_filtering => .non_filtering,
                            .comparison => .comparison,
                        },
                    } else .{},
                    .texture = if (entry.texture) |tex| .{
                        .sample_type = switch (tex.sample_type) {
                            .float => .float,
                            .unfilterable_float => .unfilterable_float,
                            .depth => .depth,
                            .sint => .sint,
                            .uint => .uint,
                        },
                        .view_dimension = @enumFromInt(@intFromEnum(tex.view_dimension)),
                        .multisampled = tex.multisampled,
                    } else .{},
                    .storage_texture = if (entry.storage_texture) |st| .{
                        .access = switch (st.access) {
                            .write_only => .write_only,
                            .read_only => .read_only,
                            .read_write => .read_write,
                        },
                        .format = @enumFromInt(@intFromEnum(st.format)),
                        .view_dimension = @enumFromInt(@intFromEnum(st.view_dimension)),
                    } else .{},
                };
            }

            const native_desc = native.WGPUBindGroupLayoutDescriptor{
                .label = null, // TODO: Convert label to null-terminated string
                .entry_count = @intCast(native_entries.len),
                .entries = native_entries.ptr,
            };

            const handle = native.wgpuDeviceCreateBindGroupLayout(self.device, &native_desc);
            return BindGroupLayout{ .handle = handle };
        }
    }

    /// Create a bind group
    pub fn createBindGroup(self: *GPU, desc: BindGroupDescriptor) !BindGroup {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            // Convert entries to JS format
            var js_entries = try std.heap.page_allocator.alloc(web.BindGroupEntryJS, desc.entries.len);
            defer std.heap.page_allocator.free(js_entries);

            for (desc.entries, 0..) |entry, i| {
                js_entries[i] = .{
                    .binding = entry.binding,
                    .resource_type = if (entry.buffer != null) 1 else if (entry.sampler != null) 2 else if (entry.texture_view != null) 3 else 0,
                    .buffer = if (entry.buffer) |buf| buf.handle else 0,
                    .buffer_offset = entry.offset,
                    .buffer_size = entry.size,
                    .sampler = if (entry.sampler) |samp| samp.handle else 0,
                    .texture_view = if (entry.texture_view) |view| view.handle else 0,
                };
            }

            const handle = web.webgpuCreateBindGroup(
                self.device,
                desc.layout.handle,
                js_entries.ptr,
                @intCast(js_entries.len),
            );
            return BindGroup{ .handle = handle };
        } else {
            // Native implementation
            var native_entries = try std.heap.page_allocator.alloc(native.WGPUBindGroupEntry, desc.entries.len);
            defer std.heap.page_allocator.free(native_entries);

            for (desc.entries, 0..) |entry, i| {
                native_entries[i] = .{
                    .binding = entry.binding,
                    .buffer = if (entry.buffer) |buf| buf.handle else null,
                    .offset = entry.offset,
                    .size = entry.size,
                    .sampler = if (entry.sampler) |samp| samp.handle else null,
                    .texture_view = if (entry.texture_view) |view| view.handle else null,
                };
            }

            const native_desc = native.WGPUBindGroupDescriptor{
                .label = null, // TODO: Convert label to null-terminated string
                .layout = desc.layout.handle,
                .entry_count = @intCast(native_entries.len),
                .entries = native_entries.ptr,
            };

            const handle = native.wgpuDeviceCreateBindGroup(self.device, &native_desc);
            return BindGroup{ .handle = handle };
        }
    }

    /// Create a pipeline layout (defines bind group layouts for a pipeline)
    pub fn createPipelineLayout(self: *GPU, desc: PipelineLayoutDescriptor) !PipelineLayout {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            // Convert bind group layouts to handle array
            var handles = try std.heap.page_allocator.alloc(web.WebGPUBindGroupLayout, desc.bind_group_layouts.len);
            defer std.heap.page_allocator.free(handles);

            for (desc.bind_group_layouts, 0..) |layout, i| {
                handles[i] = layout.handle;
            }

            const handle = web.webgpuCreatePipelineLayout(
                self.device,
                handles.ptr,
                @intCast(handles.len),
            );
            return PipelineLayout{ .handle = handle };
        } else {
            // Native implementation
            var native_layouts = try std.heap.page_allocator.alloc(native.WGPUBindGroupLayout, desc.bind_group_layouts.len);
            defer std.heap.page_allocator.free(native_layouts);

            for (desc.bind_group_layouts, 0..) |layout, i| {
                native_layouts[i] = layout.handle;
            }

            const native_desc = native.WGPUPipelineLayoutDescriptor{
                .label = null, // TODO: Convert label to null-terminated string
                .bind_group_layout_count = @intCast(native_layouts.len),
                .bind_group_layouts = native_layouts.ptr,
            };

            const handle = native.wgpuDeviceCreatePipelineLayout(self.device, &native_desc);
            return PipelineLayout{ .handle = handle };
        }
    }

    // =========================================================================
    // Command Encoding
    // =========================================================================

    /// Create a command encoder for recording GPU commands
    pub fn createCommandEncoder(self: *GPU) !CommandEncoder {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const handle = web.webgpuCreateCommandEncoder(self.device);
            return CommandEncoder{ .handle = handle };
        } else {
            const handle = native.wgpuDeviceCreateCommandEncoder(self.device, null);
            return CommandEncoder{ .handle = handle orelse return error.EncoderCreationFailed };
        }
    }

    /// Get the current swap chain texture view (for rendering to screen)
    pub fn getCurrentTextureView(self: *GPU) !TextureView {
        if (!self.isReady()) return error.GPUNotReady;

        if (comptime is_wasm) {
            const handle = web.webgpuGetCurrentTextureView();
            return TextureView{ .handle = handle };
        } else {
            // Native: Get current texture from surface
            var surface_texture: native.WGPUSurfaceTexture = undefined;
            native.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);

            // Check if we got a valid texture
            if (surface_texture.status != .success) {
                return error.SurfaceTextureError;
            }

            // Create a texture view
            const view = native.wgpuTextureCreateView(surface_texture.texture, null);
            if (view == null) return error.TextureViewCreationFailed;

            return TextureView{ .handle = view };
        }
    }

    /// Present the current frame to screen
    pub fn present(self: *GPU) void {
        if (!self.isReady()) return;

        if (comptime is_wasm) {
            web.webgpuPresent();
        } else {
            // Native: Present the surface
            native.wgpuSurfacePresent(self.surface);
        }
    }

    // =========================================================================
    // Legacy 2D API (for backward compatibility with old examples)
    // =========================================================================
    // These methods are deprecated and will be removed once examples are updated

    /// @deprecated Use WebGPU command encoding instead
    pub fn beginFrame(self: *GPU) void {
        _ = self;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU command encoding instead
    pub fn endFrame(self: *GPU) void {
        _ = self;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU render pipeline instead
    pub fn clearScreen(self: *GPU, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU vertex buffers instead
    pub fn drawLine(self: *GPU, x1: f32, y1: f32, x2: f32, y2: f32, line_width: f32, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = x1;
        _ = y1;
        _ = x2;
        _ = y2;
        _ = line_width;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU vertex buffers instead
    pub fn drawCircle(self: *GPU, x: f32, y: f32, radius: f32, line_width: f32, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = radius;
        _ = line_width;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU vertex buffers instead
    pub fn drawRect(self: *GPU, x: f32, y: f32, width: f32, height: f32, line_width: f32, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = line_width;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU vertex buffers instead
    pub fn drawFilledRect(self: *GPU, x: f32, y: f32, width: f32, height: f32, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU vertex buffers instead
    pub fn drawFilledCircle(self: *GPU, x: f32, y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = radius;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    /// @deprecated Use WebGPU vertex buffers instead
    pub fn drawRoundedRect(self: *GPU, x: f32, y: f32, width: f32, height: f32, corner_radius: f32, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = corner_radius;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
        // No-op: Legacy method for old 2D examples
    }

    // =========================================================================
    // Queue Operations
    // =========================================================================

    /// Submit command buffers to the GPU queue
    pub fn submit(self: *GPU, command_buffers: []const CommandBuffer) void {
        if (!self.isReady()) return;

        if (comptime is_wasm) {
            const handles = std.mem.sliceAsBytes(command_buffers);
            web.webgpuQueueSubmit(
                self.queue,
                @ptrCast(handles.ptr),
                @intCast(command_buffers.len),
            );
        } else {
            var c_buffers: [16]native.WGPUCommandBuffer = undefined;
            const count = @min(command_buffers.len, c_buffers.len);
            for (command_buffers[0..count], 0..) |buf, i| {
                c_buffers[i] = buf.handle;
            }
            native.wgpuQueueSubmit(self.queue, @intCast(count), &c_buffers);

            // Poll device to process submitted work (wgpu-native extension)
            _ = native.wgpuDevicePoll(self.device, 1, null); // wait=true

            // Release command buffers after processing
            for (command_buffers[0..count]) |buf| {
                native.wgpuCommandBufferRelease(buf.handle);
            }
        }
    }

    /// Write data to a buffer
    pub fn writeBuffer(self: *GPU, buffer: Buffer, offset: u64, data: []const u8) void {
        if (!self.isReady()) return;

        if (comptime is_wasm) {
            web.webgpuWriteBuffer(
                self.queue,
                buffer.handle,
                offset,
                data.ptr,
                data.len,
            );
        } else {
            native.wgpuQueueWriteBuffer(
                self.queue,
                buffer.handle,
                offset,
                data.ptr,
                data.len,
            );
        }
    }

    /// Write data to a texture
    pub fn writeTexture(
        self: *GPU,
        texture: Texture,
        data: []const u8,
        bytes_per_row: u32,
        rows_per_image: u32,
        size: Extent3D,
    ) void {
        if (!self.isReady()) return;

        if (comptime is_wasm) {
            web.webgpuWriteTexture(
                self.queue,
                texture.handle,
                0, // mip level
                0,
                0,
                0, // origin
                size.width,
                size.height,
                size.depth_or_array_layers,
                data.ptr,
                data.len,
                bytes_per_row,
                rows_per_image,
            );
        } else {
            const copy_texture = native.WGPUImageCopyTexture{
                .texture = texture.handle,
                .mip_level = 0,
                .origin = .{},
                .aspect = .all,
            };
            const data_layout = native.WGPUTextureDataLayout{
                .offset = 0,
                .bytes_per_row = bytes_per_row,
                .rows_per_image = rows_per_image,
            };
            const write_size = native.WGPUExtent3D{
                .width = size.width,
                .height = size.height,
                .depth_or_array_layers = size.depth_or_array_layers,
            };
            native.wgpuQueueWriteTexture(
                self.queue,
                &copy_texture,
                data.ptr,
                data.len,
                &data_layout,
                &write_size,
            );
        }
    }
};

// =============================================================================
// Resource Handle Types
// =============================================================================
// These wrap the platform-specific handles

pub const Buffer = struct {
    handle: if (is_wasm) web.WebGPUBuffer else native.WGPUBuffer,

    pub fn destroy(self: Buffer) void {
        if (comptime is_wasm) {
            web.webgpuBufferDestroy(self.handle);
        } else {
            native.wgpuBufferDestroy(self.handle);
        }
    }
};

pub const Texture = struct {
    handle: if (is_wasm) web.WebGPUTexture else native.WGPUTexture,

    pub fn createView(self: Texture, desc: types.TextureViewDescriptor) !TextureView {
        if (comptime is_wasm) {
            const handle = web.webgpuCreateTextureView(
                self.handle,
                if (desc.format) |f| @intFromEnum(f) else 0,
                if (desc.dimension) |d| @intFromEnum(d) else 0,
                @intFromEnum(desc.aspect),
                desc.base_mip_level,
                desc.mip_level_count orelse 0xFFFFFFFF,
                desc.base_array_layer,
                desc.array_layer_count orelse 0xFFFFFFFF,
            );
            return TextureView{ .handle = handle };
        } else {
            const c_desc = native.WGPUTextureViewDescriptor{
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
                .format = if (desc.format) |f| @enumFromInt(@intFromEnum(f)) else .undefined,
                .dimension = if (desc.dimension) |d| @enumFromInt(@intFromEnum(d)) else .undefined,
                .base_mip_level = desc.base_mip_level,
                .mip_level_count = desc.mip_level_count orelse 0xFFFFFFFF,
                .base_array_layer = desc.base_array_layer,
                .array_layer_count = desc.array_layer_count orelse 0xFFFFFFFF,
                .aspect = @enumFromInt(@intFromEnum(desc.aspect)),
            };
            const handle = native.wgpuTextureCreateView(self.handle, &c_desc);
            return TextureView{ .handle = handle orelse return error.ViewCreationFailed };
        }
    }

    pub fn destroy(self: Texture) void {
        if (comptime is_wasm) {
            web.webgpuTextureDestroy(self.handle);
        } else {
            native.wgpuTextureDestroy(self.handle);
        }
    }
};

pub const TextureView = struct {
    handle: if (is_wasm) web.WebGPUTextureView else native.WGPUTextureView,

    pub fn release(self: TextureView) void {
        if (comptime is_wasm) {
            // WASM handles cleanup automatically
        } else {
            native.wgpuTextureViewRelease(self.handle);
        }
    }
};

pub const Sampler = struct {
    handle: if (is_wasm) web.WebGPUSampler else native.WGPUSampler,
};

pub const ShaderModule = struct {
    handle: if (is_wasm) web.WebGPUShaderModule else native.WGPUShaderModule,
};

pub const RenderPipeline = struct {
    handle: if (is_wasm) web.WebGPURenderPipeline else native.WGPURenderPipeline,
};

pub const ComputePipeline = struct {
    handle: if (is_wasm) web.WebGPUComputePipeline else native.WGPUComputePipeline,
};

pub const BindGroupLayout = struct {
    handle: if (is_wasm) web.WebGPUBindGroupLayout else native.WGPUBindGroupLayout,
};

pub const BindGroup = struct {
    handle: if (is_wasm) web.WebGPUBindGroup else native.WGPUBindGroup,
};

pub const PipelineLayout = struct {
    handle: if (is_wasm) web.WebGPUPipelineLayout else native.WGPUPipelineLayout,
};

pub const CommandEncoder = struct {
    handle: if (is_wasm) web.WebGPUCommandEncoder else native.WGPUCommandEncoder,

    /// Begin a render pass for drawing
    pub fn beginRenderPass(self: CommandEncoder, desc: RenderPassDescriptor) !RenderPassEncoder {
        if (comptime is_wasm) {
            // Convert descriptor to JS format
            var color_attachments: [8]web.RenderPassColorAttachmentJS = undefined;
            for (desc.color_attachments, 0..) |att, i| {
                color_attachments[i] = .{
                    .view = att.view.handle,
                    .resolve_target = if (att.resolve_target) |rt| rt.handle else 0,
                    .load_op = @intFromEnum(att.load_op),
                    .store_op = @intFromEnum(att.store_op),
                    .clear_r = att.clear_value.r,
                    .clear_g = att.clear_value.g,
                    .clear_b = att.clear_value.b,
                    .clear_a = att.clear_value.a,
                };
            }

            const handle = web.webgpuCommandEncoderBeginRenderPass(
                self.handle,
                &color_attachments,
                @intCast(desc.color_attachments.len),
                if (desc.depth_stencil_attachment) |ds| ds.view.handle else 0,
                if (desc.depth_stencil_attachment) |ds| @intFromEnum(ds.depth_load_op) else 0,
                if (desc.depth_stencil_attachment) |ds| @intFromEnum(ds.depth_store_op) else 0,
                if (desc.depth_stencil_attachment) |ds| ds.depth_clear_value else 0,
                if (desc.depth_stencil_attachment) |ds| @intFromEnum(ds.stencil_load_op) else 0,
                if (desc.depth_stencil_attachment) |ds| @intFromEnum(ds.stencil_store_op) else 0,
                if (desc.depth_stencil_attachment) |ds| ds.stencil_clear_value else 0,
            );
            return RenderPassEncoder{ .handle = handle };
        } else {
            // Convert descriptor to C format
            var color_attachments: [8]native.WGPURenderPassColorAttachment = std.mem.zeroes([8]native.WGPURenderPassColorAttachment);
            for (desc.color_attachments, 0..) |att, i| {
                // Initialize each field explicitly
                color_attachments[i].next_in_chain = null;
                color_attachments[i].view = att.view.handle;
                color_attachments[i].resolve_target = if (att.resolve_target) |rt| rt.handle else null;
                color_attachments[i].load_op = @enumFromInt(@intFromEnum(att.load_op));
                color_attachments[i].store_op = @enumFromInt(@intFromEnum(att.store_op));
                color_attachments[i].clear_value.r = att.clear_value.r;
                color_attachments[i].clear_value.g = att.clear_value.g;
                color_attachments[i].clear_value.b = att.clear_value.b;
                color_attachments[i].clear_value.a = att.clear_value.a;
            }

            var depth_stencil: ?native.WGPURenderPassDepthStencilAttachment = null;
            if (desc.depth_stencil_attachment) |ds| {
                depth_stencil = .{
                    .view = ds.view.handle,
                    .depth_load_op = @enumFromInt(@intFromEnum(ds.depth_load_op)),
                    .depth_store_op = @enumFromInt(@intFromEnum(ds.depth_store_op)),
                    .depth_clear_value = ds.depth_clear_value,
                    .depth_read_only = if (ds.depth_read_only) @as(u32, 1) else 0,
                    .stencil_load_op = @enumFromInt(@intFromEnum(ds.stencil_load_op)),
                    .stencil_store_op = @enumFromInt(@intFromEnum(ds.stencil_store_op)),
                    .stencil_clear_value = ds.stencil_clear_value,
                    .stencil_read_only = if (ds.stencil_read_only) @as(u32, 1) else 0,
                };
            }

            const c_desc = native.WGPURenderPassDescriptor{
                .next_in_chain = null,
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
                .color_attachment_count = desc.color_attachments.len,
                .color_attachments = color_attachments[0..desc.color_attachments.len].ptr,
                .depth_stencil_attachment = if (depth_stencil) |*ds| ds else null,
                .occlusion_query_set = null,
                .timestamp_write_count = 0,
                .timestamp_writes = null,
            };

            const handle = native.wgpuCommandEncoderBeginRenderPass(self.handle, &c_desc);
            return RenderPassEncoder{ .handle = handle orelse return error.RenderPassCreationFailed };
        }
    }

    /// Finish encoding and return command buffer
    pub fn finish(self: CommandEncoder) !CommandBuffer {
        if (comptime is_wasm) {
            const handle = web.webgpuCommandEncoderFinish(self.handle);
            return CommandBuffer{ .handle = handle };
        } else {
            const handle = native.wgpuCommandEncoderFinish(self.handle, null);
            native.wgpuCommandEncoderRelease(self.handle);
            return CommandBuffer{ .handle = handle orelse return error.CommandBufferCreationFailed };
        }
    }
};

pub const RenderPassEncoder = struct {
    handle: if (is_wasm) web.WebGPURenderPassEncoder else native.WGPURenderPassEncoder,

    pub fn setPipeline(self: RenderPassEncoder, pipeline: RenderPipeline) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassSetPipeline(self.handle, pipeline.handle);
        } else {
            native.wgpuRenderPassEncoderSetPipeline(self.handle, pipeline.handle);
        }
    }

    pub fn setBindGroup(self: RenderPassEncoder, index: u32, bind_group: BindGroup) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassSetBindGroup(self.handle, index, bind_group.handle, null, 0);
        } else {
            native.wgpuRenderPassEncoderSetBindGroup(self.handle, index, bind_group.handle, 0, null);
        }
    }

    pub fn setVertexBuffer(self: RenderPassEncoder, slot: u32, buffer: Buffer, offset: u64, size: u64) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassSetVertexBuffer(self.handle, slot, buffer.handle, offset, size);
        } else {
            native.wgpuRenderPassEncoderSetVertexBuffer(self.handle, slot, buffer.handle, offset, size);
        }
    }

    pub fn setIndexBuffer(self: RenderPassEncoder, buffer: Buffer, format: IndexFormat, offset: u64, size: u64) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassSetIndexBuffer(self.handle, buffer.handle, @intFromEnum(format), offset, size);
        } else {
            native.wgpuRenderPassEncoderSetIndexBuffer(self.handle, buffer.handle, @enumFromInt(@intFromEnum(format)), offset, size);
        }
    }

    pub fn draw(self: RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassDraw(self.handle, vertex_count, instance_count, first_vertex, first_instance);
        } else {
            native.wgpuRenderPassEncoderDraw(self.handle, vertex_count, instance_count, first_vertex, first_instance);
        }
    }

    pub fn drawIndexed(self: RenderPassEncoder, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassDrawIndexed(self.handle, index_count, instance_count, first_index, base_vertex, first_instance);
        } else {
            native.wgpuRenderPassEncoderDrawIndexed(self.handle, index_count, instance_count, first_index, base_vertex, first_instance);
        }
    }

    pub fn end(self: RenderPassEncoder) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassEnd(self.handle);
        } else {
            native.wgpuRenderPassEncoderEnd(self.handle);
            native.wgpuRenderPassEncoderRelease(self.handle);
        }
    }
};

pub const CommandBuffer = struct {
    handle: if (is_wasm) web.WebGPUCommandBuffer else native.WGPUCommandBuffer,
};

// =============================================================================
// Descriptor Types (referencing concrete handle types)
// =============================================================================
// These override the types.zig versions to use the concrete handle types above

/// Vertex state for render pipeline
pub const VertexState = struct {
    module: *ShaderModule,
    entry_point: []const u8,
    buffers: []const types.VertexBufferLayout = &.{},
};

/// Fragment state for render pipeline
pub const FragmentState = struct {
    module: *ShaderModule,
    entry_point: []const u8,
    targets: []const types.ColorTargetState,
};

/// Compute state for compute pipeline
pub const ComputeState = struct {
    module: *ShaderModule,
    entry_point: []const u8,
};

/// Render pass color attachment
pub const RenderPassColorAttachment = struct {
    view: *TextureView,
    resolve_target: ?*TextureView = null,
    load_op: LoadOp,
    store_op: StoreOp,
    clear_value: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
};

/// Render pass depth stencil attachment
pub const RenderPassDepthStencilAttachment = struct {
    view: *TextureView,
    depth_load_op: LoadOp = .load,
    depth_store_op: StoreOp = .store,
    depth_clear_value: f32 = 0.0,
    depth_read_only: bool = false,
    stencil_load_op: LoadOp = .load,
    stencil_store_op: StoreOp = .store,
    stencil_clear_value: u32 = 0,
    stencil_read_only: bool = false,
};

/// Render pass descriptor (overrides types.zig version)
pub const RenderPassDescriptor = struct {
    label: ?[]const u8 = null,
    color_attachments: []const RenderPassColorAttachment,
    depth_stencil_attachment: ?RenderPassDepthStencilAttachment = null,
};

/// Render pipeline descriptor (overrides types.zig version)
pub const RenderPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: ?*PipelineLayout = null,
    vertex: VertexState,
    primitive: types.PrimitiveState = .{},
    depth_stencil: ?types.DepthStencilState = null,
    multisample: types.MultisampleState = .{},
    fragment: ?FragmentState = null,
};

/// Compute pipeline descriptor (overrides types.zig version)
pub const ComputePipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: ?*PipelineLayout = null,
    compute: ComputeState,
};

/// Bind group entry (overrides types.zig version)
pub const BindGroupEntry = struct {
    binding: u32,
    buffer: ?*Buffer = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler: ?*Sampler = null,
    texture_view: ?*TextureView = null,
};

/// Bind group descriptor (overrides types.zig version)
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: *BindGroupLayout,
    entries: []const BindGroupEntry,
};

/// Pipeline layout descriptor (overrides types.zig version)
pub const PipelineLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    bind_group_layouts: []const *BindGroupLayout,
};

/// Image copy buffer (overrides types.zig version)
pub const ImageCopyBuffer = struct {
    buffer: *Buffer,
    offset: u64 = 0,
    bytes_per_row: u32,
    rows_per_image: u32,
};

/// Image copy texture (overrides types.zig version)
pub const ImageCopyTexture = struct {
    texture: *Texture,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: types.TextureAspect = .all,
};
