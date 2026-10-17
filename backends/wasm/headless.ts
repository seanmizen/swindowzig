// Headless test of the voxel web build (app.wasm) in Bun. No browser, no GPU.
//
// The test does these steps:
//   1. Start app.wasm with headless-app.ts: stub WebGPU imports, and the
//      real chunk worker pool (real Bun Web Workers that run chunks.wasm).
//      `--workers 0` starts no pool: the Inline executor runs the jobs.
//   2. Wait for the loading screen to stop. Click to capture the mouse.
//      Double-tap Space to fly, rise above the terrain, then hold W until
//      the player is a minimum of 5 chunks from the spawn chunk.
//   3. Read voxel_debug_chunk_counts. Fail if a chunk near the player is
//      missing, or if the chunks around the player have no mesh.
//   4. With the pool: fail if a chunk job ran on the main thread. Only the
//      simulation radius can generate chunks inline (C6).
//
// The test finds bugs in the wasm-only code of main.zig. Example: chunks
// that do not load past the spawn ring.
//
// `--measure` uses the real clock and runs 60 frames per second, as a
// browser does. It prints the main-thread time of the frames during the
// load and during the walk, and the load times.
//
// Usage (from utils/swindowzig, after `zig build web -Dexample=voxel`):
//   bun backends/wasm/headless.ts [--wasm zig-out/bin/app.wasm] [--chunks 5]
//       [--workers auto|0|N] [--measure]
//       [--chunks-wasm <path>] [--worker <path of the worker script>]
// The last two test the production files of bundle.sh, for example
// public/chunks-<hash>.wasm and public/chunk-worker-<hash>.js.

import {
  type ChunkCounts,
  FRAME_MS,
  type HeadlessApp,
  startApp,
  yieldToEventLoop,
} from './headless-app';

const KEY_W = 87;
const KEY_SPACE = 32;
const MOUSE_LEFT = 0;

// Limits in frames. They stop the test if the game hangs.
const MAX_LOADING_FRAMES = 60 * 120;
const MAX_WALK_FRAMES = 60 * 60;
const MAX_SETTLE_FRAMES = 60 * 60;
const RISE_FRAMES = 60 * 3;
const SETTLE_FRAMES = 60 * 3;

// The square of chunks that must be loaded, and the smaller square that
// must be meshed, as a radius in chunks around the player chunk.
const LOADED_RADIUS = 2;
const MESHED_RADIUS = 1;

interface Options {
  wasm: string;
  chunks: number;
  workers: 'auto' | number;
  measure: boolean;
  chunksWasm?: string;
  worker?: string;
}

function parseArgs(argv: string[]): Options {
  const opts: Options = {
    wasm: 'zig-out/bin/app.wasm',
    chunks: 5,
    workers: 'auto',
    measure: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[i + 1];
    if (arg === '--wasm' && value) {
      opts.wasm = value;
      i++;
    } else if (arg === '--chunks' && value) {
      opts.chunks = Number(value);
      i++;
    } else if (arg === '--workers' && value) {
      opts.workers = value === 'auto' ? 'auto' : Number(value);
      i++;
    } else if (arg === '--measure') {
      opts.measure = true;
    } else if (arg === '--chunks-wasm' && value) {
      opts.chunksWasm = value;
      i++;
    } else if (arg === '--worker' && value) {
      opts.worker = Bun.pathToFileURL(value).href;
      i++;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

function fail(message: string): never {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function percentile(values: number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[
    Math.min(sorted.length - 1, Math.floor(((sorted.length - 1) * p) / 100))
  ];
}

function summary(name: string, ms: number[]): string {
  return (
    `${name}: ${ms.length} frames, main ms p50 ${percentile(ms, 50).toFixed(2)} ` +
    `p95 ${percentile(ms, 95).toFixed(2)} p99 ${percentile(ms, 99).toFixed(2)} ` +
    `max ${Math.max(0, ...ms).toFixed(2)}`
  );
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const usePool = opts.workers !== 0;
  const t0 = performance.now();
  const app: HeadlessApp = await startApp({
    wasm: opts.wasm,
    pool: usePool
      ? {
          size: opts.workers === 'auto' ? undefined : opts.workers,
          chunksPath: opts.chunksWasm,
          workerUrl: opts.worker,
        }
      : null,
    clock: opts.measure ? 'real' : 'sim',
  });
  const startMs = performance.now() - t0;
  const pool = app.pool;
  if (pool && pool.aliveCount === 0)
    fail(`No chunk worker started: ${pool.error}`);
  console.log(
    pool
      ? `WorkerPool: ${pool.aliveCount} of ${pool.size} workers run`
      : 'No worker pool: the Inline executor runs the chunk jobs',
  );

  // Each frame of a --measure run lasts FRAME_MS of real time, as in a
  // browser. Else frames run at once, with a yield for the worker messages.
  let next = performance.now();
  const frameTimes: number[] = [];
  const step = async (n = 1): Promise<void> => {
    for (let i = 0; i < n; i++) {
      frameTimes.push(app.frame());
      if (opts.measure) {
        next += FRAME_MS;
        await yieldToEventLoop(Math.max(0, next - performance.now()));
      } else if (pool) {
        await yieldToEventLoop();
      }
    }
  };
  const counts = (r: number) => app.counts(r);

  // 1. Loading screen.
  while (counts(0).loading) {
    if (app.frameCount() >= MAX_LOADING_FRAMES) {
      fail(`The loading screen did not stop in ${app.frameCount()} frames`);
    }
    await step();
  }
  const loadMs = performance.now() - t0;
  const loadFrames = frameTimes.splice(0);
  const spawn = counts(LOADED_RADIUS);
  console.log(
    `Loaded after ${app.frameCount()} frames: player chunk (${spawn.cx}, ${spawn.cz}), ` +
      `${spawn.loadedTotal} chunks, ${spawn.meshedTotal} meshed`,
  );

  // 2. Click to capture the mouse. The game moves the player only then.
  app.mouse(MOUSE_LEFT, true);
  await step();
  app.mouse(MOUSE_LEFT, false);
  await step();

  // 3. Double-tap Space to fly, and hold it to rise above the hills.
  app.key(KEY_SPACE, true);
  await step();
  app.key(KEY_SPACE, false);
  await step();
  app.key(KEY_SPACE, true);
  await step(RISE_FRAMES);
  app.key(KEY_SPACE, false);
  await step();
  const riseFrames = frameTimes.splice(0);

  // 4. Hold W until the player is far enough from the spawn chunk.
  const start = counts(0);
  const distance = (c: ChunkCounts) =>
    Math.max(Math.abs(c.cx - start.cx), Math.abs(c.cz - start.cz));
  app.key(KEY_W, true);
  let walkFrames = 0;
  while (distance(counts(0)) < opts.chunks) {
    if (walkFrames >= MAX_WALK_FRAMES) {
      const c = counts(0);
      fail(
        `The player moved ${distance(c)} chunks in ${walkFrames} frames. ` +
          `Expected ${opts.chunks}. Player chunk (${c.cx}, ${c.cz})`,
      );
    }
    await step();
    walkFrames++;
  }
  app.key(KEY_W, false);
  const walkTimes = frameTimes.splice(0);
  await step(SETTLE_FRAMES);

  // With the pool, the workers can need more frames than the simulated
  // clock gives them. Wait until the scheduler is idle.
  let settle = 0;
  while (pool && !app.pipeline()?.idle) {
    if (settle >= MAX_SETTLE_FRAMES)
      fail('The chunk scheduler did not become idle');
    await step();
    settle++;
  }
  const idleMs = performance.now() - t0;

  // 5. The area around the player must have chunks and meshes.
  const near = counts(LOADED_RADIUS);
  const inner = counts(MESHED_RADIUS);
  console.log(
    `After ${app.frameCount()} frames: player chunk (${near.cx}, ${near.cz}), ` +
      `${distance(near)} chunks from the start`,
  );
  console.log(
    `  radius ${LOADED_RADIUS}: ${near.loadedNear}/${near.area} loaded, ` +
      `${near.meshedNear} meshed`,
  );
  console.log(
    `  radius ${MESHED_RADIUS}: ${inner.loadedNear}/${inner.area} loaded, ` +
      `${inner.meshedNear}/${inner.area} meshed`,
  );
  console.log(
    `  world: ${near.loadedTotal} loaded, ${near.meshedTotal} meshed`,
  );

  if (near.loadedNear < near.area) {
    fail(
      `${near.area - near.loadedNear} of ${near.area} chunks near the ` +
        'player are not loaded. Chunks do not load past the spawn ring.',
    );
  }
  if (inner.meshedNear < inner.area) {
    fail(
      `${inner.area - inner.meshedNear} of ${inner.area} chunks around the ` +
        'player have no mesh.',
    );
  }

  // 6. With the pool, no chunk stage runs on the main thread, except the
  // simulation radius (C6, C9).
  const p = app.pipeline();
  if (p) {
    console.log(
      `Pipeline: executor ${p.executor}, ${p.workers} workers, ${p.workerJobs} worker jobs, ` +
        `${p.mainJobs} main-thread jobs, ${p.simGenerated} simulation-radius chunks inline, ` +
        `${p.installed} installed, ${p.discarded} discarded, ${p.fallbacks} fallbacks`,
    );
    if (pool && pool.aliveCount > 0) {
      if (p.executor !== 'web')
        fail('The pool runs, but app.wasm uses the Inline executor');
      if (p.mainJobs !== 0)
        fail(`${p.mainJobs} chunk jobs ran on the main thread`);
      if (p.workerJobs === 0) fail('No chunk job went to a worker');
    }
  }

  if (opts.measure) {
    console.log(`Start (pool and app.wasm): ${startMs.toFixed(0)} ms`);
    console.log(`Loading screen: ${loadMs.toFixed(0)} ms`);
    console.log(`Full desired state after the walk: ${idleMs.toFixed(0)} ms`);
    console.log(summary('Load', loadFrames));
    console.log(summary('Rise', riseFrames));
    console.log(summary('Walk', walkTimes));
    console.log(summary('Settle', frameTimes));
  }
  app.stop();
  console.log('PASS: chunks load and mesh around the player in app.wasm');
  process.exit(0);
}

main().catch((err) => fail(String(err?.stack ?? err)));
