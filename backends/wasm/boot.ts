// WASM boot loader for swindowzig

import { attachEventListeners } from './events';
import { initWebGPU } from './webgpu';

async function main() {
  const canvas = document.getElementById('canvas') as HTMLCanvasElement;
  if (!canvas) throw new Error('Canvas not found');

  // Set canvas resolution to match game size
  canvas.width = 1280;
  canvas.height = 720;

  // Load WASM
  const response = await fetch('../../zig-out/bin/app.wasm');
  const wasmBytes = await response.arrayBuffer();

  // Initialize WebGPU
  const gpu = await initWebGPU(canvas);

  // Initialize debug global
  (window as any).swindowzigDebug = {
    tick: 0,
    shipAlive: true,
    asteroidCount: 0,
    score: 0,
  };

  // Create WASM imports
  const imports = {
    env: {
      jsGetTime: () => performance.now(),
      jsLog: (ptr: number, len: number) => {
        console.log('WASM log:', ptr, len);
      },
      jsSetDebugInfo: (
        tick: bigint,
        shipAlive: number,
        asteroidCount: number,
        score: number,
      ) => {
        (window as any).swindowzigDebug = {
          tick: Number(tick),
          shipAlive: shipAlive !== 0,
          asteroidCount,
          score,
        };
      },
    },
    gpu: gpu.imports,
  };

  // Instantiate WASM
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const exports = instance.exports as {
    swindowzig_init: () => void;
    swindowzig_frame: (timestamp: number) => void;
  };

  // Attach DOM event listeners
  attachEventListeners(canvas, exports);

  // Initialize
  exports.swindowzig_init();

  // Start frame loop
  function frame(timestamp: number) {
    exports.swindowzig_frame(timestamp);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

main().catch(console.error);
