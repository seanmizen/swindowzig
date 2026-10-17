// Dev page entry point for swindowzig (`yarn voxel:web`). All start-up code
// and every wasm import are in loader.ts.

import { loadWasm } from './loader';

const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
if (!canvas) throw new Error('Canvas not found');

loadWasm({
  canvas,
  wasmUrl: '/app.wasm',
  // The dev server sends these files with Cache-Control: no-cache, so they
  // need no content-hashed names.
  chunkWorkers: { wasmUrl: '/chunks.wasm', workerUrl: '/chunk-worker.js' },
  canvasSize: 'css',
  cursorFollowsLock: true,
}).catch(console.error);
