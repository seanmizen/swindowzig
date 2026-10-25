// Run the voxel web build (app.wasm) in Bun, with no browser and no GPU.
//
// headless.ts (the CI run) and worker-pool.test.ts use this file. It makes
// one import for each entry of WebAssembly.Module.imports(module):
//   - The time import reads a clock that the caller controls ('sim'), or
//     performance.now() ('real').
//   - The "chunks" imports use a real WorkerPool (worker-pool.ts) with real
//     Bun Web Workers, or no pool.
//   - The storage and asset imports are the real ones.
//   - The WebGPU buffer imports are a stub that records each buffer and each
//     write (StubGpu), and checks the WebGPU rules of writeBuffer. The tests
//     use it to check the mesh uploads (C5).
//   - Each other import (WebGPU, canvas, audio) does nothing, and returns a
//     new handle.

import { createAssetImports } from './assets';
import { HeldBytes } from './held-bytes';
import { createStorageImports } from './storage';
import {
  attachPool,
  chunkImports,
  type PoolHolder,
  WorkerPool,
  type WorkerPoolOptions,
} from './worker-pool';

export const FRAME_MS = 1000 / 60;

const HEADER_LEN = 16;
const GPU_USAGE_STORAGE = 0x0080;

/** One GPU buffer of the stub. */
export interface StubBuffer {
  size: number;
  usage: number;
  destroyed: boolean;
}

/** One writeBuffer to a storage buffer (the chunk quad buffers). */
export interface StubWrite {
  frame: number;
  buffer: number;
  offset: number;
  size: number;
  /** 'wasm': from the wasm memory. 'held': from bytes that JS holds. */
  source: 'wasm' | 'held';
  /** A 16-byte write from the wasm memory: its 4 u32 values. */
  header?: [number, number, number, number];
  /** A held write: the first byte in the held message. */
  heldOffset?: number;
  /** A held write of a mesh Result: its chunk and its quad count. */
  mesh?: { cx: number; cz: number; quads: number; messageLength: number };
}

/**
 * The WebGPU buffer imports of the headless run. It records the buffers and
 * the writes to storage buffers, and checks the rules of writeBuffer: the
 * buffer exists and is not destroyed, the offset and the size are multiples
 * of 4, and the write fits in the buffer. Each break of a rule goes into
 * `errors`. With `record` false (a --measure run), it keeps the checks and
 * the counters, but not the list of writes: the list costs main-thread
 * time that a browser does not have.
 */
export class StubGpu {
  readonly buffers = new Map<number, StubBuffer>();
  readonly writes: StubWrite[] = [];
  readonly errors: string[] = [];
  created = 0;
  destroyed = 0;
  bindGroups = 0;
  /** Writes from held bytes, also when `record` is false. */
  heldWrites = 0;
  frame = 0;

  constructor(
    private nextHandle: () => number,
    private getMemory: () => WebAssembly.Memory,
    private held: HeldBytes,
    readonly record: boolean,
  ) {}

  private check(handle: number, offset: number, size: number): StubBuffer {
    const b = this.buffers.get(handle);
    if (!b) {
      this.error(`writeBuffer to buffer ${handle}, which does not exist`);
      return { size: 0, usage: 0, destroyed: true };
    }
    if (b.destroyed) this.error(`writeBuffer to destroyed buffer ${handle}`);
    if (offset % 4 !== 0 || size % 4 !== 0) {
      this.error(
        `writeBuffer offset ${offset} or size ${size} is not a multiple of 4`,
      );
    }
    if (offset + size > b.size) {
      this.error(
        `writeBuffer of ${size} bytes at ${offset} is past the end of buffer ${handle} (${b.size} bytes)`,
      );
    }
    return b;
  }

  private error(message: string): void {
    if (this.errors.length === 0) console.error(`[stub gpu] ${message}`);
    this.errors.push(message);
  }

  imports(): Record<string, (...args: never[]) => unknown> {
    return {
      webgpuCreateBuffer: (
        _device: number,
        size: bigint,
        usage: number,
      ): number => {
        const handle = this.nextHandle();
        this.buffers.set(handle, {
          size: Number(size),
          usage,
          destroyed: false,
        });
        this.created++;
        return handle;
      },
      webgpuBufferDestroy: (handle: number): void => {
        const b = this.buffers.get(handle);
        if (!b || b.destroyed)
          this.error(`destroy of buffer ${handle}, which is not live`);
        if (b) b.destroyed = true;
        this.destroyed++;
      },
      webgpuCreateBindGroup: (): number => {
        this.bindGroups++;
        return this.nextHandle();
      },
      webgpuWriteBuffer: (
        _queue: number,
        handle: number,
        offset: bigint,
        ptr: number,
        size: bigint,
      ): void => {
        const b = this.check(handle, Number(offset), Number(size));
        if (!this.record || (b.usage & GPU_USAGE_STORAGE) === 0) return;
        const w: StubWrite = {
          frame: this.frame,
          buffer: handle,
          offset: Number(offset),
          size: Number(size),
          source: 'wasm',
        };
        if (w.size === 16) {
          const v = new Uint32Array(
            this.getMemory().buffer.slice(ptr, ptr + 16),
          );
          w.header = [v[0], v[1], v[2], v[3]];
        }
        this.writes.push(w);
      },
      webgpuWriteBufferHeld: (
        _queue: number,
        handle: number,
        offset: bigint,
        heldHandle: number,
        heldOffset: number,
        size: bigint,
      ): void => {
        this.check(handle, Number(offset), Number(size));
        const bytes = this.held.get(heldHandle);
        if (heldOffset + Number(size) > bytes.byteLength) {
          this.error(
            `held write of ${size} bytes at ${heldOffset} is past the end of the held message (${bytes.byteLength} bytes)`,
          );
        }
        this.heldWrites++;
        this.held.countGpuWrite(Number(size));
        if (!this.record) return;
        const view = new DataView(
          bytes.buffer,
          bytes.byteOffset,
          bytes.byteLength,
        );
        const w: StubWrite = {
          frame: this.frame,
          buffer: handle,
          offset: Number(offset),
          size: Number(size),
          source: 'held',
          heldOffset,
        };
        if (bytes[6] === 4 && bytes[HEADER_LEN] === 2) {
          w.mesh = {
            cx: view.getInt32(HEADER_LEN + 4, true),
            cz: view.getInt32(HEADER_LEN + 8, true),
            quads: view.getUint32(HEADER_LEN + 24, true),
            messageLength: bytes.byteLength,
          };
        }
        this.writes.push(w);
      },
    };
  }
}

/** voxel_debug_gpu_counts (main.zig). */
export interface GpuCounts {
  uploadsLocal: number;
  uploadsHeld: number;
  buffersCreated: number;
  buffersReused: number;
  buffersDestroyed: number;
  buffersFree: number;
  uploadsWaiting: number;
  cpuCopies: number;
  headBytes: number;
  payloadBytes: number;
  heldMeshes: number;
  chunksOnGpu: number;
}

interface VoxelExports {
  memory: WebAssembly.Memory;
  swindowzig_init: () => void;
  swindowzig_frame: (timestamp: number) => void;
  swindowzig_event_resize: (w: number, h: number, dpi: number) => void;
  swindowzig_event_key: (keycode: number, down: boolean) => void;
  swindowzig_event_mouse_button: (button: number, down: boolean) => void;
  voxel_debug_chunk_counts?: (radius: number) => number;
  voxel_debug_pipeline_counts?: () => number;
  voxel_debug_world_hash?: () => bigint;
  voxel_debug_edit?: (
    wx: number,
    wy: number,
    wz: number,
    block: number,
  ) => number;
  voxel_debug_gpu_counts?: () => number;
  voxel_debug_set_render_distance?: (r: number) => void;
}

export interface ChunkCounts {
  cx: number;
  cz: number;
  loadedNear: number;
  meshedNear: number;
  area: number;
  loadedTotal: number;
  meshedTotal: number;
  loading: boolean;
}

/** voxel_debug_pipeline_counts (main.zig). */
export interface PipelineCounts {
  /** 'web': the WorkerPool executor. 'inline': the main thread. */
  executor: 'inline' | 'web';
  workers: number;
  /** Chunk jobs that ran on the main thread (the Inline executor). */
  mainJobs: number;
  /** Chunks that the simulation radius generated inline (C6). */
  simGenerated: number;
  workerJobs: number;
  installed: number;
  discarded: number;
  idle: boolean;
  fallbacks: number;
  inFlight: number;
  loading: boolean;
  badReplies: number;
}

export interface PoolSetup {
  /** The path of chunks.wasm. The default is next to app.wasm. */
  chunksPath?: string;
  /** The worker script. The default is chunk-worker.ts next to this file. */
  workerUrl?: string;
  size?: number;
  createWorker?: WorkerPoolOptions['createWorker'];
  maxRestarts?: number;
  /** Tests only: change the handshake values of app.wasm. */
  appHandshake?: {
    protocolVersion?: number;
    buildHash?: bigint;
    buildId?: bigint;
  };
}

export interface AppOptions {
  wasm: string;
  /** null: no pool. app.wasm uses the Inline executor. */
  pool: PoolSetup | null;
  /** 'sim': each frame adds FRAME_MS to the clock. 'real': performance.now(). */
  clock: 'sim' | 'real';
  /** Print the wasm log. */
  log?: boolean;
  /**
   * Keep the list of GPU writes for checkMeshUploads. The default is true.
   * A --measure run sets false, so the stub costs less time.
   */
  recordGpu?: boolean;
}

export interface HeadlessApp {
  /** Run one frame. Returns the main-thread time of the frame in ms. */
  frame(): number;
  /** Run frames with a yield to the event loop after each frame. */
  frames(n: number): Promise<void>;
  counts(radius: number): ChunkCounts;
  pipeline(): PipelineCounts | null;
  worldHash(): bigint;
  edit(wx: number, wy: number, wz: number, block: number): boolean;
  /** The mesh upload counters of app.wasm (C5). */
  gpuCounts(): GpuCounts;
  /** Set the render distance, as the Settings picker does. */
  setRenderDistance(r: number): void;
  /** The stub WebGPU buffers and writes. */
  gpu: StubGpu;
  /** The results that JS holds for app.wasm, and their counters (C5). */
  held: HeldBytes;
  key(keycode: number, down: boolean): void;
  mouse(button: number, down: boolean): void;
  /** The size of the main wasm memory in bytes. It never gets smaller. */
  memoryBytes(): number;
  /** Simulated seconds ('sim' clock) since the start. */
  seconds(): number;
  frameCount(): number;
  pool: WorkerPool | null;
  stop(): void;
}

/** Let the event loop deliver the messages of the workers. */
export function yieldToEventLoop(ms = 0): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function dirOf(path: string): string {
  const i = path.lastIndexOf('/');
  return i < 0 ? '.' : path.slice(0, i);
}

export async function startApp(opts: AppOptions): Promise<HeadlessApp> {
  const file = Bun.file(opts.wasm);
  if (!(await file.exists())) {
    throw new Error(
      `${opts.wasm} does not exist. Run: zig build web -Dexample=voxel`,
    );
  }
  const module = new WebAssembly.Module(await file.arrayBuffer());

  let nowMs = 0;
  let frames = 0;
  let memory: WebAssembly.Memory | null = null;
  const getMemory = () => {
    if (!memory) throw new Error('wasm memory is not ready');
    return memory;
  };
  const decoder = new TextDecoder();
  const holder: PoolHolder = { pool: null };
  const held = new HeldBytes();
  // Every other import does nothing and returns a new handle. A handle is
  // never 0, because the Zig side reads 0 as "no object".
  let nextHandle = 1;
  const stub = () => nextHandle++;
  const gpu = new StubGpu(stub, getMemory, held, opts.recordGpu ?? true);

  // D7: the pool starts first, as in the loader.
  let poolStart: Promise<WorkerPool> | null = null;
  if (opts.pool) {
    const chunksPath =
      opts.pool.chunksPath ?? `${dirOf(opts.wasm)}/chunks.wasm`;
    const chunks = Bun.file(chunksPath);
    if (!(await chunks.exists())) {
      throw new Error(
        `${chunksPath} does not exist. Run: zig build web -Dexample=voxel`,
      );
    }
    poolStart = WorkerPool.start({
      module: new WebAssembly.Module(await chunks.arrayBuffer()),
      workerUrl:
        opts.pool.workerUrl ??
        new URL('./chunk-worker.ts', import.meta.url).href,
      size: opts.pool.size,
      createWorker: opts.pool.createWorker,
      maxRestarts: opts.pool.maxRestarts,
      logPrefix: '[headless chunks]',
    });
  }

  const real: Record<string, Record<string, unknown>> = {
    env: {
      jsGetTime: opts.clock === 'sim' ? () => nowMs : () => performance.now(),
      jsLog: (ptr: number, len: number) => {
        if (!opts.log) return;
        const bytes = new Uint8Array(getMemory().buffer, ptr, len);
        console.log(`wasm: ${decoder.decode(bytes)}`);
      },
      ...createStorageImports(getMemory),
      ...createAssetImports(getMemory),
    },
    chunks: chunkImports(holder, getMemory, held),
    webgpu: gpu.imports(),
  };

  const imports: Record<string, Record<string, unknown>> = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.kind !== 'function') {
      throw new Error(
        `Import ${imp.module}.${imp.name} is a ${imp.kind}, not a function`,
      );
    }
    imports[imp.module] ??= {};
    const fn = real[imp.module]?.[imp.name];
    imports[imp.module][imp.name] = fn ?? stub;
  }

  const instance = new WebAssembly.Instance(
    module,
    imports as WebAssembly.Imports,
  );
  const wasm = instance.exports as unknown as VoxelExports;
  memory = wasm.memory;

  let pool: WorkerPool | null = null;
  if (poolStart) {
    pool = await poolStart;
    const override = opts.pool?.appHandshake;
    const appExports = override
      ? {
          voxel_chunk_protocol_version: () =>
            override.protocolVersion ??
            (instance.exports.voxel_chunk_protocol_version as () => number)(),
          voxel_chunk_build_hash: () =>
            override.buildHash ??
            (instance.exports.voxel_chunk_build_hash as () => bigint)(),
          voxel_chunk_build_id: () =>
            override.buildId ??
            (instance.exports.voxel_chunk_build_id as () => bigint)(),
        }
      : instance.exports;
    attachPool(holder, pool, appExports, '[headless chunks]');
  }

  const debugCounts = wasm.voxel_debug_chunk_counts;
  if (!debugCounts)
    throw new Error('app.wasm has no voxel_debug_chunk_counts export');

  wasm.swindowzig_init();
  wasm.swindowzig_event_resize(1280, 720, 1);

  const frame = (): number => {
    nowMs += FRAME_MS;
    frames++;
    gpu.frame = frames;
    const t0 = performance.now();
    wasm.swindowzig_frame(opts.clock === 'sim' ? nowMs : performance.now());
    return performance.now() - t0;
  };

  return {
    frame,
    async frames(n: number) {
      for (let i = 0; i < n; i++) {
        frame();
        if (holder.pool) await yieldToEventLoop();
      }
    },
    counts(radius: number): ChunkCounts {
      const ptr = debugCounts(radius);
      const v = new Int32Array(getMemory().buffer, ptr, 8);
      return {
        cx: v[0],
        cz: v[1],
        loadedNear: v[2],
        meshedNear: v[3],
        area: v[4],
        loadedTotal: v[5],
        meshedTotal: v[6],
        loading: v[7] !== 0,
      };
    },
    pipeline(): PipelineCounts | null {
      if (!wasm.voxel_debug_pipeline_counts) return null;
      const ptr = wasm.voxel_debug_pipeline_counts();
      const v = new Uint32Array(getMemory().buffer, ptr, 12);
      return {
        executor: v[0] === 1 ? 'web' : 'inline',
        workers: v[1],
        mainJobs: v[2],
        simGenerated: v[3],
        workerJobs: v[4],
        installed: v[5],
        discarded: v[6],
        idle: v[7] !== 0,
        fallbacks: v[8],
        inFlight: v[9],
        loading: v[10] !== 0,
        badReplies: v[11],
      };
    },
    worldHash(): bigint {
      if (!wasm.voxel_debug_world_hash)
        throw new Error('app.wasm has no voxel_debug_world_hash export');
      return BigInt.asUintN(64, wasm.voxel_debug_world_hash());
    },
    edit(wx: number, wy: number, wz: number, block: number): boolean {
      if (!wasm.voxel_debug_edit)
        throw new Error('app.wasm has no voxel_debug_edit export');
      return wasm.voxel_debug_edit(wx, wy, wz, block) !== 0;
    },
    gpuCounts(): GpuCounts {
      if (!wasm.voxel_debug_gpu_counts)
        throw new Error('app.wasm has no voxel_debug_gpu_counts export');
      const v = new Uint32Array(
        getMemory().buffer,
        wasm.voxel_debug_gpu_counts(),
        12,
      );
      return {
        uploadsLocal: v[0],
        uploadsHeld: v[1],
        buffersCreated: v[2],
        buffersReused: v[3],
        buffersDestroyed: v[4],
        buffersFree: v[5],
        uploadsWaiting: v[6],
        cpuCopies: v[7],
        headBytes: v[8],
        payloadBytes: v[9],
        heldMeshes: v[10],
        chunksOnGpu: v[11],
      };
    },
    setRenderDistance(r: number) {
      if (!wasm.voxel_debug_set_render_distance)
        throw new Error(
          'app.wasm has no voxel_debug_set_render_distance export',
        );
      wasm.voxel_debug_set_render_distance(r);
    },
    gpu,
    held,
    key(keycode: number, down: boolean) {
      wasm.swindowzig_event_key(keycode, down);
    },
    mouse(button: number, down: boolean) {
      wasm.swindowzig_event_mouse_button(button, down);
    },
    memoryBytes: () => getMemory().buffer.byteLength,
    seconds: () => (frames * FRAME_MS) / 1000,
    frameCount: () => frames,
    pool,
    stop() {
      pool?.stop();
      holder.pool = null;
    },
  };
}

/** The size of the head of a Result: the part that app.wasm copies (C5). */
export const RESULT_HEAD_BYTES = 64;
/** The GPU header of a chunk quad buffer: (origin x, tick, origin z, 0). */
const GPU_HEADER_BYTES = 16;
const CHUNK_W = 16;

/** What checkMeshUploads found. */
export interface UploadReport {
  /** Each problem, as a sentence. Empty when the uploads are correct. */
  failures: string[];
  /** GPU writes of meshes from held bytes. */
  heldWrites: number;
  /** Bytes that JS wrote into the wasm memory for each held result. */
  headBytesPerResult: number;
}

/**
 * Check the mesh uploads of a run (C5). Call it when the scheduler is idle
 * and after one more frame, so that each new mesh is on the GPU.
 *
 * With the WorkerPool executor (`pooled`):
 *   - JS wrote no mesh quad into the wasm memory. For each result, JS wrote
 *     at most RESULT_HEAD_BYTES into the wasm memory.
 *   - Each mesh went to the GPU from the held bytes: one held write for
 *     each upload, at byte 16 of the buffer, from byte 64 of the message,
 *     with the size of the quads. Just before it, main wrote the 16-byte
 *     GPU header of the same chunk to the same buffer.
 * With no pool (`pooled` false): no held upload. With null (a run that
 * changed from the pool to the Inline executor), no check of the kind.
 *
 * In all runs: no write broke a WebGPU rule, no quad bytes wait, no chunk
 * keeps a CPU copy, the quad payload of a mesh never went into the wasm
 * memory, and JS holds no result after the uploads (no leak).
 */
export function checkMeshUploads(
  app: HeadlessApp,
  pooled: boolean | null,
): UploadReport {
  const failures: string[] = [];
  const g = app.gpuCounts();
  const st = app.held.stats;
  for (const e of app.gpu.errors.slice(0, 5)) failures.push(`stub GPU: ${e}`);
  if (g.uploadsWaiting !== 0)
    failures.push(`${g.uploadsWaiting} chunks still wait for their upload`);
  if (g.cpuCopies !== 0)
    failures.push(`${g.cpuCopies} chunks keep a CPU copy of their quads`);

  // The list of writes exists only when the stub records it.
  const last = new Map<number, StubWrite>();
  const heldWrites = app.gpu.heldWrites;
  for (const w of app.gpu.writes) {
    if (w.source === 'held') {
      const m = w.mesh;
      const where = m ? `chunk (${m.cx}, ${m.cz})` : `buffer ${w.buffer}`;
      if (!m) {
        failures.push(`a held write to ${where} is not a mesh Result`);
      } else {
        if (w.size !== m.quads * 16)
          failures.push(`${where}: ${w.size} bytes for ${m.quads} quads`);
        if (w.size !== m.messageLength - RESULT_HEAD_BYTES)
          failures.push(`${where}: the write is not the whole payload`);
      }
      if (w.offset !== GPU_HEADER_BYTES || w.heldOffset !== RESULT_HEAD_BYTES)
        failures.push(
          `${where}: quads at buffer offset ${w.offset} from message offset ${w.heldOffset}`,
        );
      const h = last.get(w.buffer);
      if (
        !h?.header ||
        h.offset !== 0 ||
        h.frame !== w.frame ||
        (m && (h.header[0] | 0) !== m.cx * CHUNK_W) ||
        (m && (h.header[2] | 0) !== m.cz * CHUNK_W) ||
        h.header[3] !== 0
      ) {
        failures.push(`${where}: no GPU header of the chunk before the quads`);
      }
    }
    last.set(w.buffer, w);
  }

  const headBytesPerResult = st.held === 0 ? 0 : st.headBytes / st.held;
  if (st.meshPayloadBytes !== 0)
    failures.push(
      `JS copied ${st.meshPayloadBytes} bytes of mesh quads into the wasm memory`,
    );
  if (st.headBytes > st.held * RESULT_HEAD_BYTES)
    failures.push(
      `JS copied ${st.headBytes} head bytes for ${st.held} results (more than ${RESULT_HEAD_BYTES} each)`,
    );
  if (app.held.count !== 0)
    failures.push(`JS still holds ${app.held.count} results`);
  if (pooled === true) {
    if (g.uploadsHeld === 0 || heldWrites === 0)
      failures.push('no mesh went to the GPU from held bytes');
    if (heldWrites !== g.uploadsHeld)
      failures.push(
        `${heldWrites} held GPU writes for ${g.uploadsHeld} held uploads`,
      );
    if (g.uploadsLocal !== 0)
      failures.push(`${g.uploadsLocal} meshes came from the wasm memory`);
    if (g.headBytes !== st.headBytes || g.payloadBytes !== st.payloadBytes)
      failures.push(
        `app.wasm counted ${g.headBytes}+${g.payloadBytes} bytes in, JS counted ${st.headBytes}+${st.payloadBytes}`,
      );
  } else if (pooled === false && (g.uploadsHeld !== 0 || heldWrites !== 0)) {
    failures.push('a run with no pool made a held upload');
  }
  return { failures: failures.slice(0, 20), heldWrites, headBytesPerResult };
}
