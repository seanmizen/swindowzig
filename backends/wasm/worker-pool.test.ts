// Bun tests of the chunk worker pool with real Web Workers (C9, C11).
//
// Each test runs the voxel web build (app.wasm) headless (headless-app.ts),
// and compares the final state with a run of the Inline executor. The state
// is voxel_debug_world_hash: the block versions, the light hashes, the
// meshes and the blocks of the desired state around the player. The tests:
//
//   equivalence  the WorkerPool gives the hash of the Inline executor, with
//                random edits while jobs run. No chunk job runs on the main
//                thread. Only the simulation radius can generate inline (C6).
//   restart      a worker that stops during the load starts again. The pool
//                sends its jobs again, and the hash does not change.
//   fallback     no worker starts (the Worker constructor throws), or all
//                workers stop during the load: the Inline executor runs the
//                jobs, and the hash does not change.
//   mismatch     a worker from another build (protocol version, build hash
//                or build id) does not start, with a clear error. The Inline
//                executor runs the jobs, so the terrain is correct.
//
// Usage (from utils/swindowzig, after `zig build web -Dexample=voxel`):
//   bun test backends/wasm/worker-pool.test.ts
// The tests use zig-out/bin/app.wasm and zig-out/bin/chunks.wasm. Set
// VOXEL_WASM to use another app.wasm.

import { describe, expect, test } from 'bun:test';
import {
  type HeadlessApp,
  type PipelineCounts,
  type PoolSetup,
  startApp,
} from './headless-app';
import { defaultPoolSize, MAX_WORKERS, WorkerPool } from './worker-pool';

const WASM = process.env.VOXEL_WASM ?? 'zig-out/bin/app.wasm';
const CHUNKS = WASM.replace(/app\.wasm$/, 'chunks.wasm');
const TIMEOUT_MS = 120_000;
const MAX_FRAMES = 20_000;
const CHUNK_W = 16;
const BLOCK_AIR = 0;
const BLOCK_STONE = 3;
const BLOCK_GLOWSTONE = 5;

interface Edit {
  dcx: number;
  dcz: number;
  x: number;
  y: number;
  z: number;
  block: number;
}

/** A small seeded random generator (mulberry32). */
function random(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Random edits in the simulation radius, often at a chunk border. */
function makeEdits(seed: number, n: number): Edit[] {
  const r = random(seed);
  const pick = <T>(xs: T[]): T => xs[Math.floor(r() * xs.length)];
  const edge = [0, 1, 2, 7, 13, 14, 15];
  const out: Edit[] = [];
  for (let i = 0; i < n; i++) {
    out.push({
      dcx: pick([-1, 0, 1]),
      dcz: pick([-1, 0, 1]),
      x: pick(edge),
      y: 55 + Math.floor(r() * 36),
      z: Math.floor(r() * CHUNK_W),
      block: pick([BLOCK_AIR, BLOCK_AIR, BLOCK_STONE, BLOCK_GLOWSTONE]),
    });
  }
  return out;
}

interface Outcome {
  hash: bigint;
  cx: number;
  cz: number;
  pipeline: PipelineCounts;
  /** The pool counters at the end of the run, before the pool stops. */
  pool: { alive: number; restarts: number; error: string | null } | null;
  editsWhileJobsRan: number;
}

/**
 * Start app.wasm, wait for the loading screen to stop, then make `edits`
 * over some frames. Wait until the scheduler is idle. `onFrame` can make a
 * fault (for example a worker that stops).
 */
async function run(
  pool: PoolSetup | null,
  edits: Edit[],
  onFrame?: (app: HeadlessApp, frame: number) => void,
): Promise<Outcome> {
  const app = await startApp({ wasm: WASM, pool, clock: 'sim' });
  try {
    let frame = 0;
    const step = async () => {
      onFrame?.(app, frame);
      frame++;
      if (frame > MAX_FRAMES) throw new Error('the run did not finish');
      await app.frames(1);
    };
    while (app.counts(0).loading) await step();
    const c = app.counts(0);
    let editsWhileJobsRan = 0;
    for (const [i, e] of edits.entries()) {
      if ((app.pipeline()?.inFlight ?? 0) > 0) editsWhileJobsRan++;
      const ok = app.edit(
        (c.cx + e.dcx) * CHUNK_W + e.x,
        e.y,
        (c.cz + e.dcz) * CHUNK_W + e.z,
        e.block,
      );
      expect(ok).toBe(true);
      for (let k = 0; k < 1 + (i % 3); k++) await step();
    }
    let hash = 0n;
    while (true) {
      const p = app.pipeline();
      if (p?.idle) {
        hash = app.worldHash();
        if (hash !== 0n) break;
      }
      await step();
    }
    const end = app.counts(0);
    const pipeline = app.pipeline();
    if (!pipeline)
      throw new Error('app.wasm has no voxel_debug_pipeline_counts');
    return {
      hash,
      cx: end.cx,
      cz: end.cz,
      pipeline,
      pool: app.pool
        ? {
            alive: app.pool.aliveCount,
            restarts: app.pool.restarts,
            error: app.pool.error,
          }
        : null,
      editsWhileJobsRan,
    };
  } finally {
    app.stop();
  }
}

const EDITS = makeEdits(0x709, 40);
let reference: Outcome | null = null;

/** The Inline executor with the same edits: the expected state. */
async function inlineReference(): Promise<Outcome> {
  reference ??= await run(null, EDITS);
  return reference;
}

function expectSameState(a: Outcome, b: Outcome): void {
  expect(a.cx).toBe(b.cx);
  expect(a.cz).toBe(b.cz);
  expect(a.hash.toString(16)).toBe(b.hash.toString(16));
}

/** The acceptance check: no chunk stage ran on the main thread (C9). */
function expectWorkersOnly(o: Outcome): void {
  expect(o.pipeline.executor).toBe('web');
  expect(o.pipeline.mainJobs).toBe(0);
  expect(o.pipeline.workerJobs).toBeGreaterThan(1000);
  expect(o.pipeline.fallbacks).toBe(0);
  expect(o.pipeline.badReplies).toBe(0);
  // The simulation radius is 3 × 3 chunks. Only it can generate inline.
  expect(o.pipeline.simGenerated).toBeLessThanOrEqual(9);
}

describe('chunk worker pool (real Bun Web Workers)', () => {
  test('the build has app.wasm and chunks.wasm', async () => {
    expect(await Bun.file(WASM).exists()).toBe(true);
    expect(await Bun.file(CHUNKS).exists()).toBe(true);
    const size = defaultPoolSize();
    expect(size).toBeGreaterThanOrEqual(1);
    expect(size).toBeLessThanOrEqual(MAX_WORKERS);
  });

  test(
    'the world hash sees the edits: a run with no edits has another hash',
    async () => {
      const ref = await inlineReference();
      const plain = await run(null, []);
      expect(plain.hash).not.toBe(0n);
      expect(plain.hash.toString(16)).not.toBe(ref.hash.toString(16));
    },
    TIMEOUT_MS,
  );

  test(
    'equivalence: the WorkerPool gives the state of the Inline executor, with random edits while jobs run',
    async () => {
      const ref = await inlineReference();
      expect(ref.pipeline.executor).toBe('inline');
      expect(ref.pipeline.mainJobs).toBeGreaterThan(1000);

      for (const size of [3, 1, 4]) {
        const o = await run({ size }, EDITS);
        expect(o.pool?.alive).toBe(size);
        expectWorkersOnly(o);
        expect(o.editsWhileJobsRan).toBeGreaterThan(5);
        expectSameState(o, ref);
      }
    },
    TIMEOUT_MS,
  );

  test(
    'restart: a worker that stops during the load starts again, and its jobs run',
    async () => {
      const ref = await inlineReference();
      const o = await run({ size: 3 }, EDITS, (app, frame) => {
        if (frame === 3) app.pool?.crash(0);
        if (frame === 10) app.pool?.crash(1);
        if (frame === 40) app.pool?.crash(2);
      });
      expect(o.pool?.restarts).toBeGreaterThanOrEqual(3);
      expect(o.pool?.alive).toBe(3);
      expectWorkersOnly(o);
      expectSameState(o, ref);
    },
    TIMEOUT_MS,
  );

  test(
    'fallback: when the Worker constructor throws, the Inline executor runs the jobs',
    async () => {
      const ref = await inlineReference();
      const o = await run(
        {
          size: 3,
          createWorker: () => {
            throw new Error('no workers in this test');
          },
        },
        EDITS,
      );
      expect(o.pool?.alive).toBe(0);
      expect(o.pool?.error).toContain('the worker did not start');
      expect(o.pipeline.executor).toBe('inline');
      expect(o.pipeline.workerJobs).toBe(0);
      expect(o.pipeline.mainJobs).toBeGreaterThan(1000);
      expectSameState(o, ref);
    },
    TIMEOUT_MS,
  );

  test(
    'fallback: when all workers stop during the load, the Inline executor takes the jobs',
    async () => {
      const ref = await inlineReference();
      const o = await run({ size: 2, maxRestarts: 0 }, EDITS, (app, frame) => {
        if (frame === 5) app.pool?.crash(0);
        if (frame === 15) app.pool?.crash(1);
      });
      expect(o.pool?.alive).toBe(0);
      expect(o.pipeline.fallbacks).toBe(1);
      expect(o.pipeline.executor).toBe('inline');
      // The workers ran jobs before they stopped.
      expect(o.pipeline.workerJobs).toBeGreaterThan(0);
      expectSameState(o, ref);
    },
    TIMEOUT_MS,
  );

  for (const [field, override] of [
    ['build id', { buildId: 0x1234n }],
    ['build hash', { buildHash: 0x5678n }],
    ['protocol version', { protocolVersion: 99 }],
  ] as const) {
    test(
      `mismatch: a chunks.wasm with another ${field} does not start, and the terrain is correct`,
      async () => {
        const ref = await inlineReference();
        const logged: string[] = [];
        const error = console.error;
        console.error = (...args: unknown[]) => logged.push(args.join(' '));
        let o: Outcome;
        try {
          o = await run({ size: 2, appHandshake: override }, EDITS);
        } finally {
          console.error = error;
        }
        expect(o.pool?.alive).toBe(0);
        expect(o.pool?.error).toContain(field);
        expect(o.pool?.error).toContain('A cached old file?');
        expect(logged.join('\n')).toContain(
          'The main thread runs the chunk jobs',
        );
        expect(o.pipeline.executor).toBe('inline');
        expect(o.pipeline.workerJobs).toBe(0);
        expectSameState(o, ref);
      },
      TIMEOUT_MS,
    );
  }

  test(
    'serve: the pool compiles chunks.wasm over HTTP, and an old file name gives a clear error',
    async () => {
      // As `serve -s` does: a file that is not there gives index.html.
      const server = Bun.serve({
        port: 0,
        fetch(req) {
          const path = new URL(req.url).pathname;
          if (path === '/chunks-new.wasm') {
            return new Response(Bun.file(CHUNKS), {
              headers: { 'Content-Type': 'application/wasm' },
            });
          }
          return new Response('<!doctype html><title>index</title>', {
            headers: { 'Content-Type': 'text/html' },
          });
        },
      });
      const workerUrl = new URL('./chunk-worker.ts', import.meta.url).href;
      const error = console.error;
      console.error = () => {};
      try {
        const good = await WorkerPool.start({
          wasmUrl: `${server.url}chunks-new.wasm`,
          workerUrl,
          size: 2,
        });
        expect(good.aliveCount).toBe(2);
        good.stop();
        // A cached old boot.js asks for the chunks.wasm of its own build.
        const stale = await WorkerPool.start({
          wasmUrl: `${server.url}chunks-old.wasm`,
          workerUrl,
          size: 2,
        });
        expect(stale.aliveCount).toBe(0);
        expect(stale.error).toContain('chunks.wasm did not compile');
        stale.stop();
      } finally {
        console.error = error;
        server.stop(true);
      }
    },
    TIMEOUT_MS,
  );

  test(
    'mismatch: a worker refuses a Hello from another build, and the slot stops',
    async () => {
      const module = new WebAssembly.Module(
        await Bun.file(CHUNKS).arrayBuffer(),
      );
      const pool = await WorkerPool.start({
        module,
        workerUrl: new URL('./chunk-worker.ts', import.meta.url).href,
        size: 2,
        logPrefix: '[test]',
      });
      try {
        expect(pool.aliveCount).toBe(2);
        // A Hello (protocol.zig): the header, then the build hash first.
        const hello = new Uint8Array(16 + 56);
        const view = new DataView(hello.buffer);
        view.setUint32(0, 0x50435856, true); // "VXCP"
        view.setUint16(4, 1, true); // protocol version
        hello[6] = 1; // kind: Hello
        view.setUint32(8, 56, true);
        view.setBigUint64(16, 0x0badn, true); // a build hash of no build
        const error = console.error;
        console.error = () => {};
        try {
          pool.broadcast(hello);
          for (let i = 0; i < 200 && pool.aliveCount > 0; i++) {
            await new Promise((r) => setTimeout(r, 5));
          }
        } finally {
          console.error = error;
        }
        expect(pool.aliveCount).toBe(0);
        expect(pool.error).toContain('refused the Hello');
      } finally {
        pool.stop();
      }
    },
    TIMEOUT_MS,
  );
});
