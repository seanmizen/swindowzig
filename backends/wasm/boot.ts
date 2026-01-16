// WASM boot loader for swindowzig

import { attachEventListeners } from './events';
import { initWebGPU } from './webgpu';
import { audioImports } from './audio';

async function main() {
  const canvas = document.getElementById('canvas') as HTMLCanvasElement;
  if (!canvas) throw new Error('Canvas not found');

  // Set canvas to fill window
  const resizeCanvas = () => {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
  };
  resizeCanvas();
  window.addEventListener('resize', resizeCanvas);

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

  // Fire state log collector
  const fireLog: string[] = [];
  (window as any).getFireLog = () => fireLog.join('\n');
  (window as any).downloadFireLog = () => {
    const blob = new Blob([fireLog.join('\n')], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'fire-log.txt';
    a.click();
  };

  // Create WASM imports
  const imports = {
    env: {
      jsGetTime: () => performance.now(),
      jsLog: (ptr: number, len: number) => {
        console.log('WASM log:', ptr, len);
      },
      jsLogFireState: (
        tick: bigint,
        spaceDown: number,
        fired: number,
        cooldown: number,
      ) => {
        fireLog.push(
          `${tick}\t${spaceDown ? 'SPACE' : '-----'}\t${fired ? 'FIRE' : '----'}\t${cooldown.toFixed(4)}`,
        );
      },
      jsSetDebugInfo: (
        tick: bigint,
        shipAlive: number,
        asteroidCount: number,
        score: number,
        fpsVal: number,
        tpsVal: number,
        bulletCount: number,
      ) => {
        (window as any).swindowzigDebug = {
          tick: Number(tick),
          shipAlive: shipAlive !== 0,
          asteroidCount,
          score,
          fps: fpsVal,
          tps: tpsVal,
          bullets: bulletCount,
        };
      },
    },
    gpu: gpu.imports,
    audio: audioImports,
  };

  // Instantiate WASM
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const exports = instance.exports as {
    swindowzig_init: () => void;
    swindowzig_frame: (timestamp: number) => void;
    swindowzig_event_resize: (width: number, height: number, dpiScale: number) => void;
  };

  // Attach DOM event listeners
  attachEventListeners(canvas, exports);

  // Send resize events to Zig
  const notifyResize = () => {
    exports.swindowzig_event_resize(canvas.width, canvas.height, window.devicePixelRatio || 1);
  };
  window.addEventListener('resize', notifyResize);

  // Initialize and send initial size
  exports.swindowzig_init();
  notifyResize();

  // Start frame loop
  function frame(timestamp: number) {
    exports.swindowzig_frame(timestamp);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

main().catch(console.error);
