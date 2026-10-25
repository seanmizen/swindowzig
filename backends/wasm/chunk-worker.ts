// The chunk worker: one Web Worker of the worker pool (C9).
//
// worker-pool.ts starts this script. The script does these steps:
//   1. It gets the compiled chunks.wasm Module from main ('init'). It makes
//      an instance, and sends the handshake values back ('ready'): the
//      protocol version, the build hash and the build id.
//   2. It gets protocol messages from main ('msg'), in order: Hello, Edit
//      and Job (pipeline/protocol.zig). It gives each message to
//      chunk_worker_handle, and sends each reply to main ('reply') as a
//      transferable ArrayBuffer.
//
// Each job shows in the DevTools Performance panel as a measure named
// 'chunk <stage> <cx>,<cz>' (C12).
//
// This file has no imports, so the dev server can send it as one
// transpiled file, and `bun build` makes one small bundle.

export type ToWorker =
  | { type: 'init'; module: WebAssembly.Module; slot: number }
  | { type: 'msg'; buf: ArrayBuffer }
  // Tests only: the worker throws, as a worker that stops does.
  | { type: 'crash' };

export type FromWorker =
  | {
      type: 'ready';
      protocolVersion: number;
      buildHash: bigint;
      buildId: bigint;
    }
  | { type: 'fail'; message: string }
  | { type: 'reply'; buf: ArrayBuffer };

interface ChunkExports {
  memory: WebAssembly.Memory;
  chunk_worker_alloc: (len: number) => number;
  chunk_worker_free: (ptr: number, len: number) => void;
  chunk_worker_handle: (ptr: number, len: number) => bigint;
  chunk_worker_protocol_version: () => number;
  chunk_worker_build_hash: () => bigint;
  chunk_worker_build_id: () => bigint;
}

const KIND_JOB = 3;
const HEADER_LEN = 16;
const STAGES = ['generate', 'light', 'mesh'];
// Clear the measures after this many jobs, so that the buffer of the
// performance timeline does not grow. DevTools keeps the measures that it
// recorded.
const CLEAR_MEASURES_EVERY = 256;
// No BigInt literals: the minecraft tsconfig targets an older ES version.
const NO_REPLY = BigInt(0);
const SHIFT_32 = BigInt(32);
const LOW_32 = BigInt(0xffffffff);

interface WorkerScope {
  postMessage(message: FromWorker, transfer?: Transferable[]): void;
  onmessage: ((event: MessageEvent<ToWorker>) => void) | null;
}
const scope = self as unknown as WorkerScope;

let wasm: ChunkExports | null = null;
let slot = 0;
let jobs = 0;
const decoder = new TextDecoder();

function instantiate(module: WebAssembly.Module): ChunkExports {
  let memory: WebAssembly.Memory | null = null;
  const env = {
    jsGetTime: (): number => performance.now(),
    jsLog: (ptr: number, len: number): void => {
      if (!memory) return;
      const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
      console.log(`[chunk worker ${slot}] ${text}`);
    },
  };
  const instance = new WebAssembly.Instance(module, { env });
  const exports = instance.exports as unknown as ChunkExports;
  memory = exports.memory;
  return exports;
}

function handle(w: ChunkExports, buf: ArrayBuffer): void {
  const bytes = new Uint8Array(buf);
  const isJob = bytes.length >= HEADER_LEN + 12 && bytes[6] === KIND_JOB;
  let name = '';
  if (isJob) {
    const view = new DataView(buf);
    const stage = STAGES[bytes[HEADER_LEN]] ?? 'stage';
    const cx = view.getInt32(HEADER_LEN + 4, true);
    const cz = view.getInt32(HEADER_LEN + 8, true);
    name = `chunk ${stage} ${cx},${cz}`;
    performance.mark(name);
  }

  const ptr = w.chunk_worker_alloc(bytes.length);
  if (ptr === 0) throw new Error('chunks.wasm has no memory for a message');
  new Uint8Array(w.memory.buffer, ptr, bytes.length).set(bytes);
  const reply = w.chunk_worker_handle(ptr, bytes.length);
  w.chunk_worker_free(ptr, bytes.length);
  if (reply !== NO_REPLY) {
    const rptr = Number(reply >> SHIFT_32);
    const rlen = Number(reply & LOW_32);
    const out = w.memory.buffer.slice(rptr, rptr + rlen);
    w.chunk_worker_free(rptr, rlen);
    scope.postMessage({ type: 'reply', buf: out }, [out]);
  }

  if (isJob) {
    performance.measure(name, name);
    performance.clearMarks(name);
    jobs++;
    if (jobs % CLEAR_MEASURES_EVERY === 0) performance.clearMeasures();
  }
}

scope.onmessage = (event: MessageEvent<ToWorker>): void => {
  const data = event.data;
  switch (data.type) {
    case 'init': {
      slot = data.slot;
      try {
        wasm = instantiate(data.module);
        scope.postMessage({
          type: 'ready',
          protocolVersion: wasm.chunk_worker_protocol_version(),
          buildHash: wasm.chunk_worker_build_hash(),
          buildId: wasm.chunk_worker_build_id(),
        });
      } catch (err) {
        scope.postMessage({
          type: 'fail',
          message: String(err instanceof Error ? err.message : err),
        });
      }
      return;
    }
    case 'msg': {
      // A message before 'init' is a bug in the pool. Throw, so that the
      // pool sees the error and starts the worker again.
      if (!wasm) throw new Error('chunk worker: a message came before init');
      handle(wasm, data.buf);
      return;
    }
    case 'crash':
      throw new Error('chunk worker: crash for a test');
  }
};
