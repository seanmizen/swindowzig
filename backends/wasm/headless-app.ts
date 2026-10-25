// Run the voxel web build (app.wasm) in Bun, with no browser and no GPU.
//
// headless.ts (the CI run) and worker-pool.test.ts use this file. It makes
// one import for each entry of WebAssembly.Module.imports(module):
//   - The time import reads a clock that the caller controls ('sim'), or
//     performance.now() ('real').
//   - The "chunks" imports use a real WorkerPool (worker-pool.ts) with real
//     Bun Web Workers, or no pool.
//   - The storage and asset imports are the real ones.
//   - Each other import (WebGPU, canvas, audio) does nothing, and returns a
//     new handle.

import { createAssetImports } from './assets';
import { createStorageImports } from './storage';
import {
  attachPool,
  chunkImports,
  type PoolHolder,
  WorkerPool,
  type WorkerPoolOptions,
} from './worker-pool';

export const FRAME_MS = 1000 / 60;

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
  key(keycode: number, down: boolean): void;
  mouse(button: number, down: boolean): void;
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
    chunks: chunkImports(holder, getMemory),
  };

  // Every other import does nothing and returns a new handle. A handle is
  // never 0, because the Zig side reads 0 as "no object".
  let nextHandle = 1;
  const stub = () => nextHandle++;
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
    key(keycode: number, down: boolean) {
      wasm.swindowzig_event_key(keycode, down);
    },
    mouse(button: number, down: boolean) {
      wasm.swindowzig_event_mouse_button(button, down);
    },
    seconds: () => (frames * FRAME_MS) / 1000,
    frameCount: () => frames,
    pool,
    stop() {
      pool?.stop();
      holder.pool = null;
    },
  };
}
