// The frame graph on the web canvas (REQ-GPU-012). The test opens justabox,
// which draws through the sw_render frame graph and the post chain (HDR
// target, tonemap, FXAA). It reads the canvas pixels two times. It checks
// these items:
//
// - The box is on the canvas, and the box turns.
// - The console has no WebGPU error.
// - The bridge does not keep a handle from each frame.

import { expect, type Page, test } from '@playwright/test';

/** The time that the test watches the example, in milliseconds. */
const watchMs = 10_000;

/** The number of canvas samples that the test compares. */
const gridW = 64;
const gridH = 36;

interface CanvasPixels {
  /** The fraction of pixels that have a channel brighter than 64. */
  lit: number;
  /** The colour bytes of gridW x gridH samples of the canvas. */
  grid: number[];
}

/**
 * The test hooks of the page. The init script (`instrument`) sets them
 * before the loader runs.
 */
interface Hooks {
  swCanvasFrames: number;
  swReadCanvas: () => Promise<CanvasPixels>;
}

/**
 * Count the canvas frames, and read the canvas texture of a frame back from
 * the GPU. The read copies the texture after the submit of the frame, in the
 * same task, before the browser shows it. So the test reads what the frame
 * graph wrote, and not the screenshot of the compositor (the Linux headless
 * shell gives a black screenshot of a WebGPU canvas).
 */
function instrument(grid: { w: number; h: number }): void {
  const hooks = window as unknown as Hooks;
  hooks.swCanvasFrames = 0;
  let device: GPUDevice | null = null;
  let current: GPUTexture | null = null;
  let waiting: ((p: CanvasPixels) => void) | null = null;

  const configure = GPUCanvasContext.prototype.configure;
  GPUCanvasContext.prototype.configure = function (c) {
    device = c.device;
    const usage =
      (c.usage ?? GPUTextureUsage.RENDER_ATTACHMENT) | GPUTextureUsage.COPY_SRC;
    return configure.call(this, { ...c, usage });
  };
  const get = GPUCanvasContext.prototype.getCurrentTexture;
  GPUCanvasContext.prototype.getCurrentTexture = function () {
    const t = get.call(this);
    if (t !== current) hooks.swCanvasFrames++;
    current = t;
    return t;
  };
  hooks.swReadCanvas = () =>
    new Promise((resolve) => {
      waiting = resolve;
    });

  const submit = GPUQueue.prototype.submit;
  GPUQueue.prototype.submit = function (buffers) {
    submit.call(this, buffers);
    const resolve = waiting;
    const tex = current;
    if (!resolve || !tex || !device) return;
    waiting = null;
    const w = tex.width;
    const h = tex.height;
    const bytesPerRow = Math.ceil((w * 4) / 256) * 256;
    const buffer = device.createBuffer({
      size: bytesPerRow * h,
      usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    });
    const encoder = device.createCommandEncoder();
    encoder.copyTextureToBuffer(
      { texture: tex },
      { buffer, bytesPerRow },
      { width: w, height: h },
    );
    submit.call(this, [encoder.finish()]);
    buffer.mapAsync(GPUMapMode.READ).then(() => {
      const data = new Uint8Array(buffer.getMappedRange());
      let lit = 0;
      for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
          const i = y * bytesPerRow + x * 4;
          if (Math.max(data[i], data[i + 1], data[i + 2]) > 64) lit++;
        }
      }
      const cells: number[] = [];
      for (let gy = 0; gy < grid.h; gy++) {
        for (let gx = 0; gx < grid.w; gx++) {
          const x = Math.floor(((gx + 0.5) * w) / grid.w);
          const y = Math.floor(((gy + 0.5) * h) / grid.h);
          const i = y * bytesPerRow + x * 4;
          cells.push(data[i], data[i + 1], data[i + 2]);
        }
      }
      buffer.unmap();
      buffer.destroy();
      resolve({ lit: lit / (w * h), grid: cells });
    });
  };
}

/** Read the canvas texture of the next frame. */
async function readCanvas(page: Page): Promise<CanvasPixels> {
  return page.evaluate(() => (window as unknown as Hooks).swReadCanvas());
}

/** The number of grid cells that changed between two reads. */
function changedCells(a: CanvasPixels, b: CanvasPixels): number {
  let changed = 0;
  for (let i = 0; i < a.grid.length; i += 3) {
    const d =
      Math.abs(a.grid[i] - b.grid[i]) +
      Math.abs(a.grid[i + 1] - b.grid[i + 1]) +
      Math.abs(a.grid[i + 2] - b.grid[i + 2]);
    if (d > 24) changed++;
  }
  return changed;
}

async function gpuHandles(page: Page): Promise<number> {
  return page.evaluate(() =>
    (
      window as unknown as { swindowzigGpuHandles: () => number }
    ).swindowzigGpuHandles(),
  );
}

test('justabox draws the spinning box on the canvas', async ({ page }) => {
  const logs: string[] = [];
  const gpuErrors: string[] = [];
  page.on('console', (m) => {
    const text = m.text();
    logs.push(`${m.type()}: ${text}`);
    if (text.startsWith('[WebGPU] error') || text.includes('is invalid')) {
      gpuErrors.push(text);
    }
  });
  page.on('pageerror', (e) => {
    logs.push(`pageerror: ${e.message}`);
    gpuErrors.push(`pageerror: ${e.message}`);
  });
  await page.addInitScript(instrument, { w: gridW, h: gridH });
  const frames = () =>
    page.evaluate(() => (window as unknown as Hooks).swCanvasFrames);
  let framesNow = 0;
  const dump = () =>
    `\nCanvas frames: ${framesNow}\nConsole:\n${logs.join('\n')}`;

  await page.goto('/');
  // With no WebGPU, justabox draws nothing. The console then tells why.
  await expect
    .poll(() => logs.some((l) => l.includes('justabox: GPU ready')), {
      timeout: 30_000,
      message: `justabox did not start.${dump()}`,
    })
    .toBe(true);

  // Some frames go through the frame graph before the first read.
  await page.waitForTimeout(1_000);
  const handlesBefore = await gpuHandles(page);
  const first = await readCanvas(page);
  await page.waitForTimeout(watchMs);
  const second = await readCanvas(page);
  const handlesAfter = await gpuHandles(page);
  framesNow = await frames();

  expect(gpuErrors, `WebGPU errors in the console.${dump()}`).toEqual([]);
  expect(
    framesNow,
    `the frame graph drew few frames.${dump()}`,
  ).toBeGreaterThan(10);

  // The box is on the canvas: the canvas is not all black, and not one
  // colour. The faces are bright and the background is dark.
  expect(first.lit, `the canvas has no box.${dump()}`).toBeGreaterThan(0.01);
  expect(first.lit, `the canvas is all bright.${dump()}`).toBeLessThan(0.5);
  expect(second.lit, `the box went away.${dump()}`).toBeGreaterThan(0.01);

  // The box turns, so the frames after the first frame also go to the
  // canvas.
  expect(
    changedCells(first, second),
    `the canvas did not change in ${watchMs} ms.${dump()}`,
  ).toBeGreaterThan(5);

  // Each frame gets a canvas texture, a command encoder, passes and a
  // command buffer. The bridge drops all of them after the submit.
  expect(
    handlesAfter - handlesBefore,
    `the WebGPU bridge keeps ${handlesAfter - handlesBefore} more handles after ${watchMs} ms`,
  ).toBeLessThan(16);
});
