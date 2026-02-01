// WebGPU Bridge for swindowzig WASM
// Implements all extern functions declared in libs/sw_gpu/src/web_bridge.zig
// Maps JavaScript WebGPU objects to numeric handles for WASM interop

export interface GPUBridge {
  device: GPUDevice;
  context: GPUCanvasContext;
  imports: Record<string, (...args: never[]) => unknown>;
}

// Handle management for WebGPU objects
// WASM can't directly hold JS objects, so we use numeric handles
let nextHandle = 1;
const handles = new Map<number, unknown>();

function createHandle(obj: unknown): number {
  const handle = nextHandle++;
  handles.set(handle, obj);
  return handle;
}

function getHandle<T>(handle: number): T {
  const obj = handles.get(handle);
  if (!obj) throw new Error(`Invalid handle: ${handle}`);
  return obj as T;
}

// Global state
let gpuDevice: GPUDevice | null = null;
let gpuQueue: GPUQueue | null = null;
let gpuContext: GPUCanvasContext | null = null;
let canvasFormat: GPUTextureFormat | null = null;

export async function initWebGPU(
  canvas: HTMLCanvasElement,
): Promise<GPUBridge> {
  if (!navigator.gpu) {
    throw new Error('WebGPU not supported in this browser');
  }

  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error('No WebGPU adapter found');
  }

  const device = await adapter.requestDevice();
  const context = canvas.getContext('webgpu');
  if (!context) {
    throw new Error('Failed to get WebGPU context');
  }

  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({
    device,
    format,
    alphaMode: 'premultiplied',
  });

  // Store global references
  gpuDevice = device;
  gpuQueue = device.queue;
  gpuContext = context;
  canvasFormat = format;

  console.log('[WebGPU] Initialized successfully');
  console.log('[WebGPU] Canvas format:', format);

  // WASM imports
  const imports = createWebGPUImports();

  return { device, context, imports };
}

function createWebGPUImports(): Record<string, (...args: never[]) => unknown> {
  return {
    // =======================================================================
    // Initialization
    // =======================================================================

    webgpuInit: () => {
      // Already initialized in initWebGPU()
      console.log('[WebGPU] Init called from WASM');
    },

    webgpuRequestAdapter: (): number => {
      // Return dummy handle - we already have the adapter
      return 1;
    },

    webgpuRequestDevice: (_adapterHandle: number): number => {
      if (!gpuDevice) throw new Error('Device not initialized');
      return createHandle(gpuDevice);
    },

    webgpuGetQueue: (deviceHandle: number): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      return createHandle(device.queue);
    },

    // =======================================================================
    // Buffer Operations
    // =======================================================================

    webgpuCreateBuffer: (
      deviceHandle: number,
      size: bigint,
      usage: number,
      mappedAtCreation: boolean,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const buffer = device.createBuffer({
        size: Number(size),
        usage,
        mappedAtCreation,
      });
      return createHandle(buffer);
    },

    webgpuBufferGetMappedRange: (
      bufferHandle: number,
      offset: bigint,
      size: bigint,
    ): number => {
      const buffer = getHandle<GPUBuffer>(bufferHandle);
      const arrayBuffer = buffer.getMappedRange(Number(offset), Number(size));
      return createHandle(arrayBuffer);
    },

    webgpuBufferUnmap: (bufferHandle: number): void => {
      const buffer = getHandle<GPUBuffer>(bufferHandle);
      buffer.unmap();
    },

    webgpuBufferDestroy: (bufferHandle: number): void => {
      const buffer = getHandle<GPUBuffer>(bufferHandle);
      buffer.destroy();
    },

    webgpuWriteBuffer: (
      queueHandle: number,
      bufferHandle: number,
      bufferOffset: bigint,
      dataPtr: number,
      dataSize: bigint,
    ): void => {
      const queue = getHandle<GPUQueue>(queueHandle);
      const buffer = getHandle<GPUBuffer>(bufferHandle);

      // Get WASM memory and create a view
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) {
        console.error('[WebGPU] WASM memory not available');
        return;
      }

      const data = new Uint8Array(memory.buffer, dataPtr, Number(dataSize));
      queue.writeBuffer(buffer, Number(bufferOffset), data);
    },

    // =======================================================================
    // Texture Operations
    // =======================================================================

    webgpuCreateTexture: (
      deviceHandle: number,
      width: number,
      height: number,
      depth: number,
      format: number,
      usage: number,
      mipLevels: number,
      sampleCount: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);

      // Map format enum to GPUTextureFormat string
      const formatMap: Record<number, GPUTextureFormat> = {
        70: 'rgba8unorm',
        71: 'rgba8unorm-srgb',
        72: 'bgra8unorm',
        73: 'bgra8unorm-srgb',
        85: 'depth32float',
        83: 'depth24plus',
        // Add more as needed
      };

      const texture = device.createTexture({
        size: { width, height, depthOrArrayLayers: depth },
        format: formatMap[format] || 'rgba8unorm',
        usage,
        mipLevelCount: mipLevels,
        sampleCount,
      });

      return createHandle(texture);
    },

    webgpuCreateTextureView: (
      textureHandle: number,
      format: number,
      dimension: number,
      aspect: number,
      baseMipLevel: number,
      mipLevelCount: number,
      baseArrayLayer: number,
      arrayLayerCount: number,
    ): number => {
      const texture = getHandle<GPUTexture>(textureHandle);

      const dimensionMap: Record<number, GPUTextureViewDimension> = {
        0: 'undefined' as never,
        1: '1d',
        2: '2d',
        3: '2d-array',
        4: 'cube',
        5: 'cube-array',
        6: '3d',
      };

      const aspectMap: Record<number, GPUTextureAspect> = {
        0: 'all',
        1: 'stencil-only',
        2: 'depth-only',
      };

      const view = texture.createView({
        format: format ? (format as never) : undefined,
        dimension: dimensionMap[dimension],
        aspect: aspectMap[aspect] || 'all',
        baseMipLevel,
        mipLevelCount: mipLevelCount === 0xffffffff ? undefined : mipLevelCount,
        baseArrayLayer,
        arrayLayerCount:
          arrayLayerCount === 0xffffffff ? undefined : arrayLayerCount,
      });

      return createHandle(view);
    },

    webgpuTextureDestroy: (textureHandle: number): void => {
      const texture = getHandle<GPUTexture>(textureHandle);
      texture.destroy();
    },

    webgpuWriteTexture: (
      queueHandle: number,
      textureHandle: number,
      mipLevel: number,
      originX: number,
      originY: number,
      originZ: number,
      width: number,
      height: number,
      depth: number,
      dataPtr: number,
      dataSize: bigint,
      bytesPerRow: number,
      rowsPerImage: number,
    ): void => {
      const queue = getHandle<GPUQueue>(queueHandle);
      const texture = getHandle<GPUTexture>(textureHandle);

      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) return;

      const data = new Uint8Array(memory.buffer, dataPtr, Number(dataSize));

      queue.writeTexture(
        {
          texture,
          mipLevel,
          origin: { x: originX, y: originY, z: originZ },
        },
        data,
        { bytesPerRow, rowsPerImage },
        { width, height, depthOrArrayLayers: depth },
      );
    },

    // =======================================================================
    // Sampler Operations
    // =======================================================================

    webgpuCreateSampler: (
      deviceHandle: number,
      addressModeU: number,
      addressModeV: number,
      addressModeW: number,
      magFilter: number,
      minFilter: number,
      mipmapFilter: number,
      lodMin: number,
      lodMax: number,
      compare: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);

      const addressModeMap: Record<number, GPUAddressMode> = {
        0: 'repeat',
        1: 'mirror-repeat',
        2: 'clamp-to-edge',
      };

      const filterMap: Record<number, GPUFilterMode> = {
        0: 'nearest',
        1: 'linear',
      };

      const compareMap: Record<number, GPUCompareFunction | undefined> = {
        0: undefined,
        1: 'never',
        2: 'less',
        3: 'less-equal',
        4: 'greater',
        5: 'greater-equal',
        6: 'equal',
        7: 'not-equal',
        8: 'always',
      };

      const sampler = device.createSampler({
        addressModeU: addressModeMap[addressModeU],
        addressModeV: addressModeMap[addressModeV],
        addressModeW: addressModeMap[addressModeW],
        magFilter: filterMap[magFilter],
        minFilter: filterMap[minFilter],
        mipmapFilter: filterMap[mipmapFilter],
        lodMinClamp: lodMin,
        lodMaxClamp: lodMax,
        compare: compareMap[compare],
      });

      return createHandle(sampler);
    },

    // =======================================================================
    // Shader Operations
    // =======================================================================

    webgpuCreateShaderModule: (
      deviceHandle: number,
      codePtr: number,
      codeLen: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);

      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      const codeBytes = new Uint8Array(memory.buffer, codePtr, codeLen);
      const code = new TextDecoder().decode(codeBytes);

      const shader = device.createShaderModule({ code });

      // Log shader compilation errors
      shader.getCompilationInfo().then((info) => {
        for (const message of info.messages) {
          if (message.type === 'error') {
            console.error(
              `[WebGPU] Shader compilation error: ${message.message}`,
            );
          }
        }
      });

      return createHandle(shader);
    },

    // =======================================================================
    // Bind Group Layout Operations
    // =======================================================================

    webgpuCreateBindGroupLayout: (
      deviceHandle: number,
      entriesPtr: number,
      entryCount: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      const entries: GPUBindGroupLayoutEntry[] = [];

      // BindGroupLayoutEntryJS size calculation (extern struct):
      // binding(u32=4) + visibility(u32=4) + buffer_type(u32=4) + buffer_has_dynamic_offset(bool=4) +
      // buffer_min_binding_size(u64=8) + sampler_type(u32=4) + texture_sample_type(u32=4) +
      // texture_view_dimension(u32=4) + texture_multisampled(bool=4) + storage_access(u32=4) +
      // storage_format(u32=4) + storage_view_dimension(u32=4) = 56 bytes
      const entrySize = 56;

      for (let i = 0; i < entryCount; i++) {
        const ptr = entriesPtr + i * entrySize;
        const view = new DataView(memory.buffer, ptr, entrySize);
        let offset = 0;

        const binding = view.getUint32(offset, true);
        offset += 4;
        const visibility = view.getUint32(offset, true);
        offset += 4;
        const bufferType = view.getUint32(offset, true);
        offset += 4;
        const bufferHasDynamicOffset = view.getUint32(offset, true) !== 0;
        offset += 4;
        const bufferMinBindingSize = view.getBigUint64(offset, true);
        offset += 8;
        const samplerType = view.getUint32(offset, true);
        offset += 4;
        const textureSampleType = view.getUint32(offset, true);
        offset += 4;
        const textureViewDimension = view.getUint32(offset, true);
        offset += 4;
        const textureMultisampled = view.getUint32(offset, true) !== 0;
        offset += 4;
        const storageAccess = view.getUint32(offset, true);
        offset += 4;
        const storageFormat = view.getUint32(offset, true);
        offset += 4;
        const storageViewDimension = view.getUint32(offset, true);

        const entry: GPUBindGroupLayoutEntry = { binding, visibility };

        // Buffer binding
        if (bufferType !== 0) {
          const bufferTypeMap: Record<number, GPUBufferBindingType> = {
            1: 'uniform',
            2: 'storage',
            3: 'read-only-storage',
          };
          entry.buffer = {
            type: bufferTypeMap[bufferType],
            hasDynamicOffset: bufferHasDynamicOffset,
            minBindingSize: Number(bufferMinBindingSize),
          };
        }

        // Sampler binding
        if (samplerType !== 0) {
          const samplerTypeMap: Record<number, GPUSamplerBindingType> = {
            1: 'filtering',
            2: 'non-filtering',
            3: 'comparison',
          };
          entry.sampler = { type: samplerTypeMap[samplerType] };
        }

        // Texture binding
        if (textureSampleType !== 0) {
          const sampleTypeMap: Record<number, GPUTextureSampleType> = {
            1: 'float',
            2: 'unfilterable-float',
            3: 'depth',
            4: 'sint',
            5: 'uint',
          };
          const viewDimensionMap: Record<number, GPUTextureViewDimension> = {
            1: '1d',
            2: '2d',
            3: '2d-array',
            4: 'cube',
            5: 'cube-array',
            6: '3d',
          };
          entry.texture = {
            sampleType: sampleTypeMap[textureSampleType],
            viewDimension: viewDimensionMap[textureViewDimension],
            multisampled: textureMultisampled,
          };
        }

        // Storage texture binding
        if (storageAccess !== 0) {
          const accessMap: Record<number, GPUStorageTextureAccess> = {
            1: 'write-only',
            2: 'read-only',
            3: 'read-write',
          };
          const viewDimensionMap: Record<number, GPUTextureViewDimension> = {
            1: '1d',
            2: '2d',
            3: '2d-array',
            4: 'cube',
            5: 'cube-array',
            6: '3d',
          };
          entry.storageTexture = {
            access: accessMap[storageAccess],
            format: storageFormat as GPUTextureFormat,
            viewDimension: viewDimensionMap[storageViewDimension],
          };
        }

        entries.push(entry);
      }

      const layout = device.createBindGroupLayout({ entries });
      return createHandle(layout);
    },

    // =======================================================================
    // Bind Group Operations
    // =======================================================================

    webgpuCreateBindGroup: (
      deviceHandle: number,
      layoutHandle: number,
      entriesPtr: number,
      entryCount: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const layout = getHandle<GPUBindGroupLayout>(layoutHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      const entries: GPUBindGroupEntry[] = [];

      // BindGroupEntryJS size calculation (extern struct):
      // binding(u32=4) + resource_type(u32=4) + buffer(u32=4) + buffer_offset(u64=8) +
      // buffer_size(u64=8) + sampler(u32=4) + texture_view(u32=4) = 36 bytes
      const entrySize = 36;

      for (let i = 0; i < entryCount; i++) {
        const ptr = entriesPtr + i * entrySize;
        const view = new DataView(memory.buffer, ptr, entrySize);
        let offset = 0;

        const binding = view.getUint32(offset, true);
        offset += 4;
        const resourceType = view.getUint32(offset, true);
        offset += 4;
        const bufferHandle = view.getUint32(offset, true);
        offset += 4;
        const bufferOffset = view.getBigUint64(offset, true);
        offset += 8;
        const bufferSize = view.getBigUint64(offset, true);
        offset += 8;
        const samplerHandle = view.getUint32(offset, true);
        offset += 4;
        const textureViewHandle = view.getUint32(offset, true);

        const entry: GPUBindGroupEntry = { binding, resource: null as never };

        // Resource type: 1=buffer, 2=sampler, 3=texture_view
        if (resourceType === 1 && bufferHandle !== 0) {
          const buffer = getHandle<GPUBuffer>(bufferHandle);
          entry.resource = {
            buffer,
            offset: Number(bufferOffset),
            size: Number(bufferSize),
          };
        } else if (resourceType === 2 && samplerHandle !== 0) {
          entry.resource = getHandle<GPUSampler>(samplerHandle);
        } else if (resourceType === 3 && textureViewHandle !== 0) {
          entry.resource = getHandle<GPUTextureView>(textureViewHandle);
        }

        entries.push(entry);
      }

      const bindGroup = device.createBindGroup({ layout, entries });
      return createHandle(bindGroup);
    },

    // =======================================================================
    // Pipeline Layout Operations
    // =======================================================================

    webgpuCreatePipelineLayout: (
      deviceHandle: number,
      layoutsPtr: number,
      layoutCount: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      const bindGroupLayouts: GPUBindGroupLayout[] = [];

      // Array of WebGPUBindGroupLayout handles (u32 = 4 bytes each)
      for (let i = 0; i < layoutCount; i++) {
        const view = new DataView(memory.buffer, layoutsPtr + i * 4, 4);
        const handle = view.getUint32(0, true);
        bindGroupLayouts.push(getHandle<GPUBindGroupLayout>(handle));
      }

      const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts });
      return createHandle(pipelineLayout);
    },

    // =======================================================================
    // Render Pipeline Operations
    // =======================================================================

    webgpuCreateRenderPipeline: (
      deviceHandle: number,
      layoutHandle: number,
      vertexModuleHandle: number,
      vertexEntryPtr: number,
      vertexEntryLen: number,
      vertexBuffersPtr: number,
      vertexBufferCount: number,
      topology: number,
      stripIndexFormat: number,
      frontFace: number,
      cullMode: number,
      fragmentModuleHandle: number,
      fragmentEntryPtr: number,
      fragmentEntryLen: number,
      fragmentTargetsPtr: number,
      fragmentTargetCount: number,
      depthStencilFormat: number,
      depthWriteEnabled: boolean,
      depthCompare: number,
      sampleCount: number,
      sampleMask: number,
      alphaToCoverageEnabled: boolean,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      const vertexModule = getHandle<GPUShaderModule>(vertexModuleHandle);
      const vertexEntryBytes = new Uint8Array(
        memory.buffer,
        vertexEntryPtr,
        vertexEntryLen,
      );
      const vertexEntry = new TextDecoder().decode(vertexEntryBytes);

      const topologyMap: Record<number, GPUPrimitiveTopology> = {
        0: 'point-list',
        1: 'line-list',
        2: 'line-strip',
        3: 'triangle-list',
        4: 'triangle-strip',
      };

      const frontFaceMap: Record<number, GPUFrontFace> = {
        0: 'ccw',
        1: 'cw',
      };

      const cullModeMap: Record<number, GPUCullMode> = {
        0: 'none',
        1: 'front',
        2: 'back',
      };

      // Parse vertex buffer layouts
      const vertexBuffers: GPUVertexBufferLayout[] = [];
      // VertexBufferLayoutJS size: array_stride(u64=8) + step_mode(u32=4) +
      // attributes_ptr(u32=4) + attribute_count(u32=4) = 20 bytes
      const vertexBufferLayoutSize = 20;

      for (let i = 0; i < vertexBufferCount; i++) {
        const ptr = vertexBuffersPtr + i * vertexBufferLayoutSize;
        const view = new DataView(memory.buffer, ptr, vertexBufferLayoutSize);
        let offset = 0;

        const arrayStride = view.getBigUint64(offset, true);
        offset += 8;
        const stepMode = view.getUint32(offset, true);
        offset += 4;
        const attributesPtr = view.getUint32(offset, true);
        offset += 4;
        const attributeCount = view.getUint32(offset, true);

        // Parse vertex attributes
        // VertexAttributeJS size: format(u32=4) + offset(u64=8) + shader_location(u32=4) = 16 bytes
        const vertexAttributeSize = 16;
        const attributes: GPUVertexAttribute[] = [];

        for (let j = 0; j < attributeCount; j++) {
          const attrPtr = attributesPtr + j * vertexAttributeSize;
          const attrView = new DataView(
            memory.buffer,
            attrPtr,
            vertexAttributeSize,
          );
          let attrOffset = 0;

          const format = attrView.getUint32(attrOffset, true);
          attrOffset += 4;
          const attrByteOffset = attrView.getBigUint64(attrOffset, true);
          attrOffset += 8;
          const shaderLocation = attrView.getUint32(attrOffset, true);

          // Map format enum to GPUVertexFormat
          const vertexFormatMap: Record<number, GPUVertexFormat> = {
            1: 'uint8x2',
            2: 'uint8x4',
            3: 'sint8x2',
            4: 'sint8x4',
            5: 'unorm8x2',
            6: 'unorm8x4',
            7: 'snorm8x2',
            8: 'snorm8x4',
            9: 'uint16x2',
            10: 'uint16x4',
            11: 'sint16x2',
            12: 'sint16x4',
            13: 'unorm16x2',
            14: 'unorm16x4',
            15: 'snorm16x2',
            16: 'snorm16x4',
            17: 'float16x2',
            18: 'float16x4',
            19: 'float32',
            20: 'float32x2',
            21: 'float32x3',
            22: 'float32x4',
            23: 'uint32',
            24: 'uint32x2',
            25: 'uint32x3',
            26: 'uint32x4',
            27: 'sint32',
            28: 'sint32x2',
            29: 'sint32x3',
            30: 'sint32x4',
          };

          attributes.push({
            format: vertexFormatMap[format] || 'float32x3',
            offset: Number(attrByteOffset),
            shaderLocation,
          });
        }

        const stepModeMap: Record<number, GPUVertexStepMode> = {
          0: 'vertex',
          1: 'instance',
        };

        vertexBuffers.push({
          arrayStride: Number(arrayStride),
          stepMode: stepModeMap[stepMode] || 'vertex',
          attributes,
        });
      }

      const pipelineDesc: GPURenderPipelineDescriptor = {
        layout: layoutHandle ? getHandle(layoutHandle) : 'auto',
        vertex: {
          module: vertexModule,
          entryPoint: vertexEntry,
          buffers: vertexBuffers,
        },
        primitive: {
          topology: topologyMap[topology] || 'triangle-list',
          frontFace: frontFaceMap[frontFace] || 'ccw',
          cullMode: cullModeMap[cullMode] || 'none',
        },
        multisample: {
          count: sampleCount,
          mask: sampleMask,
          alphaToCoverageEnabled,
        },
      };

      // Add fragment stage if provided
      if (fragmentModuleHandle) {
        const fragmentModule = getHandle<GPUShaderModule>(fragmentModuleHandle);
        const fragmentEntryBytes = new Uint8Array(
          memory.buffer,
          fragmentEntryPtr,
          fragmentEntryLen,
        );
        const fragmentEntry = new TextDecoder().decode(fragmentEntryBytes);

        // Parse fragment targets
        // ColorTargetStateJS size: format(u32=4) + blend_enabled(bool=4) +
        // color_operation(u32=4) + color_src_factor(u32=4) + color_dst_factor(u32=4) +
        // alpha_operation(u32=4) + alpha_src_factor(u32=4) + alpha_dst_factor(u32=4) +
        // write_mask(u32=4) = 36 bytes
        const colorTargetSize = 36;
        const targets: GPUColorTargetState[] = [];

        for (let i = 0; i < fragmentTargetCount; i++) {
          const ptr = fragmentTargetsPtr + i * colorTargetSize;
          const view = new DataView(memory.buffer, ptr, colorTargetSize);
          let offset = 0;

          const format = view.getUint32(offset, true);
          offset += 4;
          const blendEnabled = view.getUint32(offset, true) !== 0;
          offset += 4;
          const colorOperation = view.getUint32(offset, true);
          offset += 4;
          const colorSrcFactor = view.getUint32(offset, true);
          offset += 4;
          const colorDstFactor = view.getUint32(offset, true);
          offset += 4;
          const alphaOperation = view.getUint32(offset, true);
          offset += 4;
          const alphaSrcFactor = view.getUint32(offset, true);
          offset += 4;
          const alphaDstFactor = view.getUint32(offset, true);
          offset += 4;
          const writeMask = view.getUint32(offset, true);

          const formatMap: Record<number, GPUTextureFormat> = {
            70: 'rgba8unorm',
            71: 'rgba8unorm-srgb',
            72: 'bgra8unorm',
            73: 'bgra8unorm-srgb',
          };

          const operationMap: Record<number, GPUBlendOperation> = {
            0: 'add',
            1: 'subtract',
            2: 'reverse-subtract',
            3: 'min',
            4: 'max',
          };

          const factorMap: Record<number, GPUBlendFactor> = {
            0: 'zero',
            1: 'one',
            2: 'src',
            3: 'one-minus-src',
            4: 'src-alpha',
            5: 'one-minus-src-alpha',
            6: 'dst',
            7: 'one-minus-dst',
            8: 'dst-alpha',
            9: 'one-minus-dst-alpha',
            10: 'src-alpha-saturated',
            11: 'constant',
            12: 'one-minus-constant',
          };

          const target: GPUColorTargetState = {
            format: formatMap[format] || canvasFormat || 'bgra8unorm',
            writeMask,
          };

          if (blendEnabled) {
            target.blend = {
              color: {
                operation: operationMap[colorOperation] || 'add',
                srcFactor: factorMap[colorSrcFactor] || 'one',
                dstFactor: factorMap[colorDstFactor] || 'zero',
              },
              alpha: {
                operation: operationMap[alphaOperation] || 'add',
                srcFactor: factorMap[alphaSrcFactor] || 'one',
                dstFactor: factorMap[alphaDstFactor] || 'zero',
              },
            };
          }

          targets.push(target);
        }

        pipelineDesc.fragment = {
          module: fragmentModule,
          entryPoint: fragmentEntry,
          targets,
        };
      }

      const pipeline = device.createRenderPipeline(pipelineDesc);
      return createHandle(pipeline);
    },

    // =======================================================================
    // Compute Pipeline Operations
    // =======================================================================

    webgpuCreateComputePipeline: (
      deviceHandle: number,
      layoutHandle: number,
      moduleHandle: number,
      entryPointPtr: number,
      entryPointLen: number,
    ): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      const module = getHandle<GPUShaderModule>(moduleHandle);
      const entryBytes = new Uint8Array(
        memory.buffer,
        entryPointPtr,
        entryPointLen,
      );
      const entryPoint = new TextDecoder().decode(entryBytes);

      const pipeline = device.createComputePipeline({
        layout: layoutHandle ? getHandle(layoutHandle) : 'auto',
        compute: {
          module,
          entryPoint,
        },
      });

      return createHandle(pipeline);
    },

    // =======================================================================
    // Command Encoding
    // =======================================================================

    webgpuCreateCommandEncoder: (deviceHandle: number): number => {
      const device = getHandle<GPUDevice>(deviceHandle);
      const encoder = device.createCommandEncoder();
      return createHandle(encoder);
    },

    webgpuCommandEncoderBeginRenderPass: (
      encoderHandle: number,
      colorAttachmentsPtr: number,
      colorAttachmentCount: number,
      depthStencilViewHandle: number,
      depthLoadOp: number,
      depthStoreOp: number,
      depthClearValue: number,
      stencilLoadOp: number,
      stencilStoreOp: number,
      stencilClearValue: number,
    ): number => {
      const encoder = getHandle<GPUCommandEncoder>(encoderHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) throw new Error('WASM memory not available');

      // Parse color attachments from memory
      const colorAttachments: GPURenderPassColorAttachment[] = [];
      const attachmentSize = 64; // Approximate size of RenderPassColorAttachmentJS

      for (let i = 0; i < colorAttachmentCount; i++) {
        const ptr = colorAttachmentsPtr + i * attachmentSize;
        const view = new DataView(memory.buffer, ptr, attachmentSize);

        const viewHandle = view.getUint32(0, true);
        const resolveTargetHandle = view.getUint32(4, true);
        const loadOp = view.getUint32(8, true);
        const storeOp = view.getUint32(12, true);
        const clearR = view.getFloat64(16, true);
        const clearG = view.getFloat64(24, true);
        const clearB = view.getFloat64(32, true);
        const clearA = view.getFloat64(40, true);

        const loadOpMap: Record<number, GPULoadOp> = {
          1: 'clear',
          2: 'load',
        };

        const storeOpMap: Record<number, GPUStoreOp> = {
          1: 'store',
          2: 'discard',
        };

        colorAttachments.push({
          view: getHandle<GPUTextureView>(viewHandle),
          resolveTarget: resolveTargetHandle
            ? getHandle<GPUTextureView>(resolveTargetHandle)
            : undefined,
          loadOp: loadOpMap[loadOp] || 'load',
          storeOp: storeOpMap[storeOp] || 'store',
          clearValue: { r: clearR, g: clearG, b: clearB, a: clearA },
        });
      }

      const loadOpMap: Record<number, GPULoadOp> = {
        1: 'clear',
        2: 'load',
      };

      const storeOpMap: Record<number, GPUStoreOp> = {
        1: 'store',
        2: 'discard',
      };

      // Add depth/stencil attachment if provided
      let depthStencilAttachment:
        | GPURenderPassDepthStencilAttachment
        | undefined;
      if (depthStencilViewHandle !== 0) {
        depthStencilAttachment = {
          view: getHandle<GPUTextureView>(depthStencilViewHandle),
          depthLoadOp: loadOpMap[depthLoadOp],
          depthStoreOp: storeOpMap[depthStoreOp],
          depthClearValue,
          stencilLoadOp: loadOpMap[stencilLoadOp],
          stencilStoreOp: storeOpMap[stencilStoreOp],
          stencilClearValue,
        };
      }

      const renderPass = encoder.beginRenderPass({
        colorAttachments,
        depthStencilAttachment,
      });

      return createHandle(renderPass);
    },

    webgpuCommandEncoderBeginComputePass: (encoderHandle: number): number => {
      const encoder = getHandle<GPUCommandEncoder>(encoderHandle);
      const computePass = encoder.beginComputePass();
      return createHandle(computePass);
    },

    webgpuCommandEncoderFinish: (encoderHandle: number): number => {
      const encoder = getHandle<GPUCommandEncoder>(encoderHandle);
      const commandBuffer = encoder.finish();
      return createHandle(commandBuffer);
    },

    // =======================================================================
    // Render Pass Encoding
    // =======================================================================

    webgpuRenderPassSetPipeline: (
      passHandle: number,
      pipelineHandle: number,
    ): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      const pipeline = getHandle<GPURenderPipeline>(pipelineHandle);
      pass.setPipeline(pipeline);
    },

    webgpuRenderPassSetBindGroup: (
      passHandle: number,
      index: number,
      bindGroupHandle: number,
      dynamicOffsetsPtr: number,
      dynamicOffsetCount: number,
    ): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      const bindGroup = getHandle<GPUBindGroup>(bindGroupHandle);

      // Parse dynamic offsets if provided
      let dynamicOffsets: Uint32Array | undefined;
      if (dynamicOffsetCount > 0) {
        const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
          .wasmMemory;
        if (memory) {
          dynamicOffsets = new Uint32Array(
            memory.buffer,
            dynamicOffsetsPtr,
            dynamicOffsetCount,
          );
        }
      }

      pass.setBindGroup(index, bindGroup, dynamicOffsets);
    },

    webgpuRenderPassSetVertexBuffer: (
      passHandle: number,
      slot: number,
      bufferHandle: number,
      offset: bigint,
      size: bigint,
    ): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      const buffer = getHandle<GPUBuffer>(bufferHandle);
      pass.setVertexBuffer(slot, buffer, Number(offset), Number(size));
    },

    webgpuRenderPassSetIndexBuffer: (
      passHandle: number,
      bufferHandle: number,
      format: number,
      offset: bigint,
      size: bigint,
    ): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      const buffer = getHandle<GPUBuffer>(bufferHandle);

      const formatMap: Record<number, GPUIndexFormat> = {
        1: 'uint16',
        2: 'uint32',
      };

      pass.setIndexBuffer(
        buffer,
        formatMap[format] || 'uint16',
        Number(offset),
        Number(size),
      );
    },

    webgpuRenderPassDraw: (
      passHandle: number,
      vertexCount: number,
      instanceCount: number,
      firstVertex: number,
      firstInstance: number,
    ): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
    },

    webgpuRenderPassDrawIndexed: (
      passHandle: number,
      indexCount: number,
      instanceCount: number,
      firstIndex: number,
      baseVertex: number,
      firstInstance: number,
    ): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      pass.drawIndexed(
        indexCount,
        instanceCount,
        firstIndex,
        baseVertex,
        firstInstance,
      );
    },

    webgpuRenderPassEnd: (passHandle: number): void => {
      const pass = getHandle<GPURenderPassEncoder>(passHandle);
      pass.end();
    },

    // =======================================================================
    // Compute Pass Encoding
    // =======================================================================

    webgpuComputePassSetPipeline: (
      passHandle: number,
      pipelineHandle: number,
    ): void => {
      const pass = getHandle<GPUComputePassEncoder>(passHandle);
      const pipeline = getHandle<GPUComputePipeline>(pipelineHandle);
      pass.setPipeline(pipeline);
    },

    webgpuComputePassSetBindGroup: (
      passHandle: number,
      index: number,
      bindGroupHandle: number,
      dynamicOffsetsPtr: number,
      dynamicOffsetCount: number,
    ): void => {
      const pass = getHandle<GPUComputePassEncoder>(passHandle);
      const bindGroup = getHandle<GPUBindGroup>(bindGroupHandle);

      // Parse dynamic offsets if provided
      let dynamicOffsets: Uint32Array | undefined;
      if (dynamicOffsetCount > 0) {
        const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
          .wasmMemory;
        if (memory) {
          dynamicOffsets = new Uint32Array(
            memory.buffer,
            dynamicOffsetsPtr,
            dynamicOffsetCount,
          );
        }
      }

      pass.setBindGroup(index, bindGroup, dynamicOffsets);
    },

    webgpuComputePassDispatch: (
      passHandle: number,
      workgroupCountX: number,
      workgroupCountY: number,
      workgroupCountZ: number,
    ): void => {
      const pass = getHandle<GPUComputePassEncoder>(passHandle);
      pass.dispatchWorkgroups(
        workgroupCountX,
        workgroupCountY,
        workgroupCountZ,
      );
    },

    webgpuComputePassEnd: (passHandle: number): void => {
      const pass = getHandle<GPUComputePassEncoder>(passHandle);
      pass.end();
    },

    // =======================================================================
    // Queue Submission
    // =======================================================================

    webgpuQueueSubmit: (
      queueHandle: number,
      commandBuffersPtr: number,
      commandBufferCount: number,
    ): void => {
      const queue = getHandle<GPUQueue>(queueHandle);
      const memory = (window as never as { wasmMemory?: WebAssembly.Memory })
        .wasmMemory;
      if (!memory) return;

      const commandBuffers: GPUCommandBuffer[] = [];
      for (let i = 0; i < commandBufferCount; i++) {
        const view = new DataView(memory.buffer, commandBuffersPtr + i * 4, 4);
        const handle = view.getUint32(0, true);
        commandBuffers.push(getHandle<GPUCommandBuffer>(handle));
      }

      queue.submit(commandBuffers);
    },

    // =======================================================================
    // Canvas/SwapChain Operations
    // =======================================================================

    webgpuGetCurrentTextureView: (): number => {
      if (!gpuContext) throw new Error('GPU context not initialized');
      const texture = gpuContext.getCurrentTexture();
      const view = texture.createView();
      return createHandle(view);
    },

    webgpuPresent: (): void => {
      // No-op on web - presentation happens automatically after queue.submit()
      // The browser handles presenting the swap chain
    },
  };
}
