// Headless test of the voxel web build (app.wasm) in Bun. No browser, no GPU.
//
// The test does these steps:
//   1. Make one import for each entry of WebAssembly.Module.imports(module).
//      WebGPU, canvas and audio imports do nothing and return a new handle.
//      The time import reads a clock that this script controls.
//   2. Drive the game with swindowzig_init and swindowzig_frame.
//   3. Wait for the loading screen to stop. Click to capture the mouse.
//      Double-tap Space to fly, rise above the terrain, then hold W until
//      the player is a minimum of 5 chunks from the spawn chunk.
//   4. Read voxel_debug_chunk_counts. Fail if a chunk near the player is
//      missing, or if the chunks around the player have no mesh.
//
// The test finds bugs in the wasm-only code of main.zig. Example: chunks
// that do not load past the spawn ring.
//
// Usage (from utils/swindowzig, after `zig build web -Dexample=voxel`):
//   bun backends/wasm/headless.ts [--wasm zig-out/bin/app.wasm] [--chunks 5]

import { createAssetImports } from './assets';
import { createStorageImports } from './storage';

const FRAME_MS = 1000 / 60;
const KEY_W = 87;
const KEY_SPACE = 32;
const MOUSE_LEFT = 0;

// Limits in frames of simulated time. They stop the test if the game hangs.
const MAX_LOADING_FRAMES = 60 * 120;
const MAX_WALK_FRAMES = 60 * 60;
const RISE_FRAMES = 60 * 3;
const SETTLE_FRAMES = 60 * 3;

// The square of chunks that must be loaded, and the smaller square that
// must be meshed, as a radius in chunks around the player chunk.
const LOADED_RADIUS = 2;
const MESHED_RADIUS = 1;

interface VoxelExports {
  memory: WebAssembly.Memory;
  swindowzig_init: () => void;
  swindowzig_frame: (timestamp: number) => void;
  swindowzig_event_resize: (w: number, h: number, dpi: number) => void;
  swindowzig_event_key: (keycode: number, down: boolean) => void;
  swindowzig_event_mouse_button: (button: number, down: boolean) => void;
  voxel_debug_chunk_counts?: (radius: number) => number;
}

interface ChunkCounts {
  cx: number;
  cz: number;
  loadedNear: number;
  meshedNear: number;
  area: number;
  loadedTotal: number;
  meshedTotal: number;
  loading: boolean;
}

function parseArgs(argv: string[]) {
  const opts = { wasm: 'zig-out/bin/app.wasm', chunks: 5 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[i + 1];
    if (arg === '--wasm' && value) {
      opts.wasm = value;
      i++;
    } else if (arg === '--chunks' && value) {
      opts.chunks = Number(value);
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

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const file = Bun.file(opts.wasm);
  if (!(await file.exists())) {
    fail(`${opts.wasm} does not exist. Run: zig build web -Dexample=voxel`);
  }
  const module = new WebAssembly.Module(await file.arrayBuffer());

  // The controlled clock, in milliseconds. Only this script changes it.
  let nowMs = 0;
  let memory: WebAssembly.Memory | null = null;
  const getMemory = () => {
    if (!memory) throw new Error('wasm memory is not ready');
    return memory;
  };
  const decoder = new TextDecoder();

  // The real imports, where they work in Bun.
  const real: Record<string, Record<string, unknown>> = {
    env: {
      jsGetTime: () => nowMs,
      jsLog: (ptr: number, len: number) => {
        const bytes = new Uint8Array(getMemory().buffer, ptr, len);
        console.log(`wasm: ${decoder.decode(bytes)}`);
      },
      ...createStorageImports(getMemory),
      ...createAssetImports(getMemory),
    },
  };

  // Every other import does nothing and returns a new handle. A handle is
  // never 0, because the Zig side reads 0 as "no object".
  let nextHandle = 1;
  const stub = () => nextHandle++;
  const imports: Record<string, Record<string, unknown>> = {};
  const stubbed: string[] = [];
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.kind !== 'function') {
      fail(`Import ${imp.module}.${imp.name} is a ${imp.kind}, not a function`);
    }
    imports[imp.module] ??= {};
    const fn = real[imp.module]?.[imp.name];
    if (fn) {
      imports[imp.module][imp.name] = fn;
    } else {
      imports[imp.module][imp.name] = stub;
      stubbed.push(`${imp.module}.${imp.name}`);
    }
  }
  console.log(`Stub imports: ${stubbed.length}`);

  const instance = new WebAssembly.Instance(
    module,
    imports as WebAssembly.Imports,
  );
  const wasm = instance.exports as unknown as VoxelExports;
  memory = wasm.memory;
  const debugCounts = wasm.voxel_debug_chunk_counts;
  if (!debugCounts) {
    fail('app.wasm has no voxel_debug_chunk_counts export');
  }

  const counts = (radius: number): ChunkCounts => {
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
  };

  let frames = 0;
  const frame = (n = 1) => {
    for (let i = 0; i < n; i++) {
      nowMs += FRAME_MS;
      frames++;
      wasm.swindowzig_frame(nowMs);
    }
  };
  const seconds = () => (frames * FRAME_MS) / 1000;

  wasm.swindowzig_init();
  wasm.swindowzig_event_resize(1280, 720, 1);

  // 1. Loading screen.
  while (counts(0).loading) {
    if (frames >= MAX_LOADING_FRAMES) {
      fail(`The loading screen did not stop in ${seconds()} s`);
    }
    frame();
  }
  const spawn = counts(LOADED_RADIUS);
  console.log(
    `Loaded at ${seconds().toFixed(1)} s: player chunk (${spawn.cx}, ${spawn.cz}), ` +
      `${spawn.loadedTotal} chunks, ${spawn.meshedTotal} meshed`,
  );

  // 2. Click to capture the mouse. The game moves the player only then.
  wasm.swindowzig_event_mouse_button(MOUSE_LEFT, true);
  frame();
  wasm.swindowzig_event_mouse_button(MOUSE_LEFT, false);
  frame();

  // 3. Double-tap Space to fly, and hold it to rise above the hills.
  wasm.swindowzig_event_key(KEY_SPACE, true);
  frame();
  wasm.swindowzig_event_key(KEY_SPACE, false);
  frame();
  wasm.swindowzig_event_key(KEY_SPACE, true);
  frame(RISE_FRAMES);
  wasm.swindowzig_event_key(KEY_SPACE, false);
  frame();

  // 4. Hold W until the player is far enough from the spawn chunk.
  const start = counts(0);
  const distance = (c: ChunkCounts) =>
    Math.max(Math.abs(c.cx - start.cx), Math.abs(c.cz - start.cz));
  wasm.swindowzig_event_key(KEY_W, true);
  let walkFrames = 0;
  while (distance(counts(0)) < opts.chunks) {
    if (walkFrames >= MAX_WALK_FRAMES) {
      const c = counts(0);
      fail(
        `The player moved ${distance(c)} chunks in ${walkFrames} frames. ` +
          `Expected ${opts.chunks}. Player chunk (${c.cx}, ${c.cz})`,
      );
    }
    frame();
    walkFrames++;
  }
  wasm.swindowzig_event_key(KEY_W, false);
  frame(SETTLE_FRAMES);

  // 5. The area around the player must have chunks and meshes.
  const near = counts(LOADED_RADIUS);
  const inner = counts(MESHED_RADIUS);
  console.log(
    `After ${seconds().toFixed(1)} s: player chunk (${near.cx}, ${near.cz}), ` +
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
  console.log('PASS: chunks load and mesh around the player in app.wasm');
}

main().catch((err) => fail(String(err?.stack ?? err)));
