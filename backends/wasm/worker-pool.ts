// The chunk worker pool of the web build (C9).
//
// The pool runs chunks.wasm in Web Workers (chunk-worker.ts). app.wasm
// sends protocol bytes to the pool through the "chunks" imports
// (pipeline/exec_web.zig), and takes the results in the frame phase (C7).
//
// Lifecycle:
//   1. start(): compile chunks.wasm one time (compileStreaming), start N
//      workers and send the Module to each. N = min(hardwareConcurrency - 1,
//      4), and 1 or more (D5, D6). Each worker sends its handshake values.
//      The loader calls start() first, before the loading screen (D7).
//   2. verify(): the loader compares the handshake values of each worker
//      with the values of app.wasm: the protocol version, the build hash
//      and the build id. A worker with other values stops, with a clear
//      error. Thus a cached old chunks.wasm cannot make wrong terrain.
//   3. app.wasm sends a Hello and the edits to each worker (broadcast), and
//      the jobs to one worker (post). The pool keeps the Hello, the edits
//      and the jobs in flight of each worker.
//   4. When a worker stops (an error event), the pool starts a new worker.
//      It sends the Module, the Hello, all the edits, then the jobs in
//      flight of the old worker, in their order. After MAX_RESTARTS, the
//      slot stops, and the pool sends its jobs to another worker.
//   5. When no worker runs, app.wasm uses the Inline executor (the
//      fallback). Without a pool, chunkImports() gives 0 slots.
//
// No SharedArrayBuffer and no wasm threads (section 11). Each message is a
// transferable ArrayBuffer.

import type { FromWorker, ToWorker } from './chunk-worker';

/** The most workers of a pool (C9). */
export const MAX_WORKERS = 4;
/** The restarts of one slot before the slot stops. */
export const MAX_RESTARTS = 3;
/** The time that a worker has to send its handshake values. */
export const START_TIMEOUT_MS = 10_000;

const KIND_HELLO = 1;
const KIND_ERROR = 5;
const HEADER_LEN = 16;

/** The values that app.wasm and chunks.wasm of one build share (C9). */
export interface Handshake {
  protocolVersion: number;
  buildHash: bigint;
  buildId: bigint;
}

export interface WorkerPoolOptions {
  /** The URL of chunks.wasm. Not used when `module` is set. */
  wasmUrl?: string | URL;
  /** A compiled chunks.wasm. */
  module?: WebAssembly.Module;
  /** The URL of the worker script (chunk-worker.js, or chunk-worker.ts in Bun). */
  workerUrl: string | URL;
  /** The number of workers. The default is defaultPoolSize(). */
  size?: number;
  /** Make a worker. The default is `new Worker(url, { type: 'module' })`. */
  createWorker?: (url: string | URL, slot: number) => Worker;
  /** The prefix of console messages. */
  logPrefix?: string;
  /** The restarts of one slot before the slot stops. */
  maxRestarts?: number;
  startTimeoutMs?: number;
}

/** min(hardwareConcurrency - 1, 4), and 1 or more (C9, D5). */
export function defaultPoolSize(): number {
  const cores =
    typeof navigator !== 'undefined' && navigator.hardwareConcurrency
      ? navigator.hardwareConcurrency
      : 2;
  return Math.max(1, Math.min(cores - 1, MAX_WORKERS));
}

interface Slot {
  index: number;
  worker: Worker | null;
  /** False when the slot stopped for good. */
  alive: boolean;
  /** The handshake values of the worker, after 'ready'. */
  handshake: Handshake | null;
  /** The job messages in flight, by job id, in the order that they went. */
  pending: Map<number, ArrayBuffer>;
  restarts: number;
}

/** A counter set for the tests and the debug overlay (C12). */
export interface PoolStats {
  slots: number;
  alive: number;
  restarts: number;
  jobsPosted: number;
  results: number;
  queued: number;
}

/** Holds the pool that the "chunks" imports use. Null: no pool. */
export interface PoolHolder {
  pool: WorkerPool | null;
}

function errorMessage(err: unknown): string {
  return String(err instanceof Error ? err.message : err);
}

function hex(v: bigint): string {
  return `0x${v.toString(16)}`;
}

/** The text of a handshake mismatch, or null when the values are equal. */
export function handshakeMismatch(
  worker: Handshake,
  app: Handshake,
): string | null {
  if (worker.protocolVersion !== app.protocolVersion) {
    return `chunks.wasm has protocol version ${worker.protocolVersion}, and app.wasm has ${app.protocolVersion}`;
  }
  if (worker.buildHash !== app.buildHash) {
    return `chunks.wasm has build hash ${hex(worker.buildHash)}, and app.wasm has ${hex(app.buildHash)}`;
  }
  if (worker.buildId !== app.buildId) {
    return `chunks.wasm has build id ${hex(worker.buildId)}, and app.wasm has ${hex(app.buildId)}`;
  }
  return null;
}

async function compileChunks(url: string | URL): Promise<WebAssembly.Module> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  if (typeof WebAssembly.compileStreaming === 'function') {
    return WebAssembly.compileStreaming(response);
  }
  return WebAssembly.compile(await response.arrayBuffer());
}

export class WorkerPool {
  readonly slots: Slot[] = [];
  /** The first error that stopped a slot, for the console and the tests. */
  error: string | null = null;
  restarts = 0;
  jobsPosted = 0;
  results = 0;

  private module: WebAssembly.Module;
  private options: WorkerPoolOptions;
  private logPrefix: string;
  private maxRestarts: number;
  private expected: Handshake | null = null;
  private hello: ArrayBuffer | null = null;
  private edits: ArrayBuffer[] = [];
  private queue: Uint8Array[] = [];
  private queueHead = 0;

  private constructor(module: WebAssembly.Module, options: WorkerPoolOptions) {
    this.module = module;
    this.options = options;
    this.logPrefix = options.logPrefix ?? '[chunks]';
    this.maxRestarts = options.maxRestarts ?? MAX_RESTARTS;
  }

  /**
   * Compile chunks.wasm and start the workers. Wait until each worker sent
   * its handshake values, or failed. The promise never rejects: on a
   * failure the pool has no live slot, and `error` tells why.
   */
  static async start(options: WorkerPoolOptions): Promise<WorkerPool> {
    const prefix = options.logPrefix ?? '[chunks]';
    let module: WebAssembly.Module;
    try {
      if (options.module) {
        module = options.module;
      } else if (options.wasmUrl) {
        module = await compileChunks(options.wasmUrl);
      } else {
        throw new Error('no chunks.wasm URL and no module');
      }
    } catch (err) {
      const pool = new WorkerPool(new WebAssembly.Module(EMPTY_WASM), options);
      pool.error = `chunks.wasm did not compile: ${errorMessage(err)}`;
      console.error(`${prefix} ${pool.error}`);
      return pool;
    }
    const pool = new WorkerPool(module, options);
    const size = Math.max(
      1,
      Math.min(options.size ?? defaultPoolSize(), MAX_WORKERS),
    );
    const ready: Promise<void>[] = [];
    for (let i = 0; i < size; i++) {
      const slot: Slot = {
        index: i,
        worker: null,
        alive: true,
        handshake: null,
        pending: new Map(),
        restarts: 0,
      };
      pool.slots.push(slot);
      ready.push(pool.launch(slot));
    }
    await Promise.all(ready);
    return pool;
  }

  /** The number of slots. It does not change. */
  get size(): number {
    return this.slots.length;
  }

  /** The number of slots that run. */
  get aliveCount(): number {
    return this.slots.filter((s) => s.alive).length;
  }

  stats(): PoolStats {
    return {
      slots: this.size,
      alive: this.aliveCount,
      restarts: this.restarts,
      jobsPosted: this.jobsPosted,
      results: this.results,
      queued: this.queue.length - this.queueHead,
    };
  }

  /**
   * Compare the handshake values of each worker with the values of app.wasm
   * (C9). A worker with other values stops. Returns false when no worker
   * runs after the check.
   */
  verify(app: Handshake): boolean {
    this.expected = app;
    for (const slot of this.slots) {
      if (!slot.alive || !slot.handshake) continue;
      const mismatch = handshakeMismatch(slot.handshake, app);
      if (mismatch) this.kill(slot, `${mismatch}. A cached old file?`);
    }
    if (this.aliveCount === 0 && !this.error) this.error = 'no worker runs';
    return this.aliveCount > 0;
  }

  /** Stop all workers. The pool then has no live slot. */
  stop(): void {
    for (const slot of this.slots) {
      slot.alive = false;
      slot.worker?.terminate();
      slot.worker = null;
      slot.pending.clear();
    }
  }

  /** Tests only: make the worker in `slot` throw, as a worker that stops. */
  crash(slot: number): void {
    const s = this.slots[slot];
    s?.worker?.postMessage({ type: 'crash' } satisfies ToWorker);
  }

  /** The jobs in flight of each slot. */
  pendingCounts(): number[] {
    return this.slots.map((s) => s.pending.size);
  }

  // -- The side of app.wasm (pipeline/exec_web.zig) ------------------------

  isAlive(slot: number): boolean {
    return this.slots[slot]?.alive ?? false;
  }

  /** Send a Job to one worker. The pool keeps a copy until the reply. */
  post(slot: number, msg: Uint8Array): boolean {
    const s = this.slots[slot];
    if (!s?.alive) return false;
    const id = new DataView(
      msg.buffer,
      msg.byteOffset,
      msg.byteLength,
    ).getUint32(12, true);
    const copy = msg.slice().buffer;
    s.pending.set(id, copy);
    this.jobsPosted++;
    this.send(s, copy.slice(0));
    return true;
  }

  /** Send a Hello or an Edit to each worker. The pool keeps a copy. */
  broadcast(msg: Uint8Array): boolean {
    if (this.aliveCount === 0) return false;
    const copy = msg.slice().buffer;
    if (msg[6] === KIND_HELLO) {
      this.hello = copy;
      this.edits = [];
    } else {
      this.edits.push(copy);
    }
    for (const s of this.slots) {
      if (s.alive) this.send(s, copy.slice(0));
    }
    return true;
  }

  /** The length of the next result, or 0. */
  nextLength(): number {
    return this.queue[this.queueHead]?.byteLength ?? 0;
  }

  /** Copy the next result into `out`, and remove it from the queue. */
  take(out: Uint8Array): void {
    const r = this.queue[this.queueHead];
    if (!r) return;
    out.set(r.subarray(0, out.byteLength));
    this.queue[this.queueHead] = EMPTY_RESULT;
    this.queueHead++;
    if (this.queueHead === this.queue.length) {
      this.queue = [];
      this.queueHead = 0;
    }
  }

  // -- Workers ---------------------------------------------------------------

  private send(slot: Slot, buf: ArrayBuffer): void {
    slot.worker?.postMessage({ type: 'msg', buf } satisfies ToWorker, [buf]);
  }

  /**
   * Start the worker of `slot`, and send it the Module. When app.wasm sent
   * a Hello already (a restart), send the Hello, the edits and the jobs in
   * flight too. The promise resolves at 'ready', at 'fail', or after the
   * timeout.
   */
  private launch(slot: Slot): Promise<void> {
    const url = this.options.workerUrl;
    let worker: Worker;
    try {
      worker = this.options.createWorker
        ? this.options.createWorker(url, slot.index)
        : new Worker(url, { type: 'module' });
    } catch (err) {
      this.kill(slot, `the worker did not start: ${errorMessage(err)}`);
      return Promise.resolve();
    }
    slot.worker = worker;
    slot.handshake = null;

    let settle: () => void = () => {};
    const ready = new Promise<void>((resolve) => {
      settle = resolve;
    });
    const timer = setTimeout(() => {
      if (slot.worker === worker && !slot.handshake) {
        this.kill(slot, 'the worker sent no handshake');
      }
      settle();
    }, this.options.startTimeoutMs ?? START_TIMEOUT_MS);

    worker.onmessage = (event: MessageEvent<FromWorker>) => {
      if (slot.worker !== worker) return;
      const data = event.data;
      if (data.type === 'reply') {
        this.onReply(slot, data.buf);
      } else if (data.type === 'ready') {
        // A wasm u64 arrives as a signed BigInt.
        slot.handshake = {
          protocolVersion: data.protocolVersion,
          buildHash: BigInt.asUintN(64, data.buildHash),
          buildId: BigInt.asUintN(64, data.buildId),
        };
        clearTimeout(timer);
        const mismatch = this.expected
          ? handshakeMismatch(slot.handshake, this.expected)
          : null;
        if (mismatch) this.kill(slot, `${mismatch}. A cached old file?`);
        settle();
      } else if (data.type === 'fail') {
        clearTimeout(timer);
        this.kill(slot, `chunks.wasm did not start: ${data.message}`);
        settle();
      }
    };
    const onStop = (why: string) => {
      if (slot.worker !== worker) return;
      clearTimeout(timer);
      settle();
      this.restart(slot, why);
    };
    worker.addEventListener('error', (event: Event) => {
      event.preventDefault?.();
      const message = (event as ErrorEvent).message ?? 'error';
      onStop(`the worker stopped: ${message}`);
    });
    worker.addEventListener('messageerror', () =>
      onStop('a message to the worker did not arrive'),
    );
    // Bun sends 'close' when a worker exits. Browsers do not.
    worker.addEventListener('close', () => onStop('the worker exited'));

    worker.postMessage({
      type: 'init',
      module: this.module,
      slot: slot.index,
    } satisfies ToWorker);
    if (this.hello) {
      this.send(slot, this.hello.slice(0));
      for (const e of this.edits) this.send(slot, e.slice(0));
      for (const job of slot.pending.values()) this.send(slot, job.slice(0));
    }
    return ready;
  }

  private onReply(slot: Slot, buf: ArrayBuffer): void {
    const bytes = new Uint8Array(buf);
    if (bytes.byteLength < HEADER_LEN) return;
    const view = new DataView(buf);
    const id = view.getUint32(12, true);
    if (id === 0) {
      // A reply to a Hello or an Edit.
      if (bytes[6] === KIND_HELLO) return;
      if (bytes[6] === KIND_ERROR) {
        const code = view.getUint16(HEADER_LEN, true);
        const len = view.getUint32(HEADER_LEN + 12, true);
        const text = new TextDecoder().decode(
          bytes.subarray(HEADER_LEN + 16, HEADER_LEN + 16 + len),
        );
        // Code 2: the Hello has another protocol version or build hash.
        // A new worker has the same file, so do not start it again.
        if (code === 2) {
          this.kill(slot, `the worker refused the Hello: ${text}`);
        } else {
          this.restart(slot, `the worker sent error ${code} (${text})`);
        }
      }
      return;
    }
    if (!slot.pending.delete(id)) return;
    this.results++;
    this.queue.push(bytes);
  }

  private restart(slot: Slot, why: string): void {
    if (!slot.alive) return;
    slot.worker?.terminate();
    slot.worker = null;
    if (slot.restarts >= this.maxRestarts) {
      this.kill(slot, `${why}, ${slot.restarts} restarts`);
      return;
    }
    slot.restarts++;
    this.restarts++;
    console.warn(
      `${this.logPrefix} worker ${slot.index}: ${why}. Start it again.`,
    );
    void this.launch(slot);
  }

  /** Stop `slot` for good, and send its jobs in flight to another worker. */
  private kill(slot: Slot, why: string): void {
    if (!slot.alive) return;
    slot.alive = false;
    slot.worker?.terminate();
    slot.worker = null;
    const message = `worker ${slot.index}: ${why}`;
    this.error ??= message;
    console.error(`${this.logPrefix} ${message}`);
    const jobs = [...slot.pending.entries()];
    slot.pending.clear();
    const other = this.slots.find((s) => s.alive);
    if (!other) {
      if (this.aliveCount === 0) {
        console.error(
          `${this.logPrefix} no chunk worker runs. The main thread runs the chunk jobs.`,
        );
      }
      return;
    }
    for (const [id, job] of jobs) {
      other.pending.set(id, job);
      this.send(other, job.slice(0));
    }
  }
}

// The smallest valid wasm module: the magic number and the version.
const EMPTY_WASM = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
]);
const EMPTY_RESULT = new Uint8Array(0);

/**
 * The "chunks" imports of app.wasm (pipeline/exec_web.zig). They read the
 * pool from `holder` when they run, so the loader can set the pool after
 * the instantiation. With no pool, jsChunkSlots returns 0, and app.wasm
 * uses the Inline executor.
 */
export function chunkImports(
  holder: PoolHolder,
  getMemory: () => WebAssembly.Memory,
): Record<string, (...args: never[]) => unknown> {
  const bytes = (ptr: number, len: number) =>
    new Uint8Array(getMemory().buffer, ptr, len);
  return {
    jsChunkSlots: (): number => holder.pool?.size ?? 0,
    jsChunkAlive: (slot: number): number =>
      holder.pool?.isAlive(slot) ? 1 : 0,
    jsChunkPost: (slot: number, ptr: number, len: number): number =>
      holder.pool?.post(slot, bytes(ptr, len)) ? 1 : 0,
    jsChunkBroadcast: (ptr: number, len: number): number =>
      holder.pool?.broadcast(bytes(ptr, len)) ? 1 : 0,
    jsChunkNextLen: (): number => holder.pool?.nextLength() ?? 0,
    jsChunkTake: (ptr: number, len: number): void => {
      holder.pool?.take(bytes(ptr, len));
    },
  };
}

interface HandshakeExports {
  voxel_chunk_protocol_version?: () => number;
  voxel_chunk_build_hash?: () => bigint;
  voxel_chunk_build_id?: () => bigint;
}

/** The handshake values of app.wasm, or null when it has none. */
export function appHandshake(exports: unknown): Handshake | null {
  const e = exports as HandshakeExports;
  if (
    !e.voxel_chunk_protocol_version ||
    !e.voxel_chunk_build_hash ||
    !e.voxel_chunk_build_id
  ) {
    return null;
  }
  return {
    protocolVersion: e.voxel_chunk_protocol_version(),
    buildHash: BigInt.asUintN(64, e.voxel_chunk_build_hash()),
    buildId: BigInt.asUintN(64, e.voxel_chunk_build_id()),
  };
}

/**
 * The loader step after the instantiation of app.wasm: check the pool
 * against the handshake values of app.wasm, and give it to the imports.
 * On a mismatch the pool stops, and app.wasm uses the Inline executor.
 */
export function attachPool(
  holder: PoolHolder,
  pool: WorkerPool | null,
  appExports: unknown,
  logPrefix = '[chunks]',
): void {
  holder.pool = null;
  if (!pool) return;
  const app = appHandshake(appExports);
  if (!app) {
    // This app.wasm has no chunk pipeline. It does not use the pool.
    pool.stop();
    return;
  }
  if (!pool.verify(app)) {
    console.error(
      `${logPrefix} the chunk worker pool did not start (${pool.error}). The main thread runs the chunk jobs.`,
    );
    pool.stop();
    return;
  }
  holder.pool = pool;
  console.info(`${logPrefix} ${pool.aliveCount} chunk worker(s)`);
}
