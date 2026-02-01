// WASM boot loader for swindowzig

import { audioImports } from './audio';
import { attachEventListeners } from './events';
import { initWebGPU } from './webgpu';

// Type definitions
export interface SwindowzigDebug {
  tick: number;
  dt_ns: number;
  time_ns: number;
  window: { width: number; height: number; dpi_scale: number };
  mouse: { x: number; y: number; dx: number; dy: number };
  buttons: { left: boolean; right: boolean; middle: boolean };
  keys: { pressed: number; down: number; released: number };
  mods: { ctrl: boolean; shift: boolean; alt: boolean; super: boolean };
  wheel: { dx: number; dy: number };
  text_len: number;
  fps: number;
}

declare global {
  interface Window {
    swindowzigDebug: SwindowzigDebug;
  }
}

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
  window.swindowzigDebug = {
    tick: 0,
    dt_ns: 0,
    time_ns: 0,
    window: { width: 0, height: 0, dpi_scale: 1 },
    mouse: { x: 0, y: 0, dx: 0, dy: 0 },
    buttons: { left: false, right: false, middle: false },
    keys: { pressed: 0, down: 0, released: 0 },
    mods: { ctrl: false, shift: false, alt: false, super: false },
    wheel: { dx: 0, dy: 0 },
    text_len: 0,
    fps: 0,
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
        dt_ns: bigint,
        time_ns: bigint,
        width: number,
        height: number,
        dpi: number,
        mouse_x: number,
        mouse_y: number,
        mouse_dx: number,
        mouse_dy: number,
        btn_left: number,
        btn_right: number,
        btn_middle: number,
        keys_pressed: number,
        keys_down: number,
        keys_released: number,
        mod_ctrl: number,
        mod_shift: number,
        mod_alt: number,
        mod_super: number,
        wheel_dx: number,
        wheel_dy: number,
        text_len: number,
        fps_val: number,
      ) => {
        window.swindowzigDebug = {
          tick: Number(tick),
          dt_ns: Number(dt_ns),
          time_ns: Number(time_ns),
          window: { width, height, dpi_scale: dpi },
          mouse: { x: mouse_x, y: mouse_y, dx: mouse_dx, dy: mouse_dy },
          buttons: {
            left: btn_left !== 0,
            right: btn_right !== 0,
            middle: btn_middle !== 0,
          },
          keys: {
            pressed: keys_pressed,
            down: keys_down,
            released: keys_released,
          },
          mods: {
            ctrl: mod_ctrl !== 0,
            shift: mod_shift !== 0,
            alt: mod_alt !== 0,
            super: mod_super !== 0,
          },
          wheel: { dx: wheel_dx, dy: wheel_dy },
          text_len,
          fps: fps_val,
        };
      },
    },
    webgpu: gpu.imports, // Changed from "gpu" to "webgpu" to match Zig extern declarations
    audio: audioImports,
  };

  // Instantiate WASM
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const exports = instance.exports;

  // Expose WASM memory to window for WebGPU bridge access
  (window as never as { wasmMemory: WebAssembly.Memory }).wasmMemory =
    exports.memory as WebAssembly.Memory;

  // Read config from WASM exports (available immediately after instantiation)
  // These are exported as u8 constants from Zig
  const disableContextMenu =
    ((exports.swindowzig_config_disable_context_menu as number | undefined) ??
      1) !== 0;
  const hideCursor =
    ((exports.swindowzig_config_hide_cursor as number | undefined) ?? 0) !== 0;

  // Apply cursor visibility
  if (hideCursor) {
    canvas.style.cursor = 'none';
  }

  // Cast exports for type safety
  const wasmFunctions = exports as unknown as {
    swindowzig_init: () => void;
    swindowzig_frame: (timestamp: number) => void;
    swindowzig_event_resize: (
      width: number,
      height: number,
      dpiScale: number,
    ) => void;
  };

  // Attach DOM event listeners with config
  attachEventListeners(canvas, wasmFunctions, {
    disableContextMenu,
  });

  // Send resize events to Zig
  const notifyResize = () => {
    wasmFunctions.swindowzig_event_resize(
      canvas.width,
      canvas.height,
      window.devicePixelRatio || 1,
    );
  };
  window.addEventListener('resize', notifyResize);

  // Initialize and send initial size
  wasmFunctions.swindowzig_init();
  notifyResize();

  // Start frame loop
  function frame(timestamp: number) {
    wasmFunctions.swindowzig_frame(timestamp);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

main().catch(console.error);
