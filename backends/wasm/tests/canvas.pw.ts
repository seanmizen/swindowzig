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

/** The size of the small copy of the canvas that the test compares. */
const gridW = 64;
const gridH = 36;

interface CanvasPixels {
  /** The fraction of pixels that have a channel brighter than 64. */
  lit: number;
  /** The RGB bytes of a gridW x gridH copy of the canvas. */
  grid: number[];
}

/** Read the pixels of the canvas, as the compositor shows them. */
async function readCanvas(page: Page): Promise<CanvasPixels> {
  const png = await page.locator('#canvas').screenshot();
  return page.evaluate(
    async ({ b64, w, h }) => {
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      const bitmap = await createImageBitmap(
        new Blob([bytes], { type: 'image/png' }),
      );
      const full = new OffscreenCanvas(bitmap.width, bitmap.height);
      const fctx = full.getContext('2d');
      if (!fctx) throw new Error('No 2D context');
      fctx.drawImage(bitmap, 0, 0);
      const data = fctx.getImageData(0, 0, bitmap.width, bitmap.height).data;
      let lit = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (Math.max(data[i], data[i + 1], data[i + 2]) > 64) lit++;
      }
      const small = new OffscreenCanvas(w, h);
      const sctx = small.getContext('2d');
      if (!sctx) throw new Error('No 2D context');
      sctx.drawImage(bitmap, 0, 0, w, h);
      const sd = sctx.getImageData(0, 0, w, h).data;
      const grid: number[] = [];
      for (let i = 0; i < sd.length; i += 4)
        grid.push(sd[i], sd[i + 1], sd[i + 2]);
      return { lit: lit / (data.length / 4), grid };
    },
    { b64: png.toString('base64'), w: gridW, h: gridH },
  );
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
  // Count the canvas textures that the page gets: one for each frame.
  await page.addInitScript(() => {
    const w = window as unknown as { swCanvasFrames: number };
    w.swCanvasFrames = 0;
    const get = GPUCanvasContext.prototype.getCurrentTexture;
    GPUCanvasContext.prototype.getCurrentTexture = function () {
      w.swCanvasFrames++;
      return get.call(this);
    };
  });
  const frames = () =>
    page.evaluate(
      () => (window as unknown as { swCanvasFrames: number }).swCanvasFrames,
    );
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
