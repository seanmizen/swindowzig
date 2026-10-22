// The one wasm loader for swindowzig.
//
// Two pages start the wasm: the dev page (backends/wasm/boot.ts) and
// minecraft.seanmizen.com (apps/minecraft.seanmizen.com/src/boot.ts). Each
// page is a thin entry point that calls loadWasm() with its options.
//
// This file builds the full import table. Each wasm import has one
// definition, here or in a module that this file imports. Put a new import
// into createImports() and nowhere else.
//
// The start-up code of the chunk worker pool (C9, C13) is here too. The
// pool starts first, before the fetch of app.wasm and before the loading
// screen (D7).

import { createAssetImports } from './assets';
import { audioImports } from './audio';
import {
  attachEventListeners,
  setPointerLock,
  setTextInputActive,
  type WasmExports,
} from './events';
import { createNetImports } from './net';
import { createStorageImports } from './storage';
import { type GPUBridge, initWebGPU } from './webgpu';
import {
  attachPool,
  chunkImports,
  type PoolHolder,
  WorkerPool,
} from './worker-pool';

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
    // The WebGPU, storage and asset bridges read the wasm memory from here.
    wasmMemory?: WebAssembly.Memory;
    // backends/wasm/debug.html reads this value.
    swindowzigDebug: SwindowzigDebug;
  }
}

/** The step where the start failed. */
export type LoadFailureKind =
  | 'no-webgpu' // navigator.gpu does not exist.
  | 'fetch' // The wasm file did not load (network error or HTTP error).
  | 'webgpu-init' // initWebGPU() threw.
  | 'instantiate' // WebAssembly.instantiate() threw.
  | 'missing-exports' // The wasm has no swindowzig_init or swindowzig_frame.
  | 'init'; // swindowzig_init() threw.

export interface LoadFailure {
  kind: LoadFailureKind;
  /** The error message, or an empty string for 'no-webgpu'. */
  message: string;
  error?: unknown;
}

export interface LoaderOptions {
  canvas: HTMLCanvasElement;
  /** The URL of the wasm file, for example '/app.wasm' or './app.wasm'. */
  wasmUrl: string;
  /** The prefix for console messages, for example '[minecraft]'. */
  logPrefix?: string;
  /**
   * 'css': the canvas size is the window size in CSS pixels.
   * 'device': the canvas size is the window size in device pixels, and the
   * CSS size is the window size.
   */
  canvasSize?: 'css' | 'device';
  /**
   * When true, the canvas shows the cursor while the pointer is not locked,
   * and hides it while the pointer is locked.
   */
  cursorFollowsLock?: boolean;
  /** When true, a click on the canvas requests the pointer lock. */
  lockOnClick?: boolean;
  /** Called one time if the start fails. The default writes to the console. */
  onFailure?: (failure: LoadFailure) => void;
  /** Called immediately before swindowzig_init(). */
  onStart?: () => void;
  /**
   * The chunk worker pool (C9). The URLs must name the files of the same
   * build as the wasm file: use content-hashed names or a version query.
   * Without this option, or when no worker starts, the main thread runs the
   * chunk jobs (the Inline executor).
   */
  chunkWorkers?: {
    /** The URL of chunks.wasm. */
    wasmUrl: string;
    /** The URL of the worker bundle (chunk-worker.js). */
    workerUrl: string;
    /** The number of workers. The default is min(cores - 1, 4). */
    size?: number;
  };
}

type Exports = WasmExports & {
  memory: WebAssembly.Memory;
  swindowzig_config_disable_context_menu?: number;
  swindowzig_config_hide_cursor?: number;
};

function errorMessage(err: unknown): string {
  return String(err instanceof Error ? err.message : err);
}

function emptyDebug(): SwindowzigDebug {
  return {
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
}

/**
 * Build the full import table. The wasm memory does not exist yet, so each
 * import reads it from window.wasmMemory when the import runs.
 */
export function createImports(
  canvas: HTMLCanvasElement,
  gpu: GPUBridge,
  setCursorVisible: (visible: boolean) => void,
  pool: PoolHolder = { pool: null },
): WebAssembly.Imports {
  const getMemory = (): WebAssembly.Memory => {
    if (!window.wasmMemory) throw new Error('wasm memory is not set');
    return window.wasmMemory;
  };

  return {
    env: {
      jsGetTime: (): number => performance.now(),
      ...createStorageImports(getMemory),
      ...createAssetImports(getMemory),
      jsSetPointerLock: (lock: number): void => {
        setPointerLock(canvas, lock !== 0);
        // Hide the cursor at once on lock, before pointerlockchange. Show it
        // at once on unlock: pointerlockchange can come one or two frames
        // late in some browsers.
        setCursorVisible(lock === 0);
      },
      // 1 while the canvas has the pointer lock. A game reads the real
      // state here, so a lock that the browser refused or ended cannot
      // leave the game without the mouse.
      jsPointerLocked: (): number =>
        document.pointerLockElement === canvas ? 1 : 0,
      jsSetTextInput: (active: number): void => {
        setTextInputActive(active !== 0);
      },
      jsLog: (ptr: number, len: number): void => {
        const mem = window.wasmMemory;
        if (!mem) {
          console.log('[wasm log]', ptr, len);
          return;
        }
        const bytes = new Uint8Array(mem.buffer, ptr, len);
        console.log('[wasm]', new TextDecoder().decode(bytes));
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
      ): void => {
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
    // The Zig extern declarations use the module name "webgpu".
    webgpu: gpu.imports,
    audio: audioImports,
    // WebSocket bridge (backends/wasm/net.ts).
    net: createNetImports(getMemory),
    // The chunk worker pool (pipeline/exec_web.zig).
    chunks: chunkImports(pool, getMemory),
  } as WebAssembly.Imports;
}

/**
 * Start the wasm on the canvas. On a failure, call options.onFailure and
 * return. The promise rejects only for an error that has no failure kind.
 */
export async function loadWasm(options: LoaderOptions): Promise<void> {
  const {
    canvas,
    wasmUrl,
    logPrefix = '[swindowzig]',
    canvasSize = 'css',
    cursorFollowsLock = false,
    lockOnClick = false,
  } = options;
  const fail = (kind: LoadFailureKind, error?: unknown): void => {
    const message = error === undefined ? '' : errorMessage(error);
    if (error !== undefined) console.error(`${logPrefix} ${kind}:`, error);
    if (options.onFailure) {
      options.onFailure({ kind, message, error });
    } else if (error === undefined) {
      console.error(`${logPrefix} ${kind}`);
    }
  };

  const resizeCanvas = (): void => {
    if (canvasSize === 'device') {
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.floor(window.innerWidth * dpr);
      canvas.height = Math.floor(window.innerHeight * dpr);
      canvas.style.width = `${window.innerWidth}px`;
      canvas.style.height = `${window.innerHeight}px`;
    } else {
      canvas.width = window.innerWidth;
      canvas.height = window.innerHeight;
    }
  };
  resizeCanvas();
  window.addEventListener('resize', resizeCanvas);

  if (!('gpu' in navigator)) {
    fail('no-webgpu');
    return;
  }

  // D7: start the chunk worker pool first. It compiles chunks.wasm and
  // starts the workers while app.wasm loads. The promise never rejects.
  const poolT0 = performance.now();
  const poolStart = options.chunkWorkers
    ? WorkerPool.start({ ...options.chunkWorkers, logPrefix })
    : null;

  let wasmBytes: ArrayBuffer;
  try {
    const response = await fetch(wasmUrl, { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    wasmBytes = await response.arrayBuffer();
  } catch (err) {
    fail('fetch', err);
    return;
  }

  // The Zig extern calls run synchronously after instantiation, and expect
  // a live device. So initialise WebGPU before instantiation.
  let gpu: GPUBridge;
  try {
    gpu = await initWebGPU(canvas);
  } catch (err) {
    fail('webgpu-init', err);
    return;
  }

  window.swindowzigDebug = emptyDebug();

  const setCursorVisible = (visible: boolean): void => {
    if (cursorFollowsLock) canvas.style.cursor = visible ? 'auto' : 'none';
  };
  if (cursorFollowsLock) {
    // Set canvas.style.cursor here too, so the cursor is correct when
    // requestPointerLock() fails, or when exitPointerLock() is slow.
    document.addEventListener('pointerlockchange', () => {
      setCursorVisible(document.pointerLockElement !== canvas);
    });
    // No pointer lock yet, so show the cursor.
    setCursorVisible(true);
  }

  const poolHolder: PoolHolder = { pool: null };
  let instance: WebAssembly.Instance;
  try {
    const imports = createImports(canvas, gpu, setCursorVisible, poolHolder);
    instance = (await WebAssembly.instantiate(wasmBytes, imports)).instance;
  } catch (err) {
    fail('instantiate', err);
    return;
  }

  const exports = instance.exports as unknown as Exports;
  window.wasmMemory = exports.memory;

  // C9: the pool runs only when each worker has the protocol version, the
  // build hash and the build id of app.wasm. Else the main thread runs the
  // chunk jobs, and the console says why.
  if (poolStart) {
    const pool = await poolStart;
    attachPool(poolHolder, pool, exports, logPrefix);
    performance.measure('chunk worker pool start', { start: poolT0 });
  }

  const init = exports.swindowzig_init;
  const frame = exports.swindowzig_frame;
  if (typeof init !== 'function' || typeof frame !== 'function') {
    console.warn(
      `${logPrefix} wasm has no swindowzig_init or swindowzig_frame export`,
      Object.keys(exports),
    );
    fail('missing-exports');
    return;
  }

  // Config flags from Zig. The defaults suit a game.
  const disableContextMenu =
    (exports.swindowzig_config_disable_context_menu ?? 1) !== 0;
  const hideCursor = (exports.swindowzig_config_hide_cursor ?? 0) !== 0;
  if (hideCursor) canvas.style.cursor = 'none';

  attachEventListeners(canvas, exports, { disableContextMenu });

  if (lockOnClick) {
    canvas.addEventListener('click', () => {
      canvas.requestPointerLock();
    });
  }

  options.onStart?.();

  // Call init() before the first resize event. init() creates the
  // WasmBackend that owns `global_window_info`. Zig ignores a resize event
  // before init(), and the MSAA target then keeps the default size of
  // 1280x720. The order is: init, resize, frame loop.
  try {
    init();
  } catch (err) {
    fail('init', err);
    return;
  }

  // The first frame reads window_info, so send the size before it.
  const notifyResize = exports.swindowzig_event_resize;
  if (notifyResize) {
    const sendSize = (): void => {
      notifyResize(canvas.width, canvas.height, window.devicePixelRatio || 1);
    };
    sendSize();
    window.addEventListener('resize', sendSize);
  }

  const tick = (ts: number): void => {
    try {
      frame(ts);
    } catch (err) {
      console.error(`${logPrefix} swindowzig_frame threw:`, err);
      return;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
