//! WebGPU Wrapper - Full 3D Graphics API
//! Source: W3C WebGPU Specification (https://www.w3.org/TR/webgpu/)
//!
//! This is a thin wrapper over WebGPU that works identically on web and native.
//! It exposes the full WebGPU API for 3D rendering, compute shaders, and everything
//! the GPU can do - not a simplified 2D Canvas subset.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const fxaa = @import("fxaa.zig");

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
pub const TextureRegion = types.TextureRegion;
pub const TextureViewDescriptor = types.TextureViewDescriptor;

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

/// Map types.CompareFunction to WGPUCompareFunction.
/// The Zig types enum starts at 0 (never=0), but WGPUCompareFunction has
/// undefined=0 and never=1, so a raw @intFromEnum cast is off by one.
/// Additionally, `equal`, `not_equal`, and `greater_equal` are in a
/// different order between the two enums, so only a named switch is safe.
fn toNativeCompareFunction(cf: types.CompareFunction) native.WGPUCompareFunction {
    return switch (cf) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_equal,
        .always => .always,
    };
}

/// Map types.AddressMode to WGPUAddressMode. The Zig enum starts with
/// clamp_to_edge=0, but WGPUAddressMode starts with repeat=0.
fn toNativeAddressMode(mode: types.AddressMode) native.WGPUAddressMode {
    return switch (mode) {
        .clamp_to_edge => .clamp_to_edge,
        .repeat => .repeat,
        .mirror_repeat => .mirror_repeat,
    };
}

fn toNativeFilterMode(mode: types.FilterMode) native.WGPUFilterMode {
    return switch (mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

/// The view dimension number of WGPUTextureViewDimension and of webgpu.ts
/// (createTextureView): 0 is "the default of the texture", then 1d=1 up to
/// 3d=6. types.TextureViewDimension starts at 1d=0, so a raw @backingInt
/// gives the wrong dimension.
fn viewDimensionCode(dimension: ?types.TextureViewDimension) u32 {
    const d = dimension orelse return 0;
    return switch (d) {
        .@"1d" => 1,
        .@"2d" => 2,
        .@"2d-array" => 3,
        .cube => 4,
        .cube_array => 5,
        .@"3d" => 6,
    };
}

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
/// Native: the most submits that run on the GPU at once. See GPU.submit().
const MAX_FRAMES_IN_FLIGHT = 2;

pub const GPU = struct {
    state: GPUState = .uninitialized,
    device: if (is_wasm) web.WebGPUDevice else native.WGPUDevice = if (is_wasm) 0 else null,
    queue: if (is_wasm) web.WebGPUQueue else native.WGPUQueue = if (is_wasm) 0 else null,

    // Native-only fields for WebGPU state
    instance: if (!is_wasm) native.WGPUInstance else void = if (!is_wasm) null else {},
    adapter: if (!is_wasm) native.WGPUAdapter else void = if (!is_wasm) null else {},
    surface: if (!is_wasm) native.WGPUSurface else void = if (!is_wasm) null else {},
    // Surface size in pixels. Native: the wgpu surface. Web: the canvas, which
    // the browser sizes. The web glue keeps it current with setSurfaceSize().
    width: u32 = 0,
    height: u32 = 0,

    // Native: submission indices of the last MAX_FRAMES_IN_FLIGHT submits, in
    // a ring. submit() waits for the oldest before it reuses its slot.
    in_flight: [MAX_FRAMES_IN_FLIGHT]?u64 = @splat(null),
    submit_count: u64 = 0,

    // MSAA state — populated by configureMSAA(); null if MSAA is off (sample_count == 1)
    msaa_sample_count: u32 = 1,
    msaa_color_texture: ?Texture = null,
    msaa_color_view: ?TextureView = null,

    // FXAA state — populated by configureFXAA(); null if FXAA is off
    fxaa_color_texture: ?Texture = null,
    fxaa_color_view: ?TextureView = null,
    fxaa_sampler: ?Sampler = null,
    fxaa_bind_group: ?BindGroup = null,
    fxaa_pipeline: ?RenderPipeline = null,

    // Current-frame surface texture (native only) — set by getCurrentTextureView,
    // consumed by captureFrame, cleared by present().
    current_surface_texture: if (!is_wasm) ?native.WGPUTexture else void =
        if (!is_wasm) null else {},

    // Headless-offscreen state (native only). Populated by GPU.init when called
    // with `window == null`: a single bgra8unorm texture sized to width × height
    // with usage RenderAttachment | CopySrc | TextureBinding. Stands in for the
    // swapchain: getCurrentTextureView returns a fresh view over this texture,
    // captureFrame reads it, present() is a no-op. See
    // `examples/voxel/docs/headless-regressions.md`.
    offscreen_color_texture: if (!is_wasm) ?Texture else void =
        if (!is_wasm) null else {},

    /// The device has the timestamp query feature (REQ-GPU-028). Native
    /// only: `init` asks for the feature when the adapter has it. The web
    /// build does not ask for it, so the value stays false there.
    timestamps: bool = false,
    /// The surface waits for the display refresh (REQ-GPU-027). See
    /// `setVsync`.
    vsync: bool = true,

    /// Check if GPU is ready for use
    pub fn isReady(self: *const GPU) bool {
        return self.state == .ready;
    }

    /// Configure anti-aliasing.  Call after init() and before creating render pipelines.
    ///
    /// Only MSAA is currently implemented.  For FXAA/SMAA/SSAA/TAA the method logs a
    /// warning and leaves MSAA disabled (sample count stays at 1).
    ///
    /// WebGPU requires all implementations to support sample counts 1 and 4; any other
    /// value is rounded up to 4.  Calling configureMSAA again replaces the existing
    /// MSAA texture (the old one is destroyed).
    ///
    /// `fallback_width`/`fallback_height` are used only on WASM (native reads the
    /// surface size from the GPU struct, which always matches the swapchain).
    pub fn configureMSAA(self: *GPU, config: types.AntiAliasingConfig, fallback_width: u32, fallback_height: u32) !void {
        if (!self.isReady()) return error.GPUNotReady;

        const sample_count: u32 = switch (config.method) {
            .none => 1,
            .msaa => blk: {
                const req = config.msaa_samples;
                if (req <= 1) break :blk 1;
                if (comptime is_wasm) {
                    // WebGPU spec only guarantees sample counts 1 and 4.
                    break :blk 4;
                } else {
                    // Native (Metal/Vulkan/DX12): bgra8unorm surface format supports 1, 2, and 4.
                    // Sample count 8 requires TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES and is
                    // NOT supported for bgra8unorm on most devices — attempting it causes a
                    // wgpu-native panic.  Cap at 4; allow 2 which is widely supported natively.
                    if (req >= 4) break :blk @as(u32, 4);
                    break :blk @as(u32, 2);
                }
            },
            .fxaa => blk: {
                // FXAA is a post-process pass set up via configureFXAA() — no MSAA texture needed.
                break :blk 1;
            },
            .smaa, .ssaa, .taa => blk: {
                std.log.warn("sw_gpu: AA method '{s}' not yet implemented — no anti-aliasing applied", .{@tagName(config.method)});
                break :blk 1;
            },
        };

        if (config.method == .msaa and sample_count != config.msaa_samples) {
            std.log.warn("sw_gpu: --msaa={} clamped to {} (bgra8unorm surface format supports 1/2/4 on native; 1/4 on WebGPU)", .{
                config.msaa_samples, sample_count,
            });
        }
        std.log.info("sw_gpu: configureMSAA → sample_count={} (method={s} requested={})", .{
            sample_count, @tagName(config.method), config.msaa_samples,
        });

        // Destroy any existing MSAA texture
        if (self.msaa_color_texture) |tex| tex.destroy();
        self.msaa_color_texture = null;
        self.msaa_color_view = null;
        self.msaa_sample_count = sample_count;

        if (sample_count <= 1) return;

        // Use the surface dimensions recorded at GPU.init() time — these are guaranteed
        // to match the swapchain texture size.  On WASM we fall back to caller-supplied values.
        const tex_w = if (comptime !is_wasm) self.width else fallback_width;
        const tex_h = if (comptime !is_wasm) self.height else fallback_height;

        // Create the multisampled color render target (same format as the swapchain)
        const msaa_tex = try self.createTexture(.{
            .size = .{ .width = tex_w, .height = tex_h, .depth_or_array_layers = 1 },
            .format = .bgra8unorm,
            .sample_count = sample_count,
            .usage = .{ .render_attachment = true },
        });
        self.msaa_color_texture = msaa_tex;
        self.msaa_color_view = try msaa_tex.createView(.{});
    }

    /// Returns the active MSAA sample count (1 means no MSAA).
    pub fn getSampleCount(self: *const GPU) u32 {
        return self.msaa_sample_count;
    }

    /// Set up FXAA resources.  Call after init() and before creating render pipelines.
    ///
    /// Creates an offscreen colour texture matching the swapchain size (bgra8unorm,
    /// render_attachment + texture_binding), a linear sampler, a bind group, and the
    /// FXAA fullscreen-triangle render pipeline.
    ///
    /// The main render pass should target `fxaa_color_view` instead of the swapchain
    /// view.  After the main pass, call `runFXAAPass` to blit the FXAA result to the
    /// swapchain.  Calling `configureFXAA` again destroys the previous resources.
    ///
    /// `quality` selects the FXAA 3.11 preset tier. Each tier substitutes three
    /// tokens in `fxaa.wgsl` at shader-module create time — WGSL has no
    /// specialisation constants, so plain text substitution is the cheapest way
    /// to get per-quality pipelines. To change quality at runtime, call
    /// `configureFXAA` again from the render loop (see the `aa_dirty` flag in
    /// the voxel example).
    pub fn configureFXAA(self: *GPU, width: u32, height: u32, quality: types.FxaaQuality) !void {
        if (!self.isReady()) return error.GPUNotReady;

        // Destroy existing FXAA resources (safe to call even if null)
        if (self.fxaa_color_texture) |tex| tex.destroy();
        self.fxaa_color_texture = null;
        self.fxaa_color_view = null;
        // sampler / bind_group / pipeline: no destroy() in the current wrapper;
        // they are cleaned up by the GPU driver on shutdown or re-creation.
        // This follows the same pattern as bind groups in setupGPUResources.

        // Offscreen colour texture — same format as the swapchain, but with
        // texture_binding so FXAA can sample it in a subsequent pass.
        const tex_w = if (comptime !is_wasm) self.width else width;
        const tex_h = if (comptime !is_wasm) self.height else height;

        const fxaa_tex = try self.createTexture(.{
            .label = "fxaa_color",
            .size = .{ .width = tex_w, .height = tex_h, .depth_or_array_layers = 1 },
            .format = .bgra8unorm,
            .usage = .{ .render_attachment = true, .texture_binding = true },
        });
        self.fxaa_color_texture = fxaa_tex;
        self.fxaa_color_view = try fxaa_tex.createView(.{});

        // Linear sampler (bilinear filtering for smooth blending at edges)
        const fxaa_sampler = try self.createSampler(.{
            .label = "fxaa_sampler",
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });
        self.fxaa_sampler = fxaa_sampler;

        // Bind group layout: texture_2d<f32> at binding 0, sampler at binding 1
        var bg_layout = try self.createBindGroupLayout(.{
            .label = "fxaa_bgl",
            .entries = &[_]types.BindGroupLayoutEntry{
                .{
                    .binding = 0,
                    .visibility = .{ .fragment = true },
                    .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
                },
                .{
                    .binding = 1,
                    .visibility = .{ .fragment = true },
                    .sampler = .{ .type = .filtering },
                },
            },
        });

        // Bind group: wire up the FXAA colour view and sampler
        self.fxaa_bind_group = try self.createBindGroup(.{
            .layout = &bg_layout,
            .entries = &[_]BindGroupEntry{
                .{ .binding = 0, .texture_view = &self.fxaa_color_view.? },
                .{ .binding = 1, .sampler = &self.fxaa_sampler.? },
            },
        });

        // Pipeline layout
        var pipe_layout = try self.createPipelineLayout(.{
            .bind_group_layouts = &[_]*BindGroupLayout{&bg_layout},
        });

        // FXAA shader module. `fxaa.shaderSource` replaces the quality-tier
        // placeholders and puts the scene texture at group 0. The buffer
        // lives on the stack for this function: createShaderModule copies
        // it before we return.
        const preset = fxaa.preset(quality);
        const search_steps = preset.search_steps;
        const subpix_cap = preset.subpix_cap;
        const edge_threshold = preset.edge_threshold;
        var substituted_buf: [fxaa.max_source_len]u8 = undefined;
        const substituted = try fxaa.shaderSource(&substituted_buf, quality, 0);

        var fxaa_shader = try self.createShaderModule(.{
            .label = "fxaa_shader",
            .code = substituted,
        });

        // Render pipeline: no vertex buffers, one colour target (swapchain format)
        self.fxaa_pipeline = try self.createRenderPipeline(.{
            .layout = &pipe_layout,
            .vertex = .{
                .module = &fxaa_shader,
                .entry_point = "vs_main",
                .buffers = &[_]types.VertexBufferLayout{},
            },
            .fragment = .{
                .module = &fxaa_shader,
                .entry_point = "fs_main",
                .targets = &[_]types.ColorTargetState{.{
                    .format = .bgra8unorm,
                }},
            },
            .primitive = .{
                .topology = .triangle_list,
                .front_face = .ccw,
                .cull_mode = .none,
            },
            .multisample = .{ .count = 1 },
        });

        std.log.info("sw_gpu: configureFXAA → {}×{} bgra8unorm offscreen target (quality={s}, search_steps={s}, subpix_cap={s}, edge_threshold={s})", .{
            tex_w, tex_h, @tagName(quality), search_steps, subpix_cap, edge_threshold,
        });
    }

    /// Record an FXAA post-process pass into `encoder`.
    ///
    /// Reads from `self.fxaa_color_view` (populated by a preceding render pass) and
    /// writes to `swap_view` (the current swapchain texture view).  The pass clears
    /// the swapchain before writing, so `swap_view` must not have been used yet this
    /// frame.  Call this after the main render pass ends but before `encoder.finish`.
    pub fn runFXAAPass(self: *GPU, encoder: CommandEncoder, swap_view: *TextureView) !void {
        const pipeline = self.fxaa_pipeline orelse return error.FXAANotConfigured;
        const bind_group = self.fxaa_bind_group orelse return error.FXAANotConfigured;

        const pass = try encoder.beginRenderPass(.{
            .label = "fxaa_pass",
            .color_attachments = &[_]RenderPassColorAttachment{.{
                .view = swap_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            }},
        });

        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group);
        pass.draw(3, 1, 0, 0); // fullscreen triangle — no vertex buffer
        pass.end();
    }

    /// Returns the swapchain/surface width in pixels (matches wgpu texture dimensions).
    /// On Retina/HiDPI displays this is the physical pixel count, NOT logical pixels.
    pub fn getSurfaceWidth(self: *const GPU) u32 {
        return self.width;
    }

    /// Returns the swapchain/surface height in pixels.
    pub fn getSurfaceHeight(self: *const GPU) u32 {
        return self.height;
    }

    /// Web only: record the canvas size in pixels. The browser owns the canvas
    /// swapchain, so there is no surface to configure. Call this when the canvas
    /// size changes, before the frame that uses getSurfaceWidth/Height.
    pub fn setSurfaceSize(self: *GPU, width: u32, height: u32) void {
        if (comptime !is_wasm) @compileError("setSurfaceSize is for the web build only");
        self.width = width;
        self.height = height;
    }

    /// Give the surface a new size in pixels. Native: configure the wgpu
    /// surface again. Web: record the canvas size, as `setSurfaceSize`
    /// does. A zero size (a minimised window) and the same size do nothing.
    /// Call it between frames, not between `getCurrentTextureView` and
    /// `present`. The MSAA and FXAA targets keep their size: call
    /// `configureMSAA` or `configureFXAA` again (REQ-PLATFORM-003).
    pub fn resizeSurface(self: *GPU, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        if (width == self.width and height == self.height) return;
        if (comptime is_wasm) {
            self.width = width;
            self.height = height;
            return;
        } else {
            // Headless-offscreen mode has no surface: its texture keeps
            // its size.
            if (!self.isReady() or self.surface == null) return;
            const surface_config = surfaceConfiguration(self.device, width, height, self.vsync);
            native.wgpuSurfaceConfigure(self.surface, &surface_config);
            self.width = width;
            self.height = height;
        }
    }

    fn surfaceConfiguration(device: native.WGPUDevice, width: u32, height: u32, vsync: bool) native.WGPUSurfaceConfiguration {
        return .{
            .next_in_chain = null,
            .device = device,
            .format = .bgra8unorm,
            .usage = native.WGPUTextureUsage_RenderAttachment | native.WGPUTextureUsage_CopySrc,
            .view_format_count = 0,
            .view_formats = null,
            .alpha_mode = .auto,
            .width = width,
            .height = height,
            .present_mode = if (vsync) .fifo else .immediate,
        };
    }

    /// True when the device can write GPU timestamps (REQ-GPU-028).
    pub fn supportsTimestamps(self: *const GPU) bool {
        return self.timestamps;
    }

    /// Set vsync (REQ-GPU-027). On: the surface waits for the display
    /// refresh (`fifo`). Off: the surface shows each frame immediately
    /// (`immediate`), and a frame can tear. Native only: the browser
    /// always waits for the display refresh, so the web build keeps the
    /// value and does nothing more.
    pub fn setVsync(self: *GPU, on: bool) void {
        self.vsync = on;
        if (comptime is_wasm) return;
        if (!self.isReady() or self.surface == null) return;
        const config = surfaceConfiguration(self.device, self.width, self.height, on);
        native.wgpuSurfaceConfigure(self.surface, &config);
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
            self.width = width;
            self.height = height;
            self.state = .ready;
        } else {
            // Native: Initialize wgpu-native. `window == null` means "headless
            // offscreen mode": skip surface creation and render to an offscreen
            // bgra8unorm texture instead. Everything else (adapter, device,
            // queue, MSAA, FXAA) is identical to the windowed path.
            const headless_offscreen = (window == null);

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

            if (headless_offscreen) {
                std.log.info("sw_gpu: headless-offscreen GPU init ({}×{} bgra8unorm)", .{ width, height });
            } else {
                std.log.info("Instance created successfully", .{});
            }

            // Request adapter FIRST (without surface) to avoid backend detection issues
            var adapter_result = AdapterRequestResult{};
            var adapter_options = std.mem.zeroes(native.WGPURequestAdapterOptions);
            adapter_options.power_preference = .high_performance;
            native.wgpuInstanceRequestAdapter(
                instance,
                &adapter_options,
                adapterRequestCallback,
                &adapter_result,
            );

            // Wait for adapter (simple spin-wait for now)
            while (!adapter_result.received) {}
            if (adapter_result.adapter == null) return error.AdapterRequestFailed;

            // Create surface from SDL window (windowed mode only). Headless
            // offscreen mode leaves `self.surface = null` and renders to a
            // persistent offscreen texture instead.
            const surface: native.WGPUSurface = if (headless_offscreen)
                null
            else
                try native.createSurfaceFromSDLWindow(instance, window.?);

            // Request device (using callback)
            var device_result = DeviceRequestResult{};
            var device_desc = std.mem.zeroes(native.WGPUDeviceDescriptor);
            // Ask for the timestamp query feature when the adapter has it
            // (REQ-GPU-028). Without it, the device is the same.
            const timestamp_feature = [_]native.WGPUFeatureName{.timestamp_query};
            const timestamps = native.wgpuAdapterHasFeature(adapter_result.adapter.?, .timestamp_query) != 0;
            if (timestamps) {
                device_desc.required_features_count = 1;
                device_desc.required_features = &timestamp_feature;
            }
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

            if (!headless_offscreen) {
                // Configure surface (modern API, replaces swap chain)
                const surface_config = surfaceConfiguration(device_result.device.?, width, height, self.vsync);
                native.wgpuSurfaceConfigure(surface, &surface_config);
            }

            // Store everything
            self.instance = instance;
            self.adapter = adapter_result.adapter.?;
            self.surface = surface;
            self.device = device_result.device.?;
            self.queue = queue;
            self.width = width;
            self.height = height;
            self.timestamps = timestamps;
            self.state = .ready;

            // Offscreen "swapchain" texture (headless mode only). Must happen
            // AFTER self.state = .ready because createTexture gates on isReady.
            // Usage mirrors the real swapchain + TextureBinding so the FXAA
            // fullscreen pass can still sample it.
            if (headless_offscreen) {
                const tex = self.createTexture(.{
                    .label = "offscreen_swapchain",
                    .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
                    .format = .bgra8unorm,
                    .usage = .{
                        .render_attachment = true,
                        .copy_src = true,
                        .texture_binding = true,
                    },
                }) catch |err| {
                    std.log.err("sw_gpu: failed to create offscreen swapchain texture: {}", .{err});
                    return err;
                };
                self.offscreen_color_texture = tex;
            }
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
                @backingInt(desc.format),
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
                .dimension = @fromBackingInt(@intCast(@backingInt(desc.dimension))),
                .size = .{
                    .width = desc.size.width,
                    .height = desc.size.height,
                    .depth_or_array_layers = desc.size.depth_or_array_layers,
                },
                .format = toNativeTextureFormat(desc.format),
                .mip_level_count = desc.mip_level_count,
                .sample_count = desc.sample_count,
                .view_format_count = 0,
                .view_formats = null,
            };
            const handle = native.wgpuDeviceCreateTexture(self.device, &c_desc);
            return Texture{ .handle = handle orelse return error.TextureCreationFailed };
        }
    }

    /// Create a sampler for texture sampling.
    ///
    /// `max_anisotropy` above 1 gives anisotropic filtering. The GPU clamps
    /// the value to the most that it supports. WebGPU requires linear
    /// `mag_filter`, `min_filter` and `mipmap_filter` for anisotropy, so a
    /// sampler with a nearest filter and `max_anisotropy` above 1 gives
    /// `error.AnisotropyNeedsLinearFilters`.
    pub fn createSampler(self: *GPU, desc: SamplerDescriptor) !Sampler {
        if (!self.isReady()) return error.GPUNotReady;
        try desc.validate();

        if (comptime is_wasm) {
            // webgpu.ts numbers the address modes and compare functions in
            // its own order. Map each value by name, never by @backingInt.
            const handle = web.webgpuCreateSampler(
                self.device,
                webAddressMode(desc.address_mode_u),
                webAddressMode(desc.address_mode_v),
                webAddressMode(desc.address_mode_w),
                @backingInt(desc.mag_filter),
                @backingInt(desc.min_filter),
                @backingInt(desc.mipmap_filter),
                desc.lod_min_clamp,
                desc.lod_max_clamp,
                if (desc.compare) |c| webCompare(c) else 0,
                desc.max_anisotropy,
            );
            return Sampler{ .handle = handle };
        } else {
            // Named maps only: WGPUAddressMode starts with repeat=0, and
            // WGPUCompareFunction has undefined=0 and another order.
            var c_desc = std.mem.zeroes(native.WGPUSamplerDescriptor);
            c_desc.label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null;
            c_desc.address_mode_u = toNativeAddressMode(desc.address_mode_u);
            c_desc.address_mode_v = toNativeAddressMode(desc.address_mode_v);
            c_desc.address_mode_w = toNativeAddressMode(desc.address_mode_w);
            c_desc.mag_filter = toNativeFilterMode(desc.mag_filter);
            c_desc.min_filter = toNativeFilterMode(desc.min_filter);
            c_desc.mipmap_filter = switch (desc.mipmap_filter) {
                .nearest => .nearest,
                .linear => .linear,
            };
            c_desc.lod_min_clamp = desc.lod_min_clamp;
            c_desc.lod_max_clamp = desc.lod_max_clamp;
            c_desc.compare = if (desc.compare) |c| toNativeCompareFunction(c) else .undefined;
            c_desc.max_anisotropy = desc.max_anisotropy;
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
            const code_z = try allocator.dupeSentinel(u8, desc.code, 0);
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

            // Track all attributes allocations for deferred cleanup.
            // ArrayList: init with `.empty`, pass the allocator per call.
            var vertex_attributes_allocations: std.ArrayList([]web.VertexAttributeJS) = .empty;
            defer {
                for (vertex_attributes_allocations.items) |attrs| {
                    std.heap.page_allocator.free(attrs);
                }
                vertex_attributes_allocations.deinit(std.heap.page_allocator);
            }

            for (desc.vertex.buffers, 0..) |buffer_layout, i| {
                // Allocate and convert attributes
                var js_attrs = try std.heap.page_allocator.alloc(web.VertexAttributeJS, buffer_layout.attributes.len);
                try vertex_attributes_allocations.append(std.heap.page_allocator, js_attrs);

                for (buffer_layout.attributes, 0..) |attr, j| {
                    js_attrs[j] = .{
                        .format = @backingInt(attr.format),
                        .offset = attr.offset,
                        .shader_location = attr.shader_location,
                    };
                }

                js_vertex_buffers[i] = .{
                    .array_stride = buffer_layout.array_stride,
                    .step_mode = @backingInt(buffer_layout.step_mode),
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
                        .format = @backingInt(target.format),
                        .blend_enabled = @as(u32, if (target.blend != null) 1 else 0),
                        .color_operation = if (target.blend) |blend| @backingInt(blend.color.operation) else 0,
                        .color_src_factor = if (target.blend) |blend| @backingInt(blend.color.src_factor) else 0,
                        .color_dst_factor = if (target.blend) |blend| @backingInt(blend.color.dst_factor) else 0,
                        .alpha_operation = if (target.blend) |blend| @backingInt(blend.alpha.operation) else 0,
                        .alpha_src_factor = if (target.blend) |blend| @backingInt(blend.alpha.src_factor) else 0,
                        .alpha_dst_factor = if (target.blend) |blend| @backingInt(blend.alpha.dst_factor) else 0,
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
                @backingInt(desc.primitive.topology),
                if (desc.primitive.strip_index_format) |fmt| @backingInt(fmt) else 0,
                @backingInt(desc.primitive.front_face),
                @backingInt(desc.primitive.cull_mode),
                // Fragment stage
                if (desc.fragment) |frag| frag.module.handle else 0,
                if (desc.fragment) |frag| frag.entry_point.ptr else @as([*]const u8, undefined),
                if (desc.fragment) |frag| @as(u32, @intCast(frag.entry_point.len)) else 0,
                js_fragment_targets.ptr,
                @intCast(js_fragment_targets.len),
                // Depth/stencil
                if (desc.depth_stencil) |ds| @backingInt(ds.format) else 0,
                if (desc.depth_stencil) |ds| ds.depth_write_enabled else false,
                if (desc.depth_stencil) |ds| @backingInt(ds.depth_compare) else 0,
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
            var vertex_attributes_allocations: [8]?[]native.WGPUVertexAttribute = @splat(null);
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
                        .format = @fromBackingInt(@intCast(@backingInt(attr.format))),
                        .offset = attr.offset,
                        .shader_location = attr.shader_location,
                    };
                }

                wgpu_vertex_buffers[i] = .{
                    .array_stride = buffer_layout.array_stride,
                    .step_mode = @fromBackingInt(@intCast(@backingInt(buffer_layout.step_mode))),
                    .attribute_count = wgpu_attrs.len,
                    .attributes = wgpu_attrs.ptr,
                };
            }

            // Convert vertex shader entry point to null-terminated string
            const vertex_entry = try allocator.dupeSentinel(u8, desc.vertex.entry_point, 0);
            defer allocator.free(vertex_entry);

            // Build vertex state (zero-initialize to avoid undefined padding)
            var vertex_state = std.mem.zeroes(native.WGPUVertexState);
            vertex_state.module = desc.vertex.module.handle;
            vertex_state.entry_point = vertex_entry.ptr;
            vertex_state.buffer_count = wgpu_vertex_buffers.len;
            vertex_state.buffers = if (wgpu_vertex_buffers.len > 0) wgpu_vertex_buffers.ptr else null;

            // Build primitive state (zero-initialize to avoid undefined padding)
            var primitive_state = std.mem.zeroes(native.WGPUPrimitiveState);
            primitive_state.topology = @fromBackingInt(@intCast(@backingInt(desc.primitive.topology)));
            primitive_state.strip_index_format = if (desc.primitive.strip_index_format) |fmt| @fromBackingInt(@intCast(@backingInt(fmt))) else .undefined;
            primitive_state.front_face = @fromBackingInt(@intCast(@backingInt(desc.primitive.front_face)));
            primitive_state.cull_mode = @fromBackingInt(@intCast(@backingInt(desc.primitive.cull_mode)));

            // Build multisample state (zero-initialize to avoid undefined padding)
            var multisample_state = std.mem.zeroes(native.WGPUMultisampleState);
            multisample_state.count = desc.multisample.count;
            multisample_state.mask = desc.multisample.mask;
            multisample_state.alpha_to_coverage_enabled = if (desc.multisample.alpha_to_coverage_enabled) @as(u32, 1) else 0;

            // Convert fragment state if present
            var fragment_state_storage: native.WGPUFragmentState = undefined;
            var fragment_ptr: ?*const native.WGPUFragmentState = null;
            var fragment_entry: ?[:0]u8 = null;
            var wgpu_targets: ?[]native.WGPUColorTargetState = null;
            // Blend states live on the stack alongside targets (up to 8 color attachments)
            var wgpu_blend_states_storage: [8]native.WGPUBlendState = undefined;
            defer {
                if (fragment_entry) |fe| allocator.free(fe);
                if (wgpu_targets) |targets| allocator.free(targets);
            }

            if (desc.fragment) |fragment| {
                // Convert fragment entry point
                fragment_entry = try allocator.dupeSentinel(u8, fragment.entry_point, 0);

                // Convert color targets (zero-initialize to avoid undefined padding)
                var targets = try allocator.alloc(native.WGPUColorTargetState, fragment.targets.len);
                wgpu_targets = targets;

                for (fragment.targets, 0..) |target, i| {
                    targets[i] = std.mem.zeroes(native.WGPUColorTargetState);
                    targets[i].format = toNativeTextureFormat(target.format);
                    targets[i].write_mask = target.write_mask;
                    if (target.blend) |blend| {
                        wgpu_blend_states_storage[i] = .{
                            .color = .{
                                .operation = @fromBackingInt(@intCast(@backingInt(blend.color.operation))),
                                .src_factor = @fromBackingInt(@intCast(@backingInt(blend.color.src_factor))),
                                .dst_factor = @fromBackingInt(@intCast(@backingInt(blend.color.dst_factor))),
                            },
                            .alpha = .{
                                .operation = @fromBackingInt(@intCast(@backingInt(blend.alpha.operation))),
                                .src_factor = @fromBackingInt(@intCast(@backingInt(blend.alpha.src_factor))),
                                .dst_factor = @fromBackingInt(@intCast(@backingInt(blend.alpha.dst_factor))),
                            },
                        };
                        targets[i].blend = &wgpu_blend_states_storage[i];
                    }
                }

                // Zero-initialize fragment state to avoid undefined padding
                fragment_state_storage = std.mem.zeroes(native.WGPUFragmentState);
                fragment_state_storage.module = fragment.module.handle;
                fragment_state_storage.entry_point = fragment_entry.?.ptr;
                fragment_state_storage.target_count = targets.len;
                fragment_state_storage.targets = targets.ptr;
                fragment_ptr = &fragment_state_storage;
            }

            // Convert depth/stencil state if present
            var depth_stencil_state_storage: native.WGPUDepthStencilState = undefined;
            var depth_stencil_ptr: ?*const native.WGPUDepthStencilState = null;

            if (desc.depth_stencil) |depth_stencil| {
                // Zero-initialize depth stencil state to avoid undefined padding (CRITICAL!)
                depth_stencil_state_storage = std.mem.zeroes(native.WGPUDepthStencilState);
                depth_stencil_state_storage.format = toNativeTextureFormat(depth_stencil.format);
                depth_stencil_state_storage.depth_write_enabled = if (depth_stencil.depth_write_enabled) @as(u32, 1) else 0;
                depth_stencil_state_storage.depth_compare = toNativeCompareFunction(depth_stencil.depth_compare);

                // Stencil front state
                depth_stencil_state_storage.stencil_front.compare = toNativeCompareFunction(depth_stencil.stencil_front.compare);
                depth_stencil_state_storage.stencil_front.fail_op = @fromBackingInt(@intCast(@backingInt(depth_stencil.stencil_front.fail_op)));
                depth_stencil_state_storage.stencil_front.depth_fail_op = @fromBackingInt(@intCast(@backingInt(depth_stencil.stencil_front.depth_fail_op)));
                depth_stencil_state_storage.stencil_front.pass_op = @fromBackingInt(@intCast(@backingInt(depth_stencil.stencil_front.pass_op)));

                // Stencil back state
                depth_stencil_state_storage.stencil_back.compare = toNativeCompareFunction(depth_stencil.stencil_back.compare);
                depth_stencil_state_storage.stencil_back.fail_op = @fromBackingInt(@intCast(@backingInt(depth_stencil.stencil_back.fail_op)));
                depth_stencil_state_storage.stencil_back.depth_fail_op = @fromBackingInt(@intCast(@backingInt(depth_stencil.stencil_back.depth_fail_op)));
                depth_stencil_state_storage.stencil_back.pass_op = @fromBackingInt(@intCast(@backingInt(depth_stencil.stencil_back.pass_op)));

                // Remaining fields
                depth_stencil_state_storage.stencil_read_mask = depth_stencil.stencil_read_mask;
                depth_stencil_state_storage.stencil_write_mask = depth_stencil.stencil_write_mask;
                depth_stencil_state_storage.depth_bias = depth_stencil.depth_bias;
                depth_stencil_state_storage.depth_bias_slope_scale = depth_stencil.depth_bias_slope_scale;
                depth_stencil_state_storage.depth_bias_clamp = depth_stencil.depth_bias_clamp;

                depth_stencil_ptr = &depth_stencil_state_storage;
            }

            // Build pipeline descriptor (zero-initialize to avoid undefined padding)
            var pipeline_desc = std.mem.zeroes(native.WGPURenderPipelineDescriptor);
            pipeline_desc.layout = if (desc.layout) |layout| layout.handle else null;
            pipeline_desc.vertex = vertex_state;
            pipeline_desc.primitive = primitive_state;
            pipeline_desc.depth_stencil = depth_stencil_ptr;
            pipeline_desc.multisample = multisample_state;
            pipeline_desc.fragment = fragment_ptr;

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
                    .buffer_has_dynamic_offset = if (entry.buffer) |buf| @as(u32, if (buf.has_dynamic_offset) 1 else 0) else 0,
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
                    .texture_view_dimension = if (entry.texture) |tex| @backingInt(tex.view_dimension) else 0,
                    .texture_multisampled = if (entry.texture) |tex| @as(u32, if (tex.multisampled) 1 else 0) else 0,
                    .storage_access = if (entry.storage_texture) |st| @backingInt(st.access) + 1 else 0,
                    .storage_format = if (entry.storage_texture) |st| @backingInt(st.format) else 0,
                    .storage_view_dimension = if (entry.storage_texture) |st| @backingInt(st.view_dimension) else 0,
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

                native_entries[i] = std.mem.zeroes(native.WGPUBindGroupLayoutEntry);
                native_entries[i].binding = entry.binding;
                native_entries[i].visibility = visibility;
                if (entry.buffer) |buf| {
                    native_entries[i].buffer.type = switch (buf.type) {
                        .uniform => .uniform,
                        .storage => .storage,
                        .read_only_storage => .read_only_storage,
                    };
                    native_entries[i].buffer.has_dynamic_offset = if (buf.has_dynamic_offset) 1 else 0;
                    native_entries[i].buffer.min_binding_size = buf.min_binding_size;
                }
                if (entry.sampler) |samp| {
                    native_entries[i].sampler.type = switch (samp.type) {
                        .filtering => .filtering,
                        .non_filtering => .non_filtering,
                        .comparison => .comparison,
                    };
                }
                if (entry.texture) |tex| {
                    native_entries[i].texture.sample_type = switch (tex.sample_type) {
                        .float => .float,
                        .unfilterable_float => .unfilterable_float,
                        .depth => .depth,
                        .sint => .sint,
                        .uint => .uint,
                    };
                    // Explicit mapping: types.TextureViewDimension starts at 0 (no 'undefined'),
                    // but WGPUTextureViewDimension has undefined=0, 1d=1, 2d=2, etc.
                    // Raw @intFromEnum would map .@"2d"→1 (WGPUTextureViewDimension.1d) — wrong.
                    native_entries[i].texture.view_dimension = switch (tex.view_dimension) {
                        .@"1d" => .@"1d",
                        .@"2d" => .@"2d",
                        .@"2d-array" => .@"2d_array",
                        .cube => .cube,
                        .cube_array => .cube_array,
                        .@"3d" => .@"3d",
                    };
                    native_entries[i].texture.multisampled = if (tex.multisampled) @as(u32, 1) else 0;
                }
                if (entry.storage_texture) |st| {
                    native_entries[i].storage_texture.access = switch (st.access) {
                        .write_only => .write_only,
                        .read_only => .read_only,
                        .read_write => .read_write,
                    };
                    native_entries[i].storage_texture.format = toNativeTextureFormat(st.format);
                    native_entries[i].storage_texture.view_dimension = switch (st.view_dimension) {
                        .@"1d" => .@"1d",
                        .@"2d" => .@"2d",
                        .@"2d-array" => .@"2d_array",
                        .cube => .cube,
                        .cube_array => .cube_array,
                        .@"3d" => .@"3d",
                    };
                }
            }

            var native_desc = std.mem.zeroes(native.WGPUBindGroupLayoutDescriptor);
            native_desc.entry_count = native_entries.len;
            native_desc.entries = native_entries.ptr;

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
                    ._padding = 0,
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
                native_entries[i] = std.mem.zeroes(native.WGPUBindGroupEntry);
                native_entries[i].binding = entry.binding;
                native_entries[i].buffer = if (entry.buffer) |buf| buf.handle else null;
                native_entries[i].offset = entry.offset;
                native_entries[i].size = entry.size;
                native_entries[i].sampler = if (entry.sampler) |samp| samp.handle else null;
                native_entries[i].texture_view = if (entry.texture_view) |view| view.handle else null;
            }

            var native_desc = std.mem.zeroes(native.WGPUBindGroupDescriptor);
            native_desc.layout = desc.layout.handle;
            native_desc.entry_count = native_entries.len;
            native_desc.entries = native_entries.ptr;

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

            var native_desc = std.mem.zeroes(native.WGPUPipelineLayoutDescriptor);
            native_desc.bind_group_layout_count = native_layouts.len;
            native_desc.bind_group_layouts = native_layouts.ptr;

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
            // Headless-offscreen mode: no surface. Return a fresh view of the
            // persistent offscreen colour texture. Caller is expected to
            // .release() it each frame (same contract as the windowed path);
            // the underlying texture lives until GPU shutdown.
            if (self.surface == null) {
                const off_tex = self.offscreen_color_texture orelse return error.OffscreenTextureNotAllocated;
                self.current_surface_texture = off_tex.handle;
                const view = native.wgpuTextureCreateView(off_tex.handle, null);
                if (view == null) return error.TextureViewCreationFailed;
                return TextureView{ .handle = view };
            }

            // Native: Get current texture from surface
            var surface_texture: native.WGPUSurfaceTexture = undefined;
            native.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);

            // Check if we got a valid texture
            if (surface_texture.status != .success) {
                return error.SurfaceTextureError;
            }

            // Cache the texture handle so captureFrame() can reuse it without
            // calling wgpuSurfaceGetCurrentTexture() again (invalid within a frame).
            self.current_surface_texture = surface_texture.texture;

            // Create a texture view
            const view = native.wgpuTextureCreateView(surface_texture.texture, null);
            if (view == null) return error.TextureViewCreationFailed;

            return TextureView{ .handle = view };
        }
    }

    /// Capture the current surface texture to a raw BGRA byte buffer.
    ///
    /// Call AFTER submit() and BEFORE present().  The surface must have been
    /// configured with CopySrc usage (done automatically since this was added).
    /// The caller owns the returned slice and must free it with `allocator.free`.
    ///
    /// Returns width × height × 4 bytes in BGRA order (the native swapchain format).
    pub fn captureFrame(self: *GPU, allocator: std.mem.Allocator) ![]u8 {
        if (comptime is_wasm) return error.NotSupportedOnWasm;

        // Headless-offscreen mode reads directly from the persistent offscreen
        // texture — there is no swapchain acquisition. Windowed mode reuses
        // the texture that getCurrentTextureView() already fetched this frame
        // (calling wgpuSurfaceGetCurrentTexture twice within a frame is a
        // validation error on Metal).
        const tex: native.WGPUTexture = blk: {
            if (self.surface == null) {
                const off = self.offscreen_color_texture orelse return error.OffscreenTextureNotAllocated;
                break :blk off.handle;
            }
            break :blk self.current_surface_texture orelse return error.NoCurrentTexture;
        };

        const w = self.width;
        const h = self.height;

        // wgpu requires bytes_per_row to be aligned to 256
        const bpp: u32 = 4;
        const bytes_per_row = (w * bpp + 255) & ~@as(u32, 255);
        const buf_size: u64 = @as(u64, bytes_per_row) * h;

        // Create a CPU-readable staging buffer
        var buf_desc = std.mem.zeroes(native.WGPUBufferDescriptor);
        buf_desc.size = buf_size;
        buf_desc.usage = native.WGPUBufferUsage_CopyDst | native.WGPUBufferUsage_MapRead;
        buf_desc.mapped_at_creation = 0;
        const staging_buf = native.wgpuDeviceCreateBuffer(self.device, &buf_desc) orelse return error.BufferCreationFailed;
        defer native.wgpuBufferDestroy(staging_buf);

        // Record the copy command
        const enc = native.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return error.EncoderCreationFailed;

        var src = std.mem.zeroes(native.WGPUImageCopyTexture);
        src.texture = tex;
        src.mip_level = 0;
        src.aspect = .all; // .all captures the colour plane for colour textures

        var dst = std.mem.zeroes(native.WGPUImageCopyBuffer);
        dst.buffer = staging_buf;
        dst.layout.bytes_per_row = bytes_per_row;
        dst.layout.rows_per_image = h;

        const extent = native.WGPUExtent3D{ .width = w, .height = h, .depth_or_array_layers = 1 };
        native.wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &extent);

        const cmd = native.wgpuCommandEncoderFinish(enc, null) orelse return error.FinishFailed;
        native.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        native.wgpuCommandBufferRelease(cmd);
        native.wgpuCommandEncoderRelease(enc);

        // Map buffer and wait synchronously
        const MapWait = struct { done: bool = false };
        var map_state = MapWait{};
        native.wgpuBufferMapAsync(
            staging_buf,
            native.WGPUMapMode_Read,
            0,
            buf_size,
            struct {
                fn cb(status: u32, ud: ?*anyopaque) callconv(.c) void {
                    _ = status;
                    @as(*MapWait, @ptrCast(@alignCast(ud))).done = true;
                }
            }.cb,
            &map_state,
        );
        _ = native.wgpuDevicePoll(self.device, 1, null);

        // Copy pixels into output buffer, stripping the 256-byte row padding
        const out = try allocator.alloc(u8, w * h * bpp);
        const ptr: [*]const u8 = @ptrCast(native.wgpuBufferGetMappedRange(staging_buf, 0, buf_size) orelse {
            allocator.free(out);
            return error.MapFailed;
        });
        for (0..h) |y| {
            const src_row = ptr[y * bytes_per_row ..][0 .. w * bpp];
            @memcpy(out[y * w * bpp ..][0 .. w * bpp], src_row);
        }
        native.wgpuBufferUnmap(staging_buf);
        return out;
    }

    /// Make a query set of `count` timestamp queries (REQ-GPU-028). It
    /// gives `error.TimestampsNotSupported` when the device has no
    /// timestamp feature. The web build has no timestamps.
    pub fn createTimestampQuerySet(self: *GPU, count: u32) !QuerySet {
        return self.createQuerySet(.{ .type = .timestamp, .count = count });
    }

    /// Make a query set of `desc.count` queries (REQ-GPU-035). Occlusion
    /// queries work on native and on the web. Timestamp queries need the
    /// device feature: else `error.TimestampsNotSupported`, and always on
    /// the web. The type goes through a named map (`types.nativeQueryType`,
    /// `types.webQueryTypeCode`), never through its Zig number.
    pub fn createQuerySet(self: *GPU, desc: types.QuerySetDescriptor) !QuerySet {
        if (!self.isReady()) return error.GPUNotReady;
        if (desc.count == 0 or desc.count > MAX_QUERIES) return error.BadQueryCount;
        if (desc.type == .timestamp and (is_wasm or !self.timestamps)) return error.TimestampsNotSupported;
        if (comptime is_wasm) {
            const handle = web.webgpuCreateQuerySet(self.device, types.webQueryTypeCode(desc.type), desc.count);
            if (handle == 0) return error.QuerySetCreationFailed;
            return .{ .handle = handle, .count = desc.count, .type = desc.type };
        } else {
            var c_desc = std.mem.zeroes(native.WGPUQuerySetDescriptor);
            c_desc.type = @fromBackingInt(types.nativeQueryType(desc.type));
            c_desc.count = desc.count;
            const handle = native.wgpuDeviceCreateQuerySet(self.device, &c_desc) orelse return error.QuerySetCreationFailed;
            return .{ .handle = handle, .count = desc.count, .type = desc.type };
        }
    }

    /// The most queries in one query set (the WebGPU limit).
    pub const MAX_QUERIES: u32 = 4096;

    /// Copy `out.len` bytes at `offset` of `buffer` to `out` (REQ-GPU-028).
    /// The buffer must have `map_read` usage. The call waits for the GPU
    /// to complete all submitted work, so use it for debug data, not each
    /// frame of a game. Native only.
    pub fn readBuffer(self: *GPU, buffer: Buffer, offset: u64, out: []u8) !void {
        if (comptime is_wasm) return error.NotSupportedOnWasm;
        if (out.len == 0) return;
        const MapWait = struct { done: bool = false, status: u32 = 0 };
        var map_state = MapWait{};
        native.wgpuBufferMapAsync(
            buffer.handle,
            native.WGPUMapMode_Read,
            @intCast(offset),
            out.len,
            struct {
                fn cb(status: u32, ud: ?*anyopaque) callconv(.c) void {
                    const st: *MapWait = @ptrCast(@alignCast(ud));
                    st.status = status;
                    st.done = true;
                }
            }.cb,
            &map_state,
        );
        _ = native.wgpuDevicePoll(self.device, 1, null);
        if (!map_state.done or map_state.status != 0) return error.MapFailed;
        defer native.wgpuBufferUnmap(buffer.handle);
        const ptr: [*]const u8 = @ptrCast(native.wgpuBufferGetMappedRange(buffer.handle, @intCast(offset), out.len) orelse return error.MapFailed);
        @memcpy(out, ptr[0..out.len]);
    }

    /// Wait until the GPU completes all submitted work, and run the native
    /// callbacks of the completed maps (REQ-GPU-038). The web cannot wait:
    /// there it does nothing. Use it at shutdown, not in each frame.
    pub fn waitIdle(self: *GPU) void {
        if (comptime is_wasm) return;
        if (!self.isReady()) return;
        _ = native.wgpuDevicePoll(self.device, 1, null);
    }

    /// Present the current frame to screen
    pub fn present(self: *GPU) void {
        if (!self.isReady()) return;

        if (comptime is_wasm) {
            web.webgpuPresent();
        } else {
            // Headless-offscreen mode has no swapchain to present to. submit()
            // limits the frames in flight, so there is nothing to wait for
            // here. Just clear the cached surface texture so the next
            // getCurrentTextureView() allocates a fresh view.
            if (self.surface == null) {
                self.current_surface_texture = null;
                return;
            }
            // Native: Present the surface
            native.wgpuSurfacePresent(self.surface);
            self.current_surface_texture = null;
        }
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
            const index = native.wgpuQueueSubmitForIndex(self.queue, count, &c_buffers);

            // wgpu keeps a submitted command buffer alive until the GPU is
            // done with it, so release our reference now.
            for (command_buffers[0..count]) |buf| {
                native.wgpuCommandBufferRelease(buf.handle);
            }

            // The CPU does not wait for this submit. It waits for the submit
            // MAX_FRAMES_IN_FLIGHT back, so the CPU makes the next frame while
            // the GPU draws this one, and cannot get further ahead. A
            // non-blocking poll frees the work that the GPU completed.
            const slot: usize = @intCast(self.submit_count % MAX_FRAMES_IN_FLIGHT);
            if (self.in_flight[slot]) |oldest| {
                const wrapped = native.WGPUWrappedSubmissionIndex{ .queue = self.queue, .submission_index = oldest };
                _ = native.wgpuDevicePoll(self.device, 1, @ptrCast(&wrapped));
            } else {
                _ = native.wgpuDevicePoll(self.device, 0, null);
            }
            self.in_flight[slot] = index;
            self.submit_count += 1;
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

    /// Write `size` bytes that the JS host holds to `buffer` at `offset`.
    /// `held` is the handle of the bytes in the host store
    /// (backends/wasm/held-bytes.ts), and `held_offset` is the first byte.
    /// JS calls `queue.writeBuffer` with the ArrayBuffer, so the bytes never
    /// go through the wasm memory. The voxel demo uses it for the meshes
    /// that Web Workers send (C5). Web only: a native build has no
    /// host-held bytes, and stops with a panic.
    pub fn writeBufferHeld(self: *GPU, buffer: Buffer, offset: u64, held: u32, held_offset: u32, size: u64) void {
        if (!self.isReady()) return;
        if (comptime is_wasm) {
            web.webgpuWriteBufferHeld(self.queue, buffer.handle, offset, held, held_offset, size);
        } else {
            @panic("writeBufferHeld: a native build has no host-held bytes");
        }
    }

    /// Write data to mip level 0 of a texture, from origin (0, 0, 0).
    pub fn writeTexture(
        self: *GPU,
        texture: Texture,
        data: []const u8,
        bytes_per_row: u32,
        rows_per_image: u32,
        size: Extent3D,
    ) void {
        self.writeTextureRegion(texture, data, .{
            .size = size,
            .bytes_per_row = bytes_per_row,
            .rows_per_image = rows_per_image,
        });
    }

    /// Write data to one region of a texture: a mip level, an origin and a
    /// size. For a 2D texture array, `origin.z` is the first array layer and
    /// `size.depth_or_array_layers` is the number of layers.
    pub fn writeTextureRegion(self: *GPU, texture: Texture, data: []const u8, region: TextureRegion) void {
        if (!self.isReady()) return;

        if (comptime is_wasm) {
            web.webgpuWriteTexture(
                self.queue,
                texture.handle,
                region.mip_level,
                region.origin.x,
                region.origin.y,
                region.origin.z,
                region.size.width,
                region.size.height,
                region.size.depth_or_array_layers,
                data.ptr,
                data.len,
                region.bytes_per_row,
                region.rows_per_image,
            );
        } else {
            var copy_texture = std.mem.zeroes(native.WGPUImageCopyTexture);
            copy_texture.texture = texture.handle;
            copy_texture.mip_level = region.mip_level;
            copy_texture.origin = .{ .x = region.origin.x, .y = region.origin.y, .z = region.origin.z };
            copy_texture.aspect = .all;
            var data_layout = std.mem.zeroes(native.WGPUTextureDataLayout);
            data_layout.bytes_per_row = region.bytes_per_row;
            data_layout.rows_per_image = region.rows_per_image;
            const write_size = native.WGPUExtent3D{
                .width = region.size.width,
                .height = region.size.height,
                .depth_or_array_layers = region.size.depth_or_array_layers,
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

    /// Native only: copy one mip level of one array layer of a texture to
    /// the CPU, and wait for the copy. The texture needs `copy_src` usage
    /// and a format with 4 bytes for each texel. The caller owns the result
    /// (`width * height * 4` bytes, rows top to bottom, no row padding).
    /// `width` and `height` are the size of that mip level. Use this for
    /// tests and tools, not for each frame.
    pub fn readTexture(
        self: *GPU,
        allocator: std.mem.Allocator,
        texture: Texture,
        mip_level: u32,
        array_layer: u32,
        width: u32,
        height: u32,
    ) ![]u8 {
        if (comptime is_wasm) return error.NotSupportedOnWasm;
        if (!self.isReady()) return error.GPUNotReady;

        const bpp: u32 = 4;
        // wgpu requires bytes_per_row to be a multiple of 256.
        const bytes_per_row = (width * bpp + 255) & ~@as(u32, 255);
        const buf_size: u64 = @as(u64, bytes_per_row) * height;

        var buf_desc = std.mem.zeroes(native.WGPUBufferDescriptor);
        buf_desc.size = buf_size;
        buf_desc.usage = native.WGPUBufferUsage_CopyDst | native.WGPUBufferUsage_MapRead;
        const staging_buf = native.wgpuDeviceCreateBuffer(self.device, &buf_desc) orelse return error.BufferCreationFailed;
        defer native.wgpuBufferDestroy(staging_buf);

        const enc = native.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return error.EncoderCreationFailed;
        var src = std.mem.zeroes(native.WGPUImageCopyTexture);
        src.texture = texture.handle;
        src.mip_level = mip_level;
        src.origin = .{ .x = 0, .y = 0, .z = array_layer };
        src.aspect = .all;
        var dst = std.mem.zeroes(native.WGPUImageCopyBuffer);
        dst.buffer = staging_buf;
        dst.layout.bytes_per_row = bytes_per_row;
        dst.layout.rows_per_image = height;
        const extent = native.WGPUExtent3D{ .width = width, .height = height, .depth_or_array_layers = 1 };
        native.wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &extent);
        const cmd = native.wgpuCommandEncoderFinish(enc, null) orelse return error.FinishFailed;
        native.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        native.wgpuCommandBufferRelease(cmd);
        native.wgpuCommandEncoderRelease(enc);

        const MapWait = struct { done: bool = false };
        var map_state = MapWait{};
        native.wgpuBufferMapAsync(
            staging_buf,
            native.WGPUMapMode_Read,
            0,
            buf_size,
            struct {
                fn cb(status: u32, ud: ?*anyopaque) callconv(.c) void {
                    _ = status;
                    @as(*MapWait, @ptrCast(@alignCast(ud))).done = true;
                }
            }.cb,
            &map_state,
        );
        while (!map_state.done) _ = native.wgpuDevicePoll(self.device, 1, null);

        const out = try allocator.alloc(u8, width * height * bpp);
        const ptr: [*]const u8 = @ptrCast(native.wgpuBufferGetMappedRange(staging_buf, 0, buf_size) orelse {
            allocator.free(out);
            return error.MapFailed;
        });
        for (0..height) |y| {
            const src_row = ptr[y * bytes_per_row ..][0 .. width * bpp];
            @memcpy(out[y * width * bpp ..][0 .. width * bpp], src_row);
        }
        native.wgpuBufferUnmap(staging_buf);
        return out;
    }
};

// =============================================================================
// Resource Handle Types
// =============================================================================
// These wrap the platform-specific handles

/// The address mode number of webgpu.ts (createSampler).
fn webAddressMode(mode: types.AddressMode) u32 {
    return switch (mode) {
        .repeat => 0,
        .mirror_repeat => 1,
        .clamp_to_edge => 2,
    };
}

/// The compare function number of webgpu.ts (createSampler). 0 is none.
fn webCompare(c: types.CompareFunction) u32 {
    return switch (c) {
        .never => 1,
        .less => 2,
        .less_equal => 3,
        .greater => 4,
        .greater_equal => 5,
        .equal => 6,
        .not_equal => 7,
        .always => 8,
    };
}

/// The native `WGPUTextureFormat` of `format`. The numbers of
/// `types.TextureFormat` differ from webgpu.h for some formats (for
/// example `rgba16float`), so do not use a raw `@intFromEnum`.
fn toNativeTextureFormat(format: types.TextureFormat) native.WGPUTextureFormat {
    return @fromBackingInt(types.nativeTextureFormat(format));
}

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
                if (desc.format) |f| @backingInt(f) else 0,
                viewDimensionCode(desc.dimension),
                @backingInt(desc.aspect),
                desc.base_mip_level,
                desc.mip_level_count orelse 0xFFFFFFFF,
                desc.base_array_layer,
                desc.array_layer_count orelse 0xFFFFFFFF,
            );
            return TextureView{ .handle = handle };
        } else {
            const c_desc = native.WGPUTextureViewDescriptor{
                .next_in_chain = null,
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
                .format = if (desc.format) |f| toNativeTextureFormat(f) else .undefined,
                .dimension = @fromBackingInt(viewDimensionCode(desc.dimension)),
                .base_mip_level = desc.base_mip_level,
                .mip_level_count = desc.mip_level_count orelse 0xFFFFFFFF,
                .base_array_layer = desc.base_array_layer,
                .array_layer_count = desc.array_layer_count orelse 0xFFFFFFFF,
                .aspect = @fromBackingInt(@intCast(@backingInt(desc.aspect))),
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

    /// Release the view. A view of the window surface is good for one
    /// frame only: release it after the submit (REQ-GPU-012).
    pub fn release(self: TextureView) void {
        if (comptime is_wasm) {
            // A view has no destroy in WebGPU. The bridge drops its handle,
            // so the browser can collect the view and its canvas texture.
            web.webgpuTextureViewRelease(self.handle);
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

    /// Drop this reference. The GPU keeps the bind group alive while a
    /// submitted command still uses it.
    pub fn release(self: BindGroup) void {
        if (comptime is_wasm) {
            web.webgpuBindGroupRelease(self.handle);
        } else {
            native.wgpuBindGroupRelease(self.handle);
        }
    }
};

pub const PipelineLayout = struct {
    handle: if (is_wasm) web.WebGPUPipelineLayout else native.WGPUPipelineLayout,
};

/// A set of GPU queries: timestamps (REQ-GPU-028) or occlusion
/// (REQ-GPU-035). Make it with `GPU.createQuerySet` or
/// `GPU.createTimestampQuerySet`.
pub const QuerySet = struct {
    handle: if (is_wasm) web.WebGPUQuerySet else native.WGPUQuerySet,
    count: u32,
    type: types.QueryType = .timestamp,

    pub fn destroy(self: QuerySet) void {
        if (comptime is_wasm) {
            web.webgpuQuerySetDestroy(self.handle);
            return;
        }
        native.wgpuQuerySetDestroy(self.handle);
        native.wgpuQuerySetRelease(self.handle);
    }
};

/// The state of a `BufferRead` (REQ-GPU-038).
pub const MapState = enum {
    /// No map: `start` can start one.
    idle,
    /// The GPU has not given the bytes yet.
    pending,
    /// `read` can copy the bytes. Then call `finish`.
    mapped,
    /// The map failed. `finish` makes the read idle again.
    failed,
};

/// A read of a GPU buffer that does not wait for the GPU (REQ-GPU-038).
/// The buffer needs `map_read` and `copy_dst` usage. Call `start` after
/// the submit that writes the buffer, then `poll` once per frame until it
/// gives `.mapped`. Then `read` the bytes and `finish`. Native: the map
/// callback writes to this struct, so do not move it while a map is
/// pending.
pub const BufferRead = struct {
    buffer: Buffer,
    offset: u64 = 0,
    size: u64,
    state: MapState = .idle,

    /// Start the map. The read must be idle.
    pub fn start(self: *BufferRead, gpu: *GPU) void {
        std.debug.assert(self.state == .idle);
        if (!gpu.isReady()) {
            self.state = .failed;
            return;
        }
        self.state = .pending;
        if (comptime is_wasm) {
            web.webgpuBufferMapReadAsync(self.buffer.handle, self.offset, self.size);
        } else {
            native.wgpuBufferMapAsync(self.buffer.handle, native.WGPUMapMode_Read, @intCast(self.offset), @intCast(self.size), mapCallback, self);
        }
    }

    fn mapCallback(status: u32, ud: ?*anyopaque) callconv(.c) void {
        const self: *BufferRead = @ptrCast(@alignCast(ud));
        // WGPUBufferMapAsyncStatus_Success is 0.
        self.state = if (status == 0) .mapped else .failed;
    }

    /// The state of the map. It does not wait: native polls the device
    /// once with no wait, and the web reads the state of the promise.
    pub fn poll(self: *BufferRead, gpu: *GPU) MapState {
        if (self.state != .pending) return self.state;
        if (comptime is_wasm) {
            self.state = switch (web.webgpuBufferMapState(self.buffer.handle)) {
                1 => .pending,
                2 => .mapped,
                else => .failed,
            };
        } else {
            _ = native.wgpuDevicePoll(gpu.device, 0, null);
        }
        return self.state;
    }

    /// Copy `out.len` bytes from the start of the mapped range to `out`.
    pub fn read(self: *BufferRead, out: []u8) !void {
        if (self.state != .mapped) return error.NotMapped;
        if (out.len > self.size) return error.ReadTooLong;
        if (out.len == 0) return;
        if (comptime is_wasm) {
            web.webgpuBufferReadMapped(self.buffer.handle, self.offset, out.len, out.ptr);
        } else {
            const ptr: [*]const u8 = @ptrCast(native.wgpuBufferGetMappedRange(self.buffer.handle, @intCast(self.offset), @intCast(self.size)) orelse return error.MapFailed);
            @memcpy(out, ptr[0..out.len]);
        }
    }

    /// Unmap the buffer. The read is idle again.
    pub fn finish(self: *BufferRead) void {
        if (self.state == .mapped) {
            if (comptime is_wasm) web.webgpuBufferUnmap(self.buffer.handle) else native.wgpuBufferUnmap(self.buffer.handle);
        }
        self.state = .idle;
    }
};

/// The timestamps that a render pass writes at its start and its end
/// (REQ-GPU-028).
pub const RenderPassTimestampWrites = struct {
    query_set: QuerySet,
    begin_index: u32,
    end_index: u32,
};

pub const CommandEncoder = struct {
    handle: if (is_wasm) web.WebGPUCommandEncoder else native.WGPUCommandEncoder,

    /// Record a copy of `count` query results, from query `first`, to
    /// `destination` at `offset`, as one u64 each (REQ-GPU-028,
    /// REQ-GPU-037). The buffer needs `query_resolve` usage. `offset` must
    /// be a multiple of 256. Native and web.
    pub fn resolveQuerySet(self: CommandEncoder, query_set: QuerySet, first: u32, count: u32, destination: Buffer, offset: u64) void {
        if (comptime is_wasm) {
            web.webgpuCommandEncoderResolveQuerySet(self.handle, query_set.handle, first, count, destination.handle, offset);
            return;
        }
        native.wgpuCommandEncoderResolveQuerySet(self.handle, query_set.handle, first, count, destination.handle, offset);
    }

    /// Record a copy of `size` bytes from `source` to `destination`.
    /// `source` needs `copy_src` usage and `destination` needs `copy_dst`
    /// usage. The offsets and the size are multiples of 4. Native and web
    /// (REQ-GPU-037).
    pub fn copyBufferToBuffer(self: CommandEncoder, source: Buffer, source_offset: u64, destination: Buffer, destination_offset: u64, size: u64) void {
        if (comptime is_wasm) {
            web.webgpuCommandEncoderCopyBufferToBuffer(self.handle, source.handle, source_offset, destination.handle, destination_offset, size);
            return;
        }
        native.wgpuCommandEncoderCopyBufferToBuffer(self.handle, source.handle, source_offset, destination.handle, destination_offset, size);
    }

    /// Begin a render pass for drawing
    pub fn beginRenderPass(self: CommandEncoder, desc: RenderPassDescriptor) !RenderPassEncoder {
        if (comptime is_wasm) {
            // Convert descriptor to JS format
            var color_attachments: [8]web.RenderPassColorAttachmentJS = undefined;
            for (desc.color_attachments, 0..) |att, i| {
                color_attachments[i] = .{
                    .view = att.view.handle,
                    .resolve_target = if (att.resolve_target) |rt| rt.handle else 0,
                    .load_op = @backingInt(att.load_op),
                    .store_op = @backingInt(att.store_op),
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
                if (desc.depth_stencil_attachment) |ds| @backingInt(ds.depth_load_op) else 0,
                if (desc.depth_stencil_attachment) |ds| @backingInt(ds.depth_store_op) else 0,
                if (desc.depth_stencil_attachment) |ds| ds.depth_clear_value else 0,
                // 0 maps to no stencil op in webgpu.ts. stencil_read_only must
                // give no ops, the same as the native path: a depth-only
                // format (depth24plus) rejects any stencil op.
                if (desc.depth_stencil_attachment) |ds| (if (ds.stencil_read_only) 0 else @backingInt(ds.stencil_load_op)) else 0,
                if (desc.depth_stencil_attachment) |ds| (if (ds.stencil_read_only) 0 else @backingInt(ds.stencil_store_op)) else 0,
                if (desc.depth_stencil_attachment) |ds| ds.stencil_clear_value else 0,
                if (desc.occlusion_query_set) |q| q.handle else 0,
            );
            return RenderPassEncoder{ .handle = handle };
        } else {
            // Convert descriptor to C format
            var color_attachments: [8]native.WGPURenderPassColorAttachment = std.mem.zeroes([8]native.WGPURenderPassColorAttachment);
            for (desc.color_attachments, 0..) |att, i| {
                // Initialize each field explicitly
                color_attachments[i].next_in_chain = null;
                color_attachments[i].view = att.view.handle;
                color_attachments[i].depth_slice = 0xFFFFFFFF; // WGPU_DEPTH_SLICE_UNDEFINED
                color_attachments[i].resolve_target = if (att.resolve_target) |rt| rt.handle else null;
                color_attachments[i].load_op = @fromBackingInt(@intCast(@backingInt(att.load_op)));
                color_attachments[i].store_op = @fromBackingInt(@intCast(@backingInt(att.store_op)));
                color_attachments[i].clear_value.r = att.clear_value.r;
                color_attachments[i].clear_value.g = att.clear_value.g;
                color_attachments[i].clear_value.b = att.clear_value.b;
                color_attachments[i].clear_value.a = att.clear_value.a;
            }

            var depth_stencil: ?native.WGPURenderPassDepthStencilAttachment = null;
            if (desc.depth_stencil_attachment) |ds| {
                // When `stencil_read_only` is set, the caller signals this is a
                // depth-only format (e.g. depth24plus has no stencil component on most
                // backends). wgpu-native v22 requires stencil ops to be `.undefined` (0)
                // for depth-only textures; any other value triggers a validation error.
                // The Zig `LoadOp`/`StoreOp` enums start at 1 (no undefined variant),
                // so we special-case here instead of polluting the public enum.
                const stencil_load: native.WGPULoadOp = if (ds.stencil_read_only) .undefined else @fromBackingInt(@intCast(@backingInt(ds.stencil_load_op)));
                const stencil_store: native.WGPUStoreOp = if (ds.stencil_read_only) .undefined else @fromBackingInt(@intCast(@backingInt(ds.stencil_store_op)));
                depth_stencil = .{
                    .view = ds.view.handle,
                    .depth_load_op = @fromBackingInt(@intCast(@backingInt(ds.depth_load_op))),
                    .depth_store_op = @fromBackingInt(@intCast(@backingInt(ds.depth_store_op))),
                    .depth_clear_value = ds.depth_clear_value,
                    .depth_read_only = if (ds.depth_read_only) @as(u32, 1) else 0,
                    .stencil_load_op = stencil_load,
                    .stencil_store_op = stencil_store,
                    .stencil_clear_value = if (ds.stencil_read_only) 0 else ds.stencil_clear_value,
                    .stencil_read_only = if (ds.stencil_read_only) @as(u32, 1) else 0,
                };
            }

            const timestamp_writes: ?native.WGPURenderPassTimestampWrites = if (desc.timestamp_writes) |t| .{
                .query_set = t.query_set.handle,
                .beginning_of_pass_write_index = t.begin_index,
                .end_of_pass_write_index = t.end_index,
            } else null;
            const c_desc = native.WGPURenderPassDescriptor{
                .next_in_chain = null,
                .label = if (desc.label) |l| @as(?[*:0]const u8, @ptrCast(l.ptr)) else null,
                .color_attachment_count = desc.color_attachments.len,
                .color_attachments = &color_attachments,
                .depth_stencil_attachment = if (depth_stencil) |*ds| ds else null,
                .occlusion_query_set = if (desc.occlusion_query_set) |q| q.handle else null,
                .timestamp_writes = if (timestamp_writes) |*t| t else null,
            };

            const handle = native.wgpuCommandEncoderBeginRenderPass(self.handle, &c_desc);
            return RenderPassEncoder{ .handle = handle orelse return error.RenderPassCreationFailed };
        }
    }

    /// Record a copy of a region of `src` to `dst` on the GPU (REQ-GPU-003).
    /// The two textures must have the same format. `src` needs `copy_src`
    /// usage and `dst` needs `copy_dst` usage. For a 2D texture array,
    /// `origin.z` is the first array layer and `size.depth_or_array_layers`
    /// is the number of layers. No data goes through the CPU.
    pub fn copyTextureToTexture(self: CommandEncoder, src: TextureCopy, dst: TextureCopy, size: Extent3D) void {
        if (comptime is_wasm) {
            web.webgpuCommandEncoderCopyTextureToTexture(
                self.handle,
                src.texture.handle,
                src.mip_level,
                src.origin.x,
                src.origin.y,
                src.origin.z,
                dst.texture.handle,
                dst.mip_level,
                dst.origin.x,
                dst.origin.y,
                dst.origin.z,
                size.width,
                size.height,
                size.depth_or_array_layers,
            );
        } else {
            var c_src = std.mem.zeroes(native.WGPUImageCopyTexture);
            c_src.texture = src.texture.handle;
            c_src.mip_level = src.mip_level;
            c_src.origin = .{ .x = src.origin.x, .y = src.origin.y, .z = src.origin.z };
            c_src.aspect = .all;
            var c_dst = std.mem.zeroes(native.WGPUImageCopyTexture);
            c_dst.texture = dst.texture.handle;
            c_dst.mip_level = dst.mip_level;
            c_dst.origin = .{ .x = dst.origin.x, .y = dst.origin.y, .z = dst.origin.z };
            c_dst.aspect = .all;
            const extent = native.WGPUExtent3D{
                .width = size.width,
                .height = size.height,
                .depth_or_array_layers = size.depth_or_array_layers,
            };
            native.wgpuCommandEncoderCopyTextureToTexture(self.handle, &c_src, &c_dst, &extent);
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
            // Can't pass null for a `[*]const u32` parameter — the web bridge
            // signature expects a non-optional pointer even when count=0. Use
            // a dummy non-null pointer; the JS side reads zero bytes.
            const dummy: [*]const u32 = &[_]u32{};
            web.webgpuRenderPassSetBindGroup(self.handle, index, bind_group.handle, dummy, 0);
        } else {
            native.wgpuRenderPassEncoderSetBindGroup(self.handle, index, bind_group.handle, 0, null);
        }
    }

    /// Set a bind group that has dynamic offsets. Give one offset for each
    /// binding with `has_dynamic_offset`, in binding order. Each offset is a
    /// multiple of 256 (`minUniformBufferOffsetAlignment`).
    pub fn setBindGroupWithOffsets(self: RenderPassEncoder, index: u32, bind_group: BindGroup, offsets: []const u32) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassSetBindGroup(self.handle, index, bind_group.handle, offsets.ptr, @intCast(offsets.len));
        } else {
            native.wgpuRenderPassEncoderSetBindGroup(self.handle, index, bind_group.handle, offsets.len, if (offsets.len == 0) null else offsets.ptr);
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
            web.webgpuRenderPassSetIndexBuffer(self.handle, buffer.handle, @backingInt(format), offset, size);
        } else {
            const native_format: native.WGPUIndexFormat = switch (format) {
                .uint16 => .uint16,
                .uint32 => .uint32,
            };
            native.wgpuRenderPassEncoderSetIndexBuffer(self.handle, buffer.handle, native_format, offset, size);
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

    /// Count the samples of the next draws that pass the depth test, into
    /// query `index` of the `occlusion_query_set` of the pass
    /// (REQ-GPU-036). One query at a time, and each index once in a pass.
    pub fn beginOcclusionQuery(self: RenderPassEncoder, index: u32) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassBeginOcclusionQuery(self.handle, index);
        } else {
            native.wgpuRenderPassEncoderBeginOcclusionQuery(self.handle, index);
        }
    }

    /// End the query of `beginOcclusionQuery` (REQ-GPU-036).
    pub fn endOcclusionQuery(self: RenderPassEncoder) void {
        if (comptime is_wasm) {
            web.webgpuRenderPassEndOcclusionQuery(self.handle);
        } else {
            native.wgpuRenderPassEncoderEndOcclusionQuery(self.handle);
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
    /// Write GPU timestamps at the start and the end of the pass
    /// (REQ-GPU-028). The web build ignores it.
    timestamp_writes: ?RenderPassTimestampWrites = null,
    /// The occlusion queries of `beginOcclusionQuery` go into this set
    /// (REQ-GPU-036). It must be a set of type `.occlusion`.
    occlusion_query_set: ?QuerySet = null,
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

/// One end of `CommandEncoder.copyTextureToTexture`: a texture, a mip
/// level and the first texel.
pub const TextureCopy = struct {
    texture: Texture,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
};

/// Image copy texture (overrides types.zig version)
pub const ImageCopyTexture = struct {
    texture: *Texture,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: types.TextureAspect = .all,
};
